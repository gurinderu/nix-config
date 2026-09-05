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
#                  gw(...)          ping the default gateway (link layer),
#                                   reported as OK(N.Nms) — the RTT, not a
#                                   boolean: the coworking gateway fails by
#                                   RAMPING (reply time climbs ~40s, then
#                                   stops), which a bare OK/FAIL column hides.
#                                   FAIL, NOGW (no default gateway) or QUIET
#                                   (probe withheld, see the drop-box below).
#                  direct[1.1.1.1]  TCP :443 bound to the physical interface
#                                   (ISP path, bypasses the TUN via IP_BOUND_IF)
#                  vless[ip]        same, per VLESS server from the rendered
#                                   sing-box config (proxy-server reachability)
#                  tun=...          HTTP through normal routing, i.e. through
#                                   sing-box (the user-visible path)
#                  sel=...          which urltest member sing-box has selected
#                                   (Clash API on 127.0.0.1:9090)
#                  load=...         host load averages 1/5/15 min — the
#                                   starvation discriminator (see below)
#
# Diagnosis by column: gw=FAIL → local network/Wi-Fi down (infra, not us);
# gw=OK direct=OK vless=OK tun=000 → sing-box is wedged (stale interface
# monitor or stuck urltest — restart it); vless=FAIL with the rest OK → that
# proxy server is dead/blocked from this path; tun=000 with load in the tens
# (2026-07-24: ~31 on 8 cores, swap full) → host starvation of the userspace
# TUN path — restarts do NOT cure it, watch for repeated ACT kicks minutes
# apart and inflated direct/nks[rtr] latencies at the cluster edges.
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
#                restart cannot help, so it deliberately does nothing. Same
#                for host starvation: above load1 16 the kick is suppressed
#                and logged as "ACT suppressed" instead, because there the
#                dead tunnel is a 4s probe losing to the run queue, not a
#                wedge, and restarting only tears down live flows (see the
#                gate below for the 2026-07-27 nine-hour restart loop).
#                Backoff: starts at one kickstart per 5 min and doubles for
#                every kick that is not followed by a healthy tun probe
#                (5/10/20/40/60 min, reset on the first 204) — a kick that
#                didn't cure the outage means it isn't a process wedge, and
#                restart-storming a fleet block or a hostile network only
#                churns utuns (see the escalation comment at the gate below).
#                A second repair path covers the job being GONE from launchd
#                entirely (manual bootout never re-bootstrapped, or BTM
#                disallow): sb= empty for 3+ ticks with the service missing
#                → bootstrap it back, and if THAT fails, log + notify the
#                console user (BTM needs a human in System Settings).
#                Kill switch without a rebuild (covers both paths):
#                  touch /var/lib/net-observer/watchdog-off
#
# Request drop-box — /var/lib/net-observer/requests/, sticky-world-writable so
# an unprivileged reader can ask without sudo. Only file NAMES are read, never
# contents:
#   freeze     one-shot: copy the pcap ring out now (consumed)
#   snapshot   one-shot: SNAP block — wdutil radio view, DHCP packet, ARP table
#              size + sample, direct reachability, per-network private MAC. This
#              is what the hand-run netdiag.sh did and nothing else recorded;
#              its ARP/DHCP/CoreCapture half was already covered by GWD, which
#              is why that script is gone. (consumed)
#   quiet      persistent: stop addressing the gateway — no ICMP echo (gw=QUIET)
#              and no forced who-has in the incident dump. For gathering a
#              capture that cannot be dismissed as "your machine is hammering
#              the gateway" (2026-08-26: 16 of 28 who-has 10.20.0.1 were ours).
#              Incident detection stays live under quiet via the direct probe;
#              ordinary traffic still traverses the gw, so quiet is not silence.
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

    # --- PCAP ring (background) ----------------------------------------------
    # A continuous small ring-buffer capture of L2/L3 CONTROL traffic on the
    # physical interface, so the packets AROUND a gateway drop are already on
    # disk the moment the incident fires — by then the Mac has often failed over
    # to the iPhone hotspot (seen within one 15s tick), far too late to START
    # capturing after detecting the drop. The filter deliberately EXCLUDES the
    # fat VLESS/data flow and keeps only ARP, ICMP, DHCP and broadcast — which is
    # exactly the "who stopped answering" evidence: my echo-requests still
    # leaving while the gateway's replies stop, any deauth/ICMP-unreachable the
    # router emits, and the broadcast-storm rate. -s128 (headers only) + an 8 MB
    # ring (8×1MB) then covers minutes. Bound to the same physical interface the
    # TICK loop probes (never the utun), re-picked in a restart loop so it
    # survives sleep/wake and iface changes — same idiom as the EVT stream above.
    # tcpdump lives in /usr/sbin and the daemon runs as root, so no extra
    # dependency or privilege. Frozen per incident by gw_incident_dump() below.
    /bin/mkdir -p /var/lib/net-observer
    while :; do
      cif=$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/interface:/ { print $2; exit }')
      case "$cif" in
        utun* | "")
          cif=$(/usr/sbin/scutil --nwi | /usr/bin/awk \
            '/^Network interfaces:/ { for (i = 3; i <= NF; i++) if ($i !~ /^utun/) { print $i; exit } }')
          ;;
      esac
      [ -n "$cif" ] || cif=en0
      /usr/sbin/tcpdump -i "$cif" -n -p -s 128 -C 1 -W 8 -w /var/lib/net-observer/ring.pcap \
        'arp or icmp or udp port 67 or udp port 68 or ether broadcast' \
        >/dev/null 2>&1
      echo "$(/bin/date '+%F %T') EVT pcap-ring exited on ''${cif:--}; restarting"
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
    # to a REAL resolver, so an answer inside the fakeip pool proves the query
    # missed the rule (fakeip answers any name — it cannot say NXDOMAIN).
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
        # Kept in lockstep with users/gurinderu/fakeip-range.nix (172.24.0.0/14 =
        # 172.24.*-172.27.*): update this glob if that range ever moves.
        172.2[4-7].*) echo "FAKEIP($ip)" ;;
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
    # Also freezes the PCAP ring (above) so packet-level proof of the drop —
    # requests out, replies gone — survives past the failover to the hotspot.
    # Freeze the pcap ring — copy the whole ring to a timestamped dir before the
    # 8 MB buffer rotates over the packets around this incident. The last file
    # may end mid-packet (pcap readers tolerate it). Pruned to the last 12 so the
    # captures can't grow without bound (logrotate owns only the .log). Called
    # from BOTH a gw-down incident (GWD) and a fast gw failover (GWCHG). Args: ts tag.
    freeze_pcap() {
      local frz
      frz="/var/lib/net-observer/gwdrop-$(printf '%s' "$1" | /usr/bin/tr ' :' '--')"
      /bin/mkdir -p "$frz"
      /bin/cp /var/lib/net-observer/ring.pcap* "$frz"/ 2>/dev/null
      echo "$1 $2 pcap-frozen: $frz ($(/bin/ls "$frz" 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ') files; read: tcpdump -nr <file> / open in Wireshark)"
      /bin/ls -1dt /var/lib/net-observer/gwdrop-* 2>/dev/null | /usr/bin/tail -n +13 | /usr/bin/xargs /bin/rm -rf 2>/dev/null
    }

    gw_incident_dump() {
      local fp
      echo "$1 GWD before: $4"
      # Freeze the ring FIRST — before the slow arp/log-show work below — so the
      # minutes of control-plane packets around this drop are copied out before
      # rotation overwrites them.
      freeze_pcap "$1" GWD
      if [ -n "$3" ]; then
        echo "$1 GWD arp: $(/usr/sbin/arp -an 2>/dev/null | /usr/bin/grep -F "($3)" || echo '(no arp entry)')"
        # Drop the entry and re-ping: does the MAC re-resolve? (incomplete after
        # this = ARP/L2 dead — private-MAC/reply-only; resolves but ping fails =
        # the gw filters us.) This mutates the ARP cache, which can also unstick
        # a stale entry — the same trick the old netdiag.sh used, deliberately.
        #
        # Skipped under quiet. This probe is the single loudest thing the daemon
        # does at the gateway: `arp -d` guarantees a fresh who-has broadcast and
        # the ping adds two more ICMP, all of it emitted at the exact moment a
        # capture is running to prove the gateway is failing. In the 2026-08-26
        # window 16 of the 28 `who-has 10.20.0.1` frames were this host's — the
        # single fact that let the network admin dismiss the capture. Log the
        # skip rather than going quiet about it: SKIP is a verdict, and a
        # missing force-arp line must not read as "the dump did not run".
        if [ -f /var/lib/net-observer/requests/quiet ]; then
          echo "$1 GWD force-arp: SKIP (quiet — arp -d + ping withheld so this host emits no gateway ARP/ICMP into its own capture)"
        else
          /usr/sbin/arp -d "$3" >/dev/null 2>&1
          if /sbin/ping -c 2 -t 2 "$3" >/dev/null 2>&1; then fp=OK; else fp=FAIL; fi
          echo "$1 GWD force-arp: arp -d + ping = $fp; $(/usr/sbin/arp -an 2>/dev/null | /usr/bin/grep -F "($3)" || echo '(still no entry)')"
        fi
      else
        echo "$1 GWD arp: (no default gateway)"
      fi
      # NB: no broadcast ping here. A ping to the subnet broadcast pulls a reply
      # from every host that answers broadcast ICMP (hundreds on a flat /20), so
      # its "+N duplicates" says nothing about whether the GATEWAY is up — it
      # only measures how many neighbours answer broadcast, and it muddied the
      # gw diagnosis (those replies got misread as a gw/segment signal, and the
      # coworking admin objected to the broadcast traffic). The gw's own
      # reachability is already the force-arp verdict above + the TICK gw() probe.
      /usr/bin/log show --last 10m --predicate 'subsystem == "com.apple.IPConfiguration"' --style compact 2>/dev/null \
        | /usr/bin/grep -iE "arp|router|conflict|lease|roam" | /usr/bin/tail -20 \
        | /usr/bin/sed "s/^/$1 GWD ipconfig-log: /"
      wifi_capture_dump "$1" GWD
    }

    # The physical interface, i.e. never the sing-box TUN — the same derivation
    # the TICK loop and the pcap ring do inline. Factored out for snapshot_dump,
    # which runs outside the tick and has no $iface in scope.
    current_iface() {
      local i
      i=$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/interface:/ { print $2; exit }')
      case "$i" in
        utun* | "")
          i=$(/usr/sbin/scutil --nwi | /usr/bin/awk \
            '/^Network interfaces:/ { for (j = 3; j <= NF; j++) if ($j !~ /^utun/) { print $j; exit } }')
          ;;
      esac
      [ -n "$i" ] || i=en0
      echo "$i"
    }

    # On-demand full snapshot, replacing the hand-run netdiag.sh (removed with
    # this change). Everything that script did on the ARP/DHCP layer — force
    # ARP, the DHCP lease, the IPConfiguration log, the CoreCapture verdict — is
    # already captured by gw_incident_dump/link_snapshot above, and captured
    # automatically AT the incident rather than by hand minutes after it, which
    # is the whole reason the manual script is going away. What is left here is
    # only what nothing else records: the Wi-Fi driver's own radio view, the
    # full ARP table (how populated the segment is), the per-network private
    # MAC, and a plain reachability check that does not involve the gateway.
    #
    # Deliberately no broadcast ping — see the note in gw_incident_dump.
    # Args: ts tag.
    snapshot_dump() {
      local iface arp_n
      iface=$(current_iface)
      echo "$1 SNAP begin ($2) iface=$iface"
      freeze_pcap "$1" SNAP
      /usr/bin/wdutil info 2>/dev/null \
        | /usr/bin/grep -viE "^[[:space:]]*(MAC Address|BSSID)[[:space:]]*:" \
        | /usr/bin/sed "s/^/$1 SNAP wdutil: /"
      /usr/sbin/ipconfig getpacket "$iface" 2>/dev/null | /usr/bin/sed "s/^/$1 SNAP dhcp: /"
      # Neighbour count first (the number is the point — how many hosts share
      # this broadcast domain), then a bounded sample of the table itself.
      arp_n=$(/usr/sbin/arp -an 2>/dev/null | /usr/bin/awk 'END { print NR + 0 }')
      echo "$1 SNAP arp: $arp_n entries in the neighbour table"
      /usr/sbin/arp -an 2>/dev/null | /usr/bin/head -40 | /usr/bin/sed "s/^/$1 SNAP arp: /"
      # Reachability that does NOT go through the gateway ping: a TCP connect
      # bound to the physical interface, so the TUN cannot fake the answer.
      echo "$1 SNAP direct[1.1.1.1]=$(probe_tcp 1.1.1.1 443 "$iface")"
      # Private (per-network randomised) MAC: macOS rotates it per SSID, which
      # is why a MAC seen in an older capture may not be this host's any more —
      # exactly the ambiguity that made an earlier capture hard to attribute.
      /usr/libexec/PlistBuddy -c "Print" \
        /Library/Preferences/com.apple.wifi.known-networks.plist 2>/dev/null \
        | /usr/bin/grep -iE "SSID|PrivateMACAddress|AddressType" | /usr/bin/head -20 \
        | /usr/bin/sed "s/^/$1 SNAP privmac: /"
      echo "$1 SNAP end"
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
    # Request drop-box for unprivileged callers (a terminal, or the menu-bar app
    # once it learns to drive this daemon). They run as the login user and must
    # not need sudo just to ask for a capture freeze, so this one directory is
    # sticky-world-writable while
    # /var/lib/net-observer itself stays root-owned 755. Only file NAMES are
    # honoured, never contents, and every request maps to a read-only action —
    # the worst a stray file achieves is an extra frozen capture.
    /bin/mkdir -p /var/lib/net-observer/requests
    /bin/chmod 1777 /var/lib/net-observer/requests
    # Each tick's DNS probes use a fresh mktemp dir removed at end of tick; a
    # SIGKILL mid-tick (launchd stop between mktemp and rm) would orphan one.
    # Sweep any left by a killed predecessor so they can't accumulate.
    /bin/rm -rf /tmp/net-observer-dns.* 2>/dev/null

    prev_snap=""
    wedge_ticks=0
    last_kick=0
    last_skip=0
    kick_streak=0
    sb_gone_ticks=0
    last_bootstrap=0
    last_btm_notify=0
    dns_incident=0
    prev_link_snap=""
    last_good_snap="(none yet)"
    gw_incident=0
    prev_gw=""
    while :; do
      ts=$(/bin/date '+%F %T')

      # --- widget requests -------------------------------------------------
      # One-shot asks dropped by the menu-bar plugin; acted on within a tick and
      # consumed. `quiet` is NOT here: it is a persistent flag, read below.
      if [ -f /var/lib/net-observer/requests/freeze ]; then
        /bin/rm -f /var/lib/net-observer/requests/freeze
        freeze_pcap "$ts" REQ &
      fi
      if [ -f /var/lib/net-observer/requests/snapshot ]; then
        /bin/rm -f /var/lib/net-observer/requests/snapshot
        snapshot_dump "$ts" REQ &
      fi

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
      # Gateway probe, with the round-trip time kept rather than a bare OK: the
      # coworking failure does not start as a loss, it starts as a RAMP — the
      # reply time climbs in a straight line for ~40s and only then stops. A
      # boolean column hides that entirely and the drop looks instantaneous, so
      # the number is what makes the menu-bar widget an early warning instead of
      # an obituary.
      #
      # `touch /var/lib/net-observer/requests/quiet` suppresses this probe (and
      # the force-ARP in the incident dump). One ICMP per 15s is negligible
      # traffic, but it is not negligible EVIDENCE: it makes this host a visible
      # source of gateway ARP/ICMP in its own captures, which is precisely the
      # objection a network admin raises when shown them ("your machine is the
      # one hammering the gateway"). In the 2026-08-26 capture window 16 of 28
      # `who-has 10.20.0.1` frames were ours — enough to sink the argument.
      #
      # What quiet does NOT do is make this host silent. The direct/vless TCP
      # probes, the DNS probes and the site curl all route THROUGH the gateway,
      # so they still refresh its ARP entry and still appear in a capture. Quiet
      # removes the traffic addressed AT the gateway (ICMP echo, forced who-has)
      # — the part that reads as "hammering" — not the host's ordinary traffic.
      # A capture free of this host entirely needs the daemon stopped, and then
      # there is no record at all; quiet is the usable middle.
      if [ -f /var/lib/net-observer/requests/quiet ]; then
        gwst=QUIET
      elif [ -n "$gw" ]; then
        rtt=$(/sbin/ping -c 1 -t 2 "$gw" 2>/dev/null \
          | /usr/bin/sed -n 's/.*time=\([0-9.]*\) ms.*/\1/p' | /usr/bin/head -1)
        if [ -n "$rtt" ]; then gwst="OK(''${rtt}ms)"; else gwst=FAIL; fi
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

      # Host load (1/5/15 min): tun=000 with the direct path fast AND load in
      # the tens is host starvation (sing-box scheduling-starved), not a wedge
      # — a restart won't cure it. Took a log archaeology session to attribute
      # the 2026-07-24 incident wave to this; now it's one column.
      load=$(/usr/sbin/sysctl -n vm.loadavg 2>/dev/null \
        | /usr/bin/awk '{ print $2 "/" $3 "/" $4 }')
      # 1-minute figure on its own: the watchdog gates on it below. If sysctl
      # ever fails the field is empty or "?", which would make the awk gate a
      # syntax error and silently disable the watchdog for good — fall back to
      # 0 instead so an unreadable load means "kick", the pre-gate behaviour.
      load1=''${load%%/*}
      case "$load1" in
        "" | *[!0-9.]*) load1=0 ;;
      esac

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

      echo "$ts TICK if=''${iface:--} link=''${link:--} ip=''${myip:--} ssid=''${ssid:--} gw(''${gw:--})=$gwst direct[1.1.1.1]=$direct tun=''${tun:-ERR} sel=''${sel:-?} sb=''${sb:--} load=''${load:-?}$vls nks[sb]=''${nsb:-?} ru[sb]=''${rsb:-?} nks[rtr]=''${nrtr:-?} nks[doh]=''${ndoh:-?} site=''${site:-ERR}"

      # --- L2/DHCP state, logged only on change (the "before" timeline) ------
      # gateway ARP entry + DHCP router/DNS; NET line only when it differs from
      # the previous tick. last_good_snap keeps the most recent snapshot taken
      # while the gw still answered, so the incident dump can show before->after.
      link_snap=$(link_snapshot "$iface" "$gw" "$link" "$myip" "$ssid")
      if [ "$link_snap" != "$prev_link_snap" ]; then
        echo "$ts NET $link_snap"
        prev_link_snap="$link_snap"
      fi
      # Under quiet there is no OK verdict to key on, and freezing last_good_snap
      # at the last pre-quiet tick would hand a dump from hours ago as "before".
      # The direct probe stands in: it traverses the same gateway, so a healthy
      # one means the link was good at THIS tick.
      case "$gwst" in
        OK*) last_good_snap="$link_snap" ;;
        QUIET) case "$direct" in OK*) last_good_snap="$link_snap" ;; esac ;;
      esac

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
        QUIET)
          # Quiet must not cost the daemon its reason to exist. With the gw ping
          # withheld gwst never reaches FAIL, so the branch above goes dark and
          # nothing freezes the ring at a drop — exactly the incident the quiet
          # capture is being gathered FOR would be the one not captured. The
          # direct probe is the stand-in trigger: TCP :443 to 1.1.1.1 bound to
          # the physical interface routes through this same gateway, so its
          # failure is the gateway path dying, observed without adding one
          # packet addressed at the gateway. The dump it fires is itself quiet
          # (the force-arp inside is skipped, see gw_incident_dump).
          case "$direct" in
            OK*) gw_incident=0 ;;
            *)
              if [ "$gw_incident" = 0 ]; then
                gw_incident=1
                gw_incident_dump "$ts" "$iface" "$gw" "$last_good_snap" &
              fi
              ;;
          esac
          ;;
        *)
          gw_incident=0
          ;;
      esac

      # Physical-network switch: the gateway changed to a DIFFERENT real gw
      # between ticks (Wi-Fi dropped and macOS fell over to e.g. the iPhone
      # hotspot). gwst never shows FAIL here — a new gw answers — so the
      # FAIL-gated GWD dump above misses it entirely. This is the exact blind
      # spot a fast ROUTER-side drop falls into: the router silently stops
      # answering, the Mac fails over within one tick, and with no CoreCapture
      # the capture-gated branch below is also silent (observed 2026-07-15
      # 12:02:18 — the coworking gw stopped answering a live 1/s ping at a hard
      # ~2-min mark; only the pcap ring, frozen by hand, caught it). So freeze
      # the ring UNCONDITIONALLY on any gw change — it holds the old gw going
      # silent, and a voluntary switch just freezes a harmless extra capture
      # (cheap, pruned to 12). The wifi_capture_dump stays gated on a fresh
      # CoreCapture, which still discriminates an involuntary RF drop from a
      # manual switch.
      if [ -n "$gw" ] && [ -n "$prev_gw" ] && [ "$gw" != "$prev_gw" ]; then
        freeze_pcap "$ts" GWCHG &
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
            # Kept in lockstep with users/gurinderu/fakeip-range.nix (172.24.0.0/14).
            *172.2[4-7].* | *fc00:*)
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
      # The wedge signature alone does NOT justify a restart: `tun` is a curl
      # with a 4s budget, and under host load a perfectly healthy tunnel blows
      # past it (2026-07-30, measured on the Mac: gstatic 0.94s and youtube
      # 3.34s at load 65, against ~0.1s idle). Restarting then is actively
      # harmful — it tears down every live flow and the fresh process is just
      # as starved, so the kick repeats on the backoff forever. That is what
      # 2026-07-27 00:26->09:06 was: 99 kicks, 12-13 restarts an hour for nine
      # hours, every one logging "tunnel dead 7 ticks", none curing anything.
      # Across 7401 ticks the split is unambiguous: at load1 >= 64 half the
      # probes fail (51.6%) with even the direct path inflated 7x, while the
      # 8-32 band is essentially clean (0-0.4%) — so genuine wedges are the
      # low-load failures, and above the threshold a restart is the wrong tool.
      # Gate on load1 and the watchdog goes back to covering only the case it
      # was built for (a stale interface monitor on an otherwise idle host).
      # A kick that WORKED is followed by a healthy tun probe within the 5-min
      # backoff; a kick that didn't means the outage is not a process wedge
      # (fleet-side block, hostile network) and another restart won't help
      # either. kick_streak counts kicks not yet vindicated by a 204, and the
      # backoff below doubles with it: 5, 10, 20, 40, then 60 min. Replayed
      # against 2026-07-27 (fleet block, load normal, sel frozen): 100 kicks
      # under the flat 5-min backoff become ~11. Beyond the user-visible
      # blips, every restart also tears down and recreates a utun — and the
      # 2026-09-03 kernel panic (m_copym_with_hdrs, uipc_mbuf.c) hit the
      # kernel's mbuf path with utun15 already in the interface list, so
      # utun churn is exposure, not just noise. The streak resets on any tick
      # whose tun probe succeeds — including the false 204 that a MISSING
      # sing-box job produces (no TUN routes, curl goes out the physical NIC);
      # that state is repaired by the bootstrap block below, and a stale
      # streak there would only delay the first kick after repair.
      if [ "$tun" = "204" ]; then
        kick_streak=0
      fi
      if [ "$wedge_ticks" -ge 3 ] && [ ! -f /var/lib/net-observer/watchdog-off ]; then
        now_s=$(/bin/date +%s)
        shift_n=$kick_streak
        [ "$shift_n" -gt 4 ] && shift_n=4
        backoff=$((300 << shift_n))
        [ "$backoff" -gt 3600 ] && backoff=3600
        if [ $((now_s - last_kick)) -ge "$backoff" ]; then
          if /usr/bin/awk "BEGIN { exit !($load1 < 16) }" 2>/dev/null; then
            echo "$ts ACT tunnel dead $wedge_ticks ticks, direct path up -> kickstart sing-box (streak $kick_streak, backoff ''${backoff}s)"
            /bin/launchctl kickstart -k system/org.nixos.sing-box \
              || echo "$ts ACT kickstart failed -- job not loaded? the bootstrap repair below will pick it up"
            kick_streak=$((kick_streak + 1))
            last_kick=$now_s
            wedge_ticks=0
          elif [ $((now_s - last_skip)) -ge 300 ]; then
            # Deliberately leaves last_kick and wedge_ticks alone: the moment
            # load drops the next tick kicks immediately, with no backoff to
            # wait out. last_skip only rate-limits this line to one per 5 min.
            echo "$ts ACT suppressed: tunnel dead $wedge_ticks ticks but load1=$load1 -> host starvation, restart would not cure it"
            last_skip=$now_s
          fi
        fi
      fi

      # Job-gone repair. KeepAlive only respawns a service that is still
      # LOADED; two observed ways the service stops existing at all are a
      # manual `launchctl bootout` never followed by a bootstrap (2026-09-05:
      # tunnel down ~25 min until diagnosed by hand) and macOS BTM silently
      # disallowing the job so activation's bootstrap loads nothing
      # (2026-09-03, see ./btm-check.nix). In both states the wedge watchdog
      # above is BLIND: with no TUN routes the tun curl goes straight out the
      # physical NIC and returns 204, so wedge_ticks never accumulates. The
      # reliable signal is the process being gone: sb= empty for 3+ ticks,
      # while a normal restart's lsof-on-cache.db wait keeps sb= empty for at
      # most ~2 ticks. Guarded by `launchctl print` so a loaded-but-
      # crash-looping job (launchd's problem, not ours) is left alone, and by
      # the same watchdog-off flag as the kick path.
      case "$sb" in
        "") sb_gone_ticks=$((sb_gone_ticks + 1)) ;;
        *) sb_gone_ticks=0 ;;
      esac
      if [ "$sb_gone_ticks" -ge 3 ] && [ ! -f /var/lib/net-observer/watchdog-off ]; then
        now_s=$(/bin/date +%s)
        if [ $((now_s - last_bootstrap)) -ge 300 ] \
          && ! /bin/launchctl print system/org.nixos.sing-box >/dev/null 2>&1; then
          last_bootstrap=$now_s
          if out=$(/bin/launchctl bootstrap system /Library/LaunchDaemons/org.nixos.sing-box.plist 2>&1); then
            echo "$ts ACT sing-box job was not loaded (bootout without bootstrap, or BTM) -> bootstrapped"
          else
            # error 5 ("Input/output error") here is BTM's refusal signature —
            # nothing this daemon can override; a human has to flip the toggle
            # in System Settings -> General -> Login Items & Extensions. Put it
            # on screen (root can't post a notification directly; asuser as
            # the console user can), rate-limited to one per 30 min.
            echo "$ts ACT sing-box job gone and bootstrap FAILED: $out"
            cuid=$(/usr/bin/stat -f %u /dev/console 2>/dev/null)
            if [ -n "$cuid" ] && [ "$cuid" != "0" ] && [ $((now_s - last_btm_notify)) -ge 1800 ]; then
              last_btm_notify=$now_s
              /bin/launchctl asuser "$cuid" /usr/bin/osascript \
                -e 'display notification "sing-box launchd job is gone and bootstrap failed (BTM?). VPN is down until re-enabled in System Settings." with title "net-observer"' \
                2>/dev/null || true
            fi
          fi
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
