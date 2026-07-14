# Passive network observer for post-incident analysis. Writes a layered,
# timestamped record of the network to /var/log/net-observer.log so that when
# connectivity dies it is possible to tell WHICH layer failed:
#
#   EVT  lines — kernel routing-socket events (route -n monitor): interface
#                status flips, address add/loss, default-route changes. This is
#                the same AF_ROUTE stream sing-box's darwin interface monitor
#                listens to (and has been observed to miss events from — see
#                sing-tun monitor_darwin.go, which opens/closes a socket per
#                message), so the log records the ground truth of what the
#                kernel actually announced.
#   CHG  lines — compact routing/DNS snapshot, logged only when it differs
#                from the previous tick: IPv4/IPv6 default routes (including
#                sing-box's auto_route 0/1 + 128.0/1 pair and per-interface
#                ifscoped defaults, with flags) and resolv.conf nameservers.
#                This is exactly the state sing-tun's checkUpdate() inspects
#                when it decides "no route to internet", so during an incident
#                the log shows what the kernel table actually contained.
#   TICK lines — every ~15s, independent probes of each layer, bound to the
#                physical interface where needed so the sing-box TUN cannot
#                mask or fake the result:
#                  gw(...)          ping the default gateway (link layer)
#                  direct[1.1.1.1]  TCP :443 bound to the physical interface
#                                   (ISP path, bypasses the TUN via IP_BOUND_IF)
#                  vless[ip]        same, per VLESS server from the rendered
#                                   sing-box config (proxy-server reachability)
#                  tun=...          HTTP through normal routing, i.e. through
#                                   sing-box (the user-visible path)
#                  sel=...          which urltest member sing-box has selected
#                                   (Clash API on 127.0.0.1:9090)
#
# Diagnosis by column: gw=FAIL → local network/Wi-Fi down (infra, not us);
# gw=OK direct=OK vless=OK tun=000 → sing-box is wedged (stale interface
# monitor or stuck urltest — restart it); vless=FAIL with the rest OK → that
# proxy server is dead/blocked from this path.
#
#   ACT  lines — the built-in watchdog acting on that same diagnosis: when the
#                wedge signature (tunnel dead while the direct path works)
#                holds for 3 consecutive ticks (~2 min), it kickstarts
#                sing-box — a fresh process re-detects the interface and
#                recovers, which nothing else reliably does (the sing-box-
#                netreload resolv.conf trigger is dead while Tailscale
#                MagicDNS pins resolv.conf, and upstream has no fix for the
#                monitor wedge — observed 15-min outage on 2026-07-03 12:24).
#                When the whole network is down (direct also failing) a
#                restart cannot help, so it deliberately does nothing.
#                Backoff: at most one kickstart per 5 min (a captive portal
#                can mimic the wedge signature — the kick is harmless there,
#                the portal flow bypasses the proxy, but don't storm).
#                Kill switch without a rebuild:
#                  touch /var/lib/net-observer/watchdog-off
#   DNS  lines — one-shot detail dump when a tick's DNS probes look anomalous
#                (dns_anomaly below): mDNSResponder cache for the probe domain
#                (a fakeip address there = poisoned cache) and the active
#                scutil resolvers. Once per incident, re-armed on recovery.
#
# DNS columns in TICK — hunting the intermittent resolution failure of
# nks.lab.mirari.ru (the exact failure mode — NXDOMAIN, SERVFAIL, timeout, or
# a fakeip answer — is what these columns are here to distinguish).
# Background: .ru is the ONLY name class that needs a live upstream resolver —
# geosite-category-ru resolves via sing-box's `local` server (in practice the
# network's DHCP resolver), while every other domain gets an instant fakeip
# with no network round-trip. So "only this site breaks" points at that path:
#   nks[sb]   probe domain via sing-box's DNS (the TUN address) — what apps see
#   ru[sb]    control .ru domain via sing-box — separates "this zone is broken"
#             (nks fails, ru OK → Yandex Cloud NS) from "the whole .ru/local
#             path is broken" (both fail → router DNS dead/banned)
#   nks[rtr]  the DHCP resolver asked directly — the actual upstream that the
#             `local` server uses on this network
#   nks[doh]  Cloudflare DoH (1.1.1.1) bound to the physical interface — is
#             the zone alive at all, bypassing every local resolver and the TUN
#   site      HTTP code of https://<probe domain>/ via normal routing — the
#             user-visible outcome tied to the same tick (302 = healthy)
# Verdict vocabulary: OK(ip/NNms), FAKEIP(ip) — a .ru name answered from the
# fakeip range, ALWAYS a bug (e.g. a search-domain variant like
# <domain>.Dlink hit the fakeip catch-all, which answers any name and has no
# NXDOMAIN — the client then connects to a bogus address); EMPTY — NOERROR
# with no A record; SERVFAIL/NXDOMAIN/... — upstream rcode; TIMEOUT; SKIP —
# prerequisite missing (no rendered config / no DHCP resolver).
{ pkgs, config, ... }:
let
  # Rendered sing-box config (home-manager substitutes sops secrets into it at
  # activation time). The VLESS server IPs are read from it AT RUNTIME so they
  # never end up in the world-readable Nix store — the same secret hygiene as
  # users/gurinderu/sing-box-config.nix. If the file is missing (first switch
  # before home-manager activation) the vless probes are skipped, not fatal.
  singBoxConfigPath = "${config.users.users.gurinderu.home}/.config/sing-box/config.json";
  logPath = "/var/log/net-observer.log";
  jq = "${pkgs.jq}/bin/jq";

  # The domain whose intermittent resolution failures we are hunting, plus a
  # control domain that shares ONLY the .ru/`local` DNS path with it (see the
  # DNS-columns doc above). ya.ru: short, stable, unquestionably in
  # geosite-category-ru.
  dnsProbeDomain = "nks.lab.mirari.ru";
  dnsControlDomain = "ya.ru";

  observer = pkgs.writeShellScript "net-observer" ''
    # --- EVT stream (background) -------------------------------------------
    # Compress route -n monitor blocks to one or two lines and keep only the
    # events that matter for diagnosis: RTM_IFINFO (interface up/down flags),
    # RTM_NEWADDR/RTM_DELADDR (address acquired/lost) always; RTM_ADD/DELETE/
    # CHANGE only when their sockaddrs line mentions the default route.
    # Host-route churn (ARP clones and the like) is dropped for readability.
    # No explicit cleanup: launchd kills the whole process group on job stop,
    # and an orphaned `route monitor` dies of SIGPIPE on its next event.
    #
    # Run it in a restart loop: the AF_ROUTE read can error out (e.g. across
    # sleep/wake), and without the loop a single exit would silently kill the
    # EVT stream for good. The restart marker in the log also flags such
    # events. NB: route lives in /sbin on macOS (unlike netstat in /usr/sbin);
    # the first deployment pointed here at /usr/sbin/route and produced zero
    # EVT lines ever — if EVT lines are absent, verify the exec actually runs.
    while :; do
      /sbin/route -n monitor 2>/dev/null | while IFS= read -r l; do
        case "$l" in
          RTM_IFINFO* | RTM_NEWADDR* | RTM_DELADDR*)
            echo "$(/bin/date '+%F %T') EVT $l"
            pend=""
            ;;
          RTM_*)
            pend="$l"
            ;;
          " "*)
            # The whitespace-indented line under an RTM_ header carries the
            # sockaddr values (dst gateway netmask ...).
            if [ -n "$pend" ]; then
              case "$l" in
                *default*)
                  echo "$(/bin/date '+%F %T') EVT $pend"
                  echo "$(/bin/date '+%F %T') EVT   addrs:$l"
                  ;;
              esac
              pend=""
            fi
            ;;
        esac
      done
      echo "$(/bin/date '+%F %T') EVT route-monitor exited; restarting"
      /bin/sleep 2
    done &

    # --- TICK loop (foreground) ----------------------------------------------
    # curl telnet:// does a bare TCP connect; on success it idles until -m
    # fires, so a non-zero time_connect means the connect succeeded regardless
    # of the exit code. --interface on macOS uses IP_BOUND_IF, which constrains
    # routing to that interface and therefore bypasses the sing-box TUN.
    probe_tcp() { # ip port iface -> OK(seconds) / FAIL
      local t
      t=$(/usr/bin/curl --interface "$3" -m 4 -s -o /dev/null -w '%{time_connect}' "telnet://$1:$2" </dev/null 2>/dev/null)
      if [ -n "$t" ] && [ "$t" != "0.000000" ]; then
        echo "OK(''${t%???})"
      else
        echo "FAIL"
      fi
    }

    # One A query against one server; verdict per the vocabulary in the header.
    # The fakeip check matters most: geosite-category-ru must route .ru names
    # to a REAL resolver, so a 198.18.0.0/15 answer proves the query missed
    # the rule (fakeip answers any name — it cannot say NXDOMAIN).
    probe_dns() { # server domain -> OK(ip/NNms)/FAKEIP(ip)/EMPTY/<RCODE>/TIMEOUT/SKIP
      local out rcode ip ms
      [ -n "$1" ] || { echo SKIP; return; }
      out=$(/usr/bin/dig @"$1" +time=2 +tries=1 +noall +comments +answer +stats "$2" A 2>/dev/null)
      rcode=$(printf '%s\n' "$out" | /usr/bin/awk -F', ' '/->>HEADER<<-/ { sub(/status: /, "", $2); print $2; exit }')
      if [ -z "$rcode" ]; then echo TIMEOUT; return; fi
      if [ "$rcode" != "NOERROR" ]; then echo "$rcode"; return; fi
      ip=$(printf '%s\n' "$out" | /usr/bin/awk '$4 == "A" { print $5; exit }')
      ms=$(printf '%s\n' "$out" | /usr/bin/awk '/Query time:/ { print $4; exit }')
      case "$ip" in
        "") echo EMPTY ;;
        198.18.* | 198.19.*) echo "FAKEIP($ip)" ;;
        *) echo "OK($ip/''${ms}ms)" ;;
      esac
    }

    # Cloudflare DoH JSON API bound to the physical interface: bypasses the
    # TUN and every local resolver, so it answers "is the zone itself alive"
    # no matter how sick the local DNS machinery is. Cloudflare, not Google:
    # 8.8.8.8:443 is TCP-blackholed on the direct RU path (verified from the
    # Mac 2026-07-06), while 1.1.1.1:443 is the same endpoint the direct[]
    # probe already exercises every tick.
    probe_doh() { # domain iface -> OK(ip)/STATUS(n)/FAIL
      local out st ip
      out=$(/usr/bin/curl --interface "$2" -m 3 -s -H 'accept: application/dns-json' \
        "https://1.1.1.1/dns-query?name=$1&type=A" 2>/dev/null)
      [ -n "$out" ] || { echo FAIL; return; }
      st=$(printf '%s' "$out" | ${jq} -r '.Status // "?"' 2>/dev/null)
      ip=$(printf '%s' "$out" | ${jq} -r '[.Answer[]? | select(.type == 1) | .data][0] // empty' 2>/dev/null)
      if [ "$st" = "0" ] && [ -n "$ip" ]; then echo "OK($ip)"; else echo "STATUS(''${st:-?})"; fi
    }

    # Decides whether this tick's DNS verdicts constitute an incident worth
    # the one-shot detail dump (mDNSResponder cache + scutil resolvers).
    # Inputs: $nsb $rsb $nrtr $ndoh — verdicts per the header vocabulary.
    # The dump is gated by dns_incident so it fires once per incident and
    # re-arms when the condition clears.
    #
    # Policy: a FAKEIP answer in any column is always an incident (a .ru name
    # must never resolve into the fakeip range, whatever else is going on).
    # Otherwise the probe domain failing is an incident only while DoH still
    # resolves the zone — the "only .ru sites die" signature. When DoH also
    # fails the whole network is down and the gw/direct columns already tell
    # that story, so no dump. site=000 with healthy DNS is deliberately not
    # an anomaly here: that is a routing problem, not a DNS one.
    dns_anomaly() { # -> 0 anomaly / 1 healthy
      case "$nsb$rsb$nrtr" in *FAKEIP*) return 0 ;; esac
      case "$nsb" in OK* | SKIP) return 1 ;; esac
      case "$ndoh" in OK*) return 0 ;; esac
      return 1
    }

    # Defaults + every sing-box TUN chunk route — sing-box's auto_route on
    # macOS is not one default but a binary decomposition of the IPv4 space
    # (1, 2/7, 4/6, ... 128.0/1, carved around route_exclude_address), all
    # with the TUN address as gateway. Chunks have been observed to vanish
    # individually on network events and be reinstalled; a chunk missing for
    # long means that slice of the address space silently bypasses the proxy
    # (and if it covers the fakeip range, all proxied traffic blackholes).
    # The TUN gateway address is read from the rendered config at runtime.
    # netstat row: Destination Gateway Flags Netif (Expire is usually absent
    # for these, so $4 is the interface). The full table is hundreds of host
    # routes — not dumped.
    route_snapshot() {
      local tunaddr
      tunaddr=$(${jq} -r '[.inbounds[]? | select(.type == "tun") | .address[]?][0] // empty' \
        "${singBoxConfigPath}" 2>/dev/null | /usr/bin/cut -d/ -f1)
      /usr/sbin/netstat -rn -f inet 2>/dev/null \
        | /usr/bin/awk -v t="$tunaddr" \
          '$1 == "default" || (t != "" && $2 == t) { print "route4: " $1 " via " $2 " dev " $4 " flags " $3 }'
      /usr/sbin/netstat -rn -f inet6 2>/dev/null \
        | /usr/bin/awk '$1 == "default" { print "route6: " $1 " via " $2 " dev " $4 " flags " $3 }'
      /usr/bin/awk '/^nameserver/ { ns = ns " " $2 } END { print "dns:" ns }' /etc/resolv.conf 2>/dev/null
    }

    # Compact one-line snapshot of the link/DHCP layer that the TICK probes do
    # not record: the gateway's ARP entry (empty/incomplete = L2 is dead, the
    # coworking-MikroTik failure signature) and the DHCP router/DNS from the
    # lease. Logged by the caller only when it changes (see the NET block), so
    # the log carries a timeline of L2 state — the state just before a gw drop
    # is the last NET line above the GWD dump. Args: iface gw link ip ssid.
    link_snapshot() {
      local gwmac pkt dhcp_router dhcp_dns
      if [ -n "$2" ]; then
        gwmac=$(/usr/sbin/arp -n "$2" 2>/dev/null | /usr/bin/sed -n 's/.* at \([0-9a-f:]*\) on .*/\1/p')
        [ -n "$gwmac" ] || gwmac=incomplete
      else
        gwmac=none
      fi
      pkt=$(/usr/sbin/ipconfig getpacket "$1" 2>/dev/null)
      dhcp_router=$(printf '%s\n' "$pkt" | /usr/bin/sed -n 's/^router.*: *{*\([0-9][0-9.]*\).*/\1/p' | /usr/bin/head -1)
      dhcp_dns=$(printf '%s\n' "$pkt" | /usr/bin/sed -n 's/^domain_name_server.*: *{*\([0-9][0-9.]*\).*/\1/p' | /usr/bin/head -1)
      echo "iface=''${1:--} link=''${3:--} ip=''${4:--} ssid=''${5:--} gw=''${2:--} gwmac=''${gwmac:-none} dhcp_router=''${dhcp_router:--} dhcp_dns=''${dhcp_dns:--}"
    }

    # Deep ARP-layer forensics for a gateway-down incident — exactly the state
    # the manual netdiag.sh captures, but fired automatically the moment the gw
    # ping dies (see the caller's one-shot gating). Backgrounded by the caller,
    # so the slow `log show` cannot stall the tick loop. Args: ts iface gw before.
    gw_incident_dump() {
      local fp bcast
      echo "$1 GWD before: $4"
      if [ -n "$3" ]; then
        echo "$1 GWD arp: $(/usr/sbin/arp -an 2>/dev/null | /usr/bin/grep -F "($3)" || echo '(no arp entry)')"
        # Drop the entry and re-ping: does the MAC re-resolve? (incomplete after
        # this = ARP/L2 dead — private-MAC/reply-only; resolves but ping fails =
        # the gw filters us.) This mutates the ARP cache, which can also unstick
        # a stale entry — the same trick netdiag.sh uses, done deliberately.
        /usr/sbin/arp -d "$3" >/dev/null 2>&1
        if /sbin/ping -c 2 -t 2 "$3" >/dev/null 2>&1; then fp=OK; else fp=FAIL; fi
        echo "$1 GWD force-arp: arp -d + ping = $fp; $(/usr/sbin/arp -an 2>/dev/null | /usr/bin/grep -F "($3)" || echo '(still no entry)')"
      else
        echo "$1 GWD arp: (no default gateway)"
      fi
      bcast=$(/sbin/ifconfig "$2" 2>/dev/null | /usr/bin/awk '/inet /{print $6; exit}')
      if [ -n "$bcast" ]; then
        echo "$1 GWD bcast($bcast): $(/sbin/ping -c 2 -t 2 "$bcast" 2>&1 | /usr/bin/awk '/packets/{print; exit}')"
      fi
      /usr/bin/log show --last 10m --predicate 'subsystem == "com.apple.IPConfiguration"' --style compact 2>/dev/null \
        | /usr/bin/grep -iE "arp|router|conflict|lease|roam" | /usr/bin/tail -20 \
        | /usr/bin/sed "s/^/$1 GWD ipconfig-log: /"
      wifi_capture_dump "$1" GWD
    }

    # The Wi-Fi driver's OWN verdict on why the link died — the L1/L2 trigger the
    # IPConfiguration log (DHCP aftermath) never shows. Args: ts tag (GWD|GWCHG).
    # Called both from a gateway-down incident AND from a physical-network switch
    # (fast Wi-Fi drop → hotspot failover, where gw never shows FAIL). On an
    # "unusable" link the BCMWLAN driver fires a CoreCapture whose directory name
    # encodes the inducer/reason: "Net Beacons Lost" (AP beacons stopped arriving
    # — RF/range), "Net Deauthentication ... Reason code=N" (AP kicked us),
    # "SlowWiFiRecovery"/"DNSFailureRecovery reassoc" (macOS forced a reassoc).
    # NB: a clean disassociation/roam may leave NO CoreCapture — the symptomsd
    # netepochs "roaming"/en0->(null) burst below is then the only trace.
    wifi_capture_dump() {
      # Only a capture created NEAR this incident (~last 3 min) is relevant — an
      # older one is unrelated noise (ls -1t|head always returned stale dirs).
      # Crucially the ABSENCE of a fresh capture is itself the diagnostic: it
      # means the driver saw no beacon-loss/deauth, so L2 was fine and the drop
      # is gateway/router-side (ARP still resolves, the gw just won't answer) —
      # a different failure class than an RF/beacon drop, which DOES capture.
      caps=$(/usr/bin/find /Library/Logs/CrashReporter/CoreCapture/WiFi -mindepth 1 -maxdepth 1 -newermt '-180 seconds' 2>/dev/null)
      if [ -n "$caps" ]; then
        printf '%s\n' "$caps" | /usr/bin/sed "s#.*/WiFi/##; s/^/$1 $2 wifi-capture: /"
      else
        echo "$1 $2 wifi-capture: (none <3m — driver saw no beacon-loss/deauth; RF/link was NOT the trigger, look router-side)"
      fi
      # symptomsd transitions in the incident window: "roaming" = driver moved to
      # another BSSID; "primary interface change to (null)"/Unsatisfied = the
      # network went away. Windowed and filtered so the ~70s "noroam" heartbeat
      # doesn't bury the signal (the earlier tail-12 caught only post-drop noise).
      /usr/bin/log show --last 5m --predicate 'process == "symptomsd" AND category == "netepochs"' --style compact 2>/dev/null \
        | /usr/bin/grep -iE "roaming|Unsatisfied|interface change to .null." | /usr/bin/tail -8 \
        | /usr/bin/sed "s/^/$1 $2 wifi-epoch: /"
    }

    echo "$(/bin/date '+%F %T') START net-observer"
    /bin/mkdir -p /var/lib/net-observer
    # Each tick's DNS probes use a fresh mktemp dir removed at end of tick; a
    # SIGKILL mid-tick (launchd stop between mktemp and rm) would orphan one.
    # Sweep any left by a killed predecessor so they can't accumulate.
    /bin/rm -rf /tmp/net-observer-dns.* 2>/dev/null

    prev_snap=""
    wedge_ticks=0
    last_kick=0
    dns_incident=0
    prev_link_snap=""
    last_good_snap="(none yet)"
    gw_incident=0
    prev_gw=""
    while :; do
      ts=$(/bin/date '+%F %T')

      snap=$(route_snapshot)
      if [ "$snap" != "$prev_snap" ]; then
        printf '%s\n' "$snap" | /usr/bin/sed "s/^/$ts CHG /"
        prev_snap="$snap"
      fi

      # Physical interface: from the default route, unless the sing-box TUN
      # owns it (utun*) — then take the first non-utun interface scutil
      # reports. Probes must bind to the physical one to bypass the TUN.
      iface=$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/interface:/ { print $2; exit }')
      case "$iface" in
        utun* | "")
          iface=$(/usr/sbin/scutil --nwi | /usr/bin/awk \
            '/^Network interfaces:/ { for (i = 3; i <= NF; i++) if ($i !~ /^utun/) { print $i; exit } }')
          ;;
      esac

      # DNS probes (dig ≤2s, doh ≤3s, site ≤4s) run in the background while the
      # sequential gw/direct/tun/vless probes below execute, so a healthy tick
      # costs no extra wall time; collected right before the TICK line. NB: wait on
      # explicit pids only — a bare `wait` would block forever on the EVT
      # route-monitor loop. tundns = sing-box's DNS address (the TUN address,
      # same one route_snapshot reads); rtr = the network's DHCP resolver.
      tundns=$(${jq} -r '[.inbounds[]? | select(.type == "tun") | .address[]?][0] // empty' \
        "${singBoxConfigPath}" 2>/dev/null | /usr/bin/cut -d/ -f1)
      rtr=$(/usr/sbin/ipconfig getpacket "$iface" 2>/dev/null \
        | /usr/bin/sed -n 's/^domain_name_server.*: *{\{0,1\}\([0-9][0-9.]*\).*/\1/p' | /usr/bin/head -1)
      dnstmp=$(/usr/bin/mktemp -d /tmp/net-observer-dns.XXXXXX)
      probe_dns "$tundns" "${dnsProbeDomain}" >"$dnstmp/nsb" 2>/dev/null & dp1=$!
      probe_dns "$tundns" "${dnsControlDomain}" >"$dnstmp/rsb" 2>/dev/null & dp2=$!
      probe_dns "$rtr" "${dnsProbeDomain}" >"$dnstmp/nrtr" 2>/dev/null & dp3=$!
      probe_doh "${dnsProbeDomain}" "$iface" >"$dnstmp/ndoh" 2>/dev/null & dp4=$!
      /usr/bin/curl -m 4 -s -o /dev/null -w '%{http_code}' "https://${dnsProbeDomain}/" >"$dnstmp/site" 2>/dev/null & dp5=$!

      gw=$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/gateway:/ { print $2; exit }')
      if [ -z "$gw" ] && [ -n "$iface" ]; then
        # TUN default routes carry no gateway; ask the physical interface.
        gw=$(/sbin/route -n get -ifscope "$iface" default 2>/dev/null | /usr/bin/awk '/gateway:/ { print $2; exit }')
      fi
      if [ -n "$gw" ]; then
        if /sbin/ping -c 1 -t 2 "$gw" >/dev/null 2>&1; then gwst=OK; else gwst=FAIL; fi
      else
        gwst=NOGW
      fi

      # macOS redacts the SSID for processes without a location entitlement
      # (ipconfig prints the literal "<redacted>", networksetup claims no
      # association). Log whatever ipconfig gives — as a root daemon it may be
      # the real name; if not, the gateway IP in the TICK line still uniquely
      # identifies the network.
      ssid=$(/usr/sbin/ipconfig getsummary "$iface" 2>/dev/null \
        | /usr/bin/awk -F ' SSID : ' '/ SSID : / { print $2; exit }')

      # Link-layer truth for "who killed the network": link=active + an IP
      # while the gateway ping fails = still associated, the network itself
      # died (infra problem); link=inactive or no IP = the AP dropped us /
      # DHCP broke (local problem).
      link=$(/sbin/ifconfig "$iface" 2>/dev/null | /usr/bin/awk '/status:/ { print $2 }')
      myip=$(/usr/sbin/ipconfig getifaddr "$iface" 2>/dev/null)
      direct=$(probe_tcp 1.1.1.1 443 "$iface")
      tun=$(/usr/bin/curl -m 4 -s -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 2>/dev/null)
      sel=$(/usr/bin/curl -m 2 -s http://127.0.0.1:9090/proxies/vless-auto 2>/dev/null \
        | ${jq} -r '.now // "?"' 2>/dev/null)

      # sing-box pid(s): a change between ticks pins a restart (netreload
      # kickstart or crash) on the timeline; two pids = old/new overlap during
      # a kickstart; "-" = the daemon is down.
      sb=$(/usr/bin/pgrep -f "sing-box run" 2>/dev/null | /usr/bin/paste -sd, -)

      vls=""
      vips=$(${jq} -r '[.outbounds[]? | select(.type == "vless") | .server] | unique | join(" ")' \
        "${singBoxConfigPath}" 2>/dev/null)
      if [ -n "$vips" ]; then
        for ip in $vips; do
          vls="$vls vless[$ip]=$(probe_tcp "$ip" 443 "$iface")"
        done
      else
        vls=" vless=skip"
      fi

      wait "$dp1" "$dp2" "$dp3" "$dp4" "$dp5" 2>/dev/null
      nsb=$(/bin/cat "$dnstmp/nsb" 2>/dev/null)
      rsb=$(/bin/cat "$dnstmp/rsb" 2>/dev/null)
      nrtr=$(/bin/cat "$dnstmp/nrtr" 2>/dev/null)
      ndoh=$(/bin/cat "$dnstmp/ndoh" 2>/dev/null)
      site=$(/bin/cat "$dnstmp/site" 2>/dev/null)
      /bin/rm -rf "$dnstmp"

      echo "$ts TICK if=''${iface:--} link=''${link:--} ip=''${myip:--} ssid=''${ssid:--} gw(''${gw:--})=$gwst direct[1.1.1.1]=$direct tun=''${tun:-ERR} sel=''${sel:-?} sb=''${sb:--}$vls nks[sb]=''${nsb:-?} ru[sb]=''${rsb:-?} nks[rtr]=''${nrtr:-?} nks[doh]=''${ndoh:-?} site=''${site:-ERR}"

      # --- L2/DHCP state, logged only on change (the "before" timeline) ------
      # gateway ARP entry + DHCP router/DNS; NET line only when it differs from
      # the previous tick. last_good_snap keeps the most recent snapshot taken
      # while the gw still answered, so the incident dump can show before->after.
      link_snap=$(link_snapshot "$iface" "$gw" "$link" "$myip" "$ssid")
      if [ "$link_snap" != "$prev_link_snap" ]; then
        echo "$ts NET $link_snap"
        prev_link_snap="$link_snap"
      fi
      case "$gwst" in OK) last_good_snap="$link_snap" ;; esac

      # --- gw incident: one-shot deep ARP dump when the gateway ping dies -----
      # Fires on the first FAIL/NOGW tick, once per incident, re-armed when the
      # gw pings again (mirrors dns_incident). Backgrounded so the dump's slow
      # `log show` cannot stall the 15s loop.
      case "$gwst" in
        FAIL | NOGW)
          if [ "$gw_incident" = 0 ]; then
            gw_incident=1
            gw_incident_dump "$ts" "$iface" "$gw" "$last_good_snap" &
          fi
          ;;
        *)
          gw_incident=0
          ;;
      esac

      # Physical-network switch: the gateway changed to a DIFFERENT real gw
      # between ticks (Wi-Fi dropped and macOS fell over to e.g. the iPhone
      # hotspot). gwst never shows FAIL here — a new gw answers — so the
      # FAIL-gated dump above misses it. But a *voluntary* switch (user turns on
      # the hotspot) looks identical from here, and dumping on every network
      # change would be noise. Discriminator: an involuntary drop leaves a FRESH
      # Wi-Fi driver CoreCapture (beacon loss / deauth) in the last ~2 min; a
      # manual switch leaves none. So only capture when one exists.
      if [ -n "$gw" ] && [ -n "$prev_gw" ] && [ "$gw" != "$prev_gw" ]; then
        if [ -n "$(/usr/bin/find /Library/Logs/CrashReporter/CoreCapture/WiFi -mindepth 1 -maxdepth 1 -newermt '-120 seconds' 2>/dev/null | /usr/bin/head -1)" ]; then
          echo "$ts GWCHG gateway $prev_gw -> $gw with fresh Wi-Fi capture (involuntary drop)"
          wifi_capture_dump "$ts" GWCHG &
        fi
      fi
      prev_gw="$gw"

      # One-shot DNS detail dump, gated so an incident logs once and re-arms
      # after recovery. What the dump answers: was the cache poisoned with a
      # fakeip (the search-domain mechanism), and which resolvers the system
      # actually had at that moment.
      if dns_anomaly; then
        if [ "$dns_incident" = 0 ]; then
          dns_incident=1
          cache=$(/usr/bin/dscacheutil -q host -a name "${dnsProbeDomain}" 2>/dev/null)
          if [ -n "$cache" ]; then
            printf '%s\n' "$cache" | /usr/bin/sed "s/^/$ts DNS cache: /"
          else
            echo "$ts DNS cache: (empty)"
          fi
          case "$cache" in
            *198.18.* | *198.19.* | *fc00:*)
              echo "$ts DNS ALERT poisoned mDNSResponder cache: fakeip for a .ru name"
              ;;
          esac
          /usr/sbin/scutil --dns 2>/dev/null \
            | /usr/bin/awk '/^resolver #|nameserver|search domain/' | /usr/bin/head -12 \
            | /usr/bin/sed "s/^/$ts DNS scutil:/"
        fi
      else
        dns_incident=0
      fi

      # Watchdog: count consecutive wedge-signature ticks; anything else
      # (healthy tunnel OR direct path also down) resets the counter.
      case "$direct" in OK*) direct_ok=1 ;; *) direct_ok=0 ;; esac
      if [ "$tun" != "204" ] && [ "$direct_ok" = 1 ]; then
        wedge_ticks=$((wedge_ticks + 1))
      else
        wedge_ticks=0
      fi
      if [ "$wedge_ticks" -ge 3 ] && [ ! -f /var/lib/net-observer/watchdog-off ]; then
        now_s=$(/bin/date +%s)
        if [ $((now_s - last_kick)) -ge 300 ]; then
          echo "$ts ACT tunnel dead $wedge_ticks ticks, direct path up -> kickstart sing-box"
          /bin/launchctl kickstart -k system/org.nixos.sing-box
          last_kick=$now_s
          wedge_ticks=0
        fi
      fi

      /bin/sleep 15
    done
  '';
in
{
  launchd.daemons.net-observer.serviceConfig = {
    # Same /nix-not-yet-mounted spawn race as the sing-box daemon (see
    # ./sing-box.nix): block on wait4path before exec'ing a store path.
    ProgramArguments = [
      "/bin/sh"
      "-c"
      "/bin/wait4path /nix/store && exec ${observer}"
    ];
    RunAtLoad = true;
    KeepAlive = true;
    ThrottleInterval = 5;
    # launchd opens the log before running the program, hence /var/log (always
    # exists). Rotation is handled by the sing-box-logrotate daemon — this log
    # is listed in its config (see ./sing-box.nix).
    StandardOutPath = logPath;
    StandardErrorPath = logPath;
  };
}
