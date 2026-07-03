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

    echo "$(/bin/date '+%F %T') START net-observer"
    /bin/mkdir -p /var/lib/net-observer

    prev_snap=""
    wedge_ticks=0
    last_kick=0
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

      echo "$ts TICK if=''${iface:--} link=''${link:--} ip=''${myip:--} ssid=''${ssid:--} gw(''${gw:--})=$gwst direct[1.1.1.1]=$direct tun=''${tun:-ERR} sel=''${sel:-?} sb=''${sb:--}$vls"

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
