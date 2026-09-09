# Emergency DNS fallback for the fail-closed pin in configuration.nix.
#
# The system DNS is pinned to sing-box's own DNS listener (networking.dns, see
# users/gurinderu/dns-pin.nix). Nothing else answers on that address, so the pin
# is fail-closed by construction. It is written into macOS SystemConfiguration
# and PERSISTS across reboots and even across nix itself dying — while the
# listener, the interface alias it binds, and the sing-box daemon do not.
# Observed 2026-07-03: a macOS update dropped the
# darwin-store LaunchDaemon, /nix never mounted, sing-box could not start
# (its start script blocks in wait4path), and the Mac was left with working
# IP connectivity but zero DNS — unrecoverable by KeepAlive or the
# net-observer watchdog, because there was no binary to restart.
#
# This daemon is the escape hatch for exactly that class of failure. It must
# survive /nix being gone, so it is deliberately primitive: the plist lives in
# /Library/LaunchDaemons (system data volume) and the whole program is an
# inline /bin/sh script using only always-present system binaries — no
# /nix/store paths anywhere in ProgramArguments.
#
# Design: a stateless reconciler, NOT a marker-based toggle. Each 30s tick it
# reads the ACTUAL DNS of every managed service (networksetup -getdnsservers,
# each service judged on its own reading) and drives it to the state the
# current TUN reality demands:
#   - TUN address present  -> DNS must equal the pin. If it does
#     not, re-pin. This self-heals the post-reboot fail-open case: an earlier
#     fallback that got baked into SystemConfiguration is corrected the moment
#     the TUN returns, with no in-memory marker needed to "remember" it.
#   - TUN absent for >= 4 consecutive checks (~2 min, long enough for wait4path
#     plus a normal boot to win the race) -> DNS must equal the public
#     fallback. If it does not, engage it.
# Deriving state from reality (rather than a /var/run marker that a reboot
# clears while the DNS setting persists) is what makes it correct across
# reboots, darwin-rebuilds, and manual edits — the earlier marker-based version
# stranded the machine fail-open after a reboot and could wedge itself into a
# zero-DNS state after a mid-incident rebuild.
#
# The ordinary wedge (sing-box process alive but stuck) keeps its existing
# recovery path — KeepAlive + the net-observer watchdog kickstart. This
# daemon only reacts to the TUN address vanishing entirely.
#
# Second, independent probe: physical-interface default route (added after
# the 2026-09-03 13:28-13:59 incident, see /var/log/net-observer.log.1). Wi-Fi
# lost its IPv4 address and default route (RTM_DELADDR, then 30 minutes of
# "default index: 0" / "arp: (no default gateway)") while the link stayed
# active and macOS never re-requested DHCP on its own; only switching
# networks recovered it. Throughout, the sing-box TUN address never moved —
# TUN liveness says nothing about whether the physical interface can reach
# the internet, only that the sing-box process is up — so the TUN probe saw
# nothing wrong and dns-fallback stayed silent while sing-box logged "no
# route to internet" for half an hour. No other daemon on the box watches for
# this state either. This probe is DNS-independent and drives its own
# escalation on its own tick counter (ROUTE_MISS, never mixed with the TUN
# probe's MISS): it never touches networking.dns — that axis stays fully
# owned by the TUN probe above — and it never kickstarts sing-box, because
# restarting a daemon that has no route to route through is pointless; that
# is netreload's job, not this one's.
#
# Reading "default route on a physical interface": sing-box's auto_route
# installs its own default-shaped entries via the TUN (0/1, 128.0/1, and
# sometimes a literal "default" through utun on this box — a live
# `netstat -rn -f inet` taken while investigating this incident showed
# exactly one non-utun "default" row via en0 alongside the utun7 halves). So
# the probe cannot just grep for the word "default"; it must specifically
# require the outgoing interface NOT be a utun (see net-observer.nix's own
# CHG-line default-route logic for the same interface convention).
#
# Coupling with sing-box-netreload: flipping DNS makes configd rewrite
# resolv.conf, which is sing-box-netreload's WatchPaths trigger. Left alone
# that would kickstart (kill+relaunch) the very sing-box we just recovered on
# the re-pin. reconcile_dns() touches a flip flag before each write that
# netreload honours (skips its kickstart if the flag is fresh) — see
# hosts/mac_aarch64/sing-box.nix.
#
# Manual override: `touch /var/run/dns-fallback.disabled` makes the daemon
# idle (it stops reconciling), so a repair session can hand-set DNS without
# the daemon fighting it. The flag is on tmpfs, so a reboot re-arms protection.
#
# Trade-off, eyes open: while the fallback is engaged, DNS queries go to
# public resolvers over the RU consumer network — fakeip routing, ECH
# blocking and the ts.net rule do not apply, and answers for RKN-blocked
# domains may be poisoned. A degraded resolver beats no resolver: the
# alternative (2026-07-03) was a Mac that cannot even download the tools to
# repair itself.
{ config, lib, ... }:
let
  # Single source of truth: the pin set in configuration.nix.
  wantDns = lib.head config.networking.dns;
  # Dots escaped for the ifconfig alias check in ensure_pin_alias, same
  # convention as tunAddressRe below.
  wantDnsRe = lib.replaceStrings [ "." ] [ "\\." ] wantDns;
  # The fakeip pool, for the AWDL collision guard in the loop below. The guard
  # tests membership with the derived shell globs, NOT an external interpreter:
  # this daemon must keep working with /nix gone, and /usr/bin/python3 (the
  # previous test) is a CLT shim that dies with the CLT after a macOS update —
  # which silently turned the guard into a no-op via its `|| continue`.
  fakeip = import ../../users/gurinderu/fakeip-range.nix;
  fakeipGlob = lib.concatStringsSep " | " fakeip.shellGlobs;
  # Liveness probe for sing-box. NOT the same address as the pin any more: the
  # pin is an interface alias installed by sing-box's start script
  # (./sing-box.nix), so it is present whether or not sing-box is healthy and
  # says nothing about it. The TUN
  # address does — it exists only while sing-box is running. Keep in sync with
  # the tun inbound in users/gurinderu/sing-box-config.nix (172.19.0.1/30).
  tunAddress = "172.19.0.1";
  # Dots escaped for the ifconfig regex so "172.19.0.1" cannot match e.g.
  # "172x19y0z1" on some unrelated interface.
  tunAddressRe = lib.replaceStrings [ "." ] [ "\\." ] tunAddress;
  fallbackDns = "8.8.8.8 1.1.1.1";
  # networksetup wants the UI service names, same list as knownNetworkServices.
  servicesArr = lib.concatMapStringsSep " " lib.escapeShellArg config.networking.knownNetworkServices;
  script = ''
    FLIP=/var/run/dns-fallback.flip
    DISABLE=/var/run/dns-fallback.disabled
    SERVICES=(${servicesArr})
    WANT_PIN="${wantDns}"
    WANT_FALLBACK="${fallbackDns}"

    log() { printf '%s %s\n' "$(/bin/date '+%F %T')" "$1"; }

    # The managed services macOS currently recognizes, one per line.
    #
    # A service disappears from the system entirely when its hardware is absent:
    # unplug the USB Ethernet dongle and "USB 10/100/1000 LAN" is gone, so every
    # networksetup call naming it fails with "is not a recognized network
    # service" + "** Error: The parameters were not valid." That is two lines of
    # noise per absent service per write pass, which drowned the real log and hid
    # genuine failures (observed 2026-07-24).
    #
    # Recomputed on each call rather than once at startup: this daemon runs
    # forever (KeepAlive), so a dongle plugged in later must start having its DNS
    # managed without waiting for a restart.
    #
    # -listallnetworkservices leads with an explanatory header line and prefixes
    # DISABLED services with "*": drop the header, strip the marker. A disabled
    # but present service still matches — it is configurable, so it should still
    # be pinned.
    live_services() {
      all=$(/usr/sbin/networksetup -listallnetworkservices 2>/dev/null \
        | /usr/bin/tail -n +2 | /usr/bin/sed 's/^\*//')
      for svc in "''${SERVICES[@]}"; do
        printf '%s\n' "$all" | /usr/bin/grep -qxF "$svc" && printf '%s\n' "$svc"
      done
    }

    # Current DNS of ONE managed service, normalized to a space-joined line
    # (the pin, or "8.8.8.8 1.1.1.1"). The "There aren't any DNS Servers set
    # on X." message when unset never equals a wanted value. Non-zero exit
    # when the reading itself failed (networksetup errored) — the caller must
    # skip such a service, never reconcile against a reading that did not
    # happen (an empty read would otherwise count as a mismatch and trigger
    # a write; concrete on this box: ENOSPC broke networksetup 2026-09-02..04).
    service_dns() {
      out=$(/usr/sbin/networksetup -getdnsservers "$1" 2>/dev/null) || return 1
      printf '%s\n' "$out" | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/ *$//'
    }

    # A service's device name ("Wi-Fi" -> en0), same -listnetworkserviceorder
    # parse as the alias loop in sing-box's start script (./sing-box.nix).
    service_device() {
      /usr/sbin/networksetup -listnetworkserviceorder 2>/dev/null \
        | /usr/bin/grep -A1 "^([0-9]*) $1\$" \
        | /usr/bin/sed -n 's/.*Device: \([^)]*\)).*/\1/p'
    }

    # The pin's invariant (users/gurinderu/dns-pin.nix): a scoped query to the
    # pin address is deliverable only on an interface that OWNS the address as
    # an alias. The alias is normally installed by sing-box's start script,
    # which resolves devices at that one moment — so a service catching up
    # LATER (USB dongle on first attach, a re-created service: exactly the
    # population reconcile_dns exists for) has no alias, and pinning its DNS
    # without one would kill its scoped lookups outright, a worse hole than
    # the DHCP bypass being fixed. So the alias is a reconciled PRECONDITION
    # of a pin write: verify it, install it if missing (same keyword-netmask
    # ifconfig idiom as the start script), and refuse the write when it
    # cannot be ensured — a loud unpinned service beats a silently dead one.
    ensure_pin_alias() {
      dev=$(service_device "$1")
      if [ -z "$dev" ]; then
        log "WARNING: no device for '$1' - not pinning (cannot verify the ${wantDns} alias)"
        return 1
      fi
      /sbin/ifconfig "$dev" 2>/dev/null | /usr/bin/grep -q 'inet ${wantDnsRe} ' && return 0
      if /sbin/ifconfig "$dev" alias ${wantDns} netmask 255.255.255.255 2>/dev/null; then
        log "installed pin alias ${wantDns} on $dev ('$1')"
        return 0
      fi
      log "WARNING: could not install pin alias ${wantDns} on $dev ('$1') - not pinning (scoped DNS would go dark)"
      return 1
    }

    # Drive every service in $LIVE to the wanted DNS ($1), each judged by its
    # OWN current reading. The earlier single-reading version treated the
    # first service as representative of all and wrote all-or-nothing, which
    # had a hole: a service catching up later with a different setting — a
    # USB dongle on its first attach, a re-created service, a hand-reset one
    # — comes up on DHCP DNS and can become primary, a silent sing-box bypass
    # (with RKN-poisoned answers on this network) that a matching first
    # service hid indefinitely. Per-service compare closes it, and only
    # mismatched services are written, so a healthy tick performs no writes.
    # An UNREADABLE service is skipped, never written: a failed read must not
    # count as a mismatch. A pin write additionally requires the alias
    # precondition (ensure_pin_alias above); the fallback target is a public
    # resolver, reachable from any interface, so it has no such precondition.
    # FLIP is touched before each write so sing-box-netreload skips the
    # kickstart it would otherwise do in response to the resolv.conf rewrite
    # the write causes. $1 is intentionally unquoted at the networksetup call
    # so a multi-server value word-splits into separate arguments. $2 labels
    # the log line with the branch's reason. The read loop is a pipeline
    # subshell, which is fine here: it only performs side effects. A failed
    # write logs FAILED — this log is what a /nix-dead repair session reads,
    # and a confident "set to" line over a rejected write would misreport the
    # one state that matters then.
    reconcile_dns() {
      printf '%s\n' "$LIVE" | while IFS= read -r svc; do
        cur=$(service_dns "$svc") || continue
        [ "$cur" = "$1" ] && continue
        if [ "$1" = "$WANT_PIN" ]; then
          ensure_pin_alias "$svc" || continue
        fi
        /usr/bin/touch "$FLIP"
        if /usr/sbin/networksetup -setdnsservers "$svc" $1; then
          log "$2, DNS on '$svc' was '$cur' - set to $1"
        else
          log "$2, DNS on '$svc' was '$cur' - FAILED to set $1"
        fi
      done
    }

    # Physical-interface default route: the first line of `netstat -rn -f
    # inet` whose destination is literally "default" and whose interface
    # column does not start with "utun" (sing-box's auto_route entries, incl.
    # its own utun "default" halves/whole, must not count as a live route).
    # awk exits 0 with empty output when nothing matches, which is exactly
    # "no physical default route" - no separate not-found branch needed.
    # Piped from netstat rather than `route -n get default` because that only
    # ever reports the single highest-priority default (may be the utun one),
    # while we need to know whether a non-utun default exists at all.
    phys_default() {
      /usr/sbin/netstat -rn -f inet 2>/dev/null \
        | /usr/bin/awk '$1 == "default" && $4 !~ /^utun/ { print $2, $4; exit }'
    }

    # Wi-Fi hardware port's device name (e.g. en0), resolved fresh each call
    # rather than hardcoded: the port-to-device mapping is not guaranteed
    # stable across hardware/macOS changes, and this daemon runs forever.
    wifi_device() {
      /usr/sbin/networksetup -listallhardwareports 2>/dev/null \
        | /usr/bin/awk '/^Hardware Port: Wi-Fi$/ { getline; print $2 }'
    }

    MISS=0
    ROUTE_MISS=0
    ROUTE_COOLDOWN=0
    while true; do
      if [ -e "$DISABLE" ]; then
        /bin/sleep 30
        continue
      fi
      # No managed service exists at all right now (Wi-Fi hardware off and no
      # dongle attached). There is nothing to reconcile, and MISS must not
      # advance on a tick we were unable to read — otherwise the fallback
      # would "engage" against a machine that has no interface to set it on.
      LIVE=$(live_services)
      if [ -z "$LIVE" ]; then
        /bin/sleep 30
        continue
      fi
      if /sbin/ifconfig | /usr/bin/grep -q 'inet ${tunAddressRe} '; then
        MISS=0
        reconcile_dns "$WANT_PIN" "TUN present, re-pinning"
      else
        MISS=$((MISS + 1))
        if [ "$MISS" -ge 4 ]; then
          reconcile_dns "$WANT_FALLBACK" "TUN absent for $MISS checks, engaging fallback"
        fi
      fi

      # Second, DNS-independent axis: physical default route. `|| true` on
      # every probe here so a transient netstat/networksetup hiccup under
      # `set -e`-like discipline never kills the whole reconcile loop (this
      # daemon has no set -e, but the probes are written to survive one
      # regardless, since a failing pipeline element under other shells'
      # differing pipefail defaults must not abort the tick).
      PD=$(phys_default || true)
      if [ -n "$PD" ]; then
        if [ "$ROUTE_MISS" -ge 4 ]; then
          PGW=$(printf '%s\n' "$PD" | /usr/bin/awk '{print $1}')
          PIF=$(printf '%s\n' "$PD" | /usr/bin/awk '{print $2}')
          log "default route back via $PGW dev $PIF after $ROUTE_MISS checks"
        fi
        ROUTE_MISS=0
        [ "$ROUTE_COOLDOWN" -gt 0 ] && ROUTE_COOLDOWN=$((ROUTE_COOLDOWN - 1))
      else
        ROUTE_MISS=$((ROUTE_MISS + 1))
        [ "$ROUTE_COOLDOWN" -gt 0 ] && ROUTE_COOLDOWN=$((ROUTE_COOLDOWN - 1))
        WDEV=$(wifi_device || true)
        LINK=inactive
        if [ -n "$WDEV" ] && /sbin/ifconfig "$WDEV" 2>/dev/null | /usr/bin/grep -q 'status: active'; then
          LINK=active
        fi
        if [ "$ROUTE_MISS" -eq 4 ]; then
          log "default route absent for $ROUTE_MISS checks, link=$LINK dev=''${WDEV:-unknown}"
        fi
        if [ "$ROUTE_MISS" -ge 8 ] && [ "$LINK" = active ] && [ "$ROUTE_COOLDOWN" -eq 0 ]; then
          if [ -n "$WDEV" ]; then
            log "default route absent for $ROUTE_MISS checks, link active - cycling Wi-Fi ($WDEV)"
            /usr/sbin/networksetup -setairportpower "$WDEV" off || true
            /bin/sleep 2
            /usr/sbin/networksetup -setairportpower "$WDEV" on || true
            ROUTE_COOLDOWN=20
          else
            log "default route absent for $ROUTE_MISS checks, link active - no Wi-Fi device found, cannot cycle"
          fi
        elif [ "$ROUTE_MISS" -ge 8 ] && [ "$LINK" != active ]; then
          if [ $((ROUTE_MISS % 8)) -eq 0 ]; then
            log "default route absent for $ROUTE_MISS checks, link=$LINK - not our zone, no action"
          fi
        fi
      fi

      # --- AWDL fakeip-collision guard ---------------------------------------
      # macOS hands Apple's peer-to-peer interfaces (awdl0/llw0: AirDrop,
      # AirPlay, Handoff, Sidecar, Instant Hotspot discovery) a self-assigned
      # IPv4 address, and its allocator has now collided with the fakeip pool
      # THREE times across two unrelated blocks: awdl0 took 198.18.2.58/24
      # (2026-09-01), then 198.19.2.0/24 (2026-09-03, inside the very /16
      # carved out to dodge the first), then 172.24.1.235/16 (2026-09-05,
      # inside the RFC1918 range the pool had moved to precisely to escape
      # that class of bug — users/gurinderu/fakeip-range.nix tells the story).
      # A connected route on awdl0 beats the TUN's aggregate chunk routes for
      # the whole claimed subnet, so every fakeip inside it dies instantly
      # (no-route in ~3ms) — and since the pool allocates sequentially from
      # the bottom, a /16 claim at 172.24.x kills effectively every
      # frequently-used domain at once. The user's long-standing manual
      # `ifconfig awdl0 down` ritual was treating exactly this without
      # knowing why. Range-hopping is demonstrably whack-a-mole, so: strip
      # the colliding alias the moment it appears. Scoped to awdl*/llw*
      # ONLY — a physical interface holding an address inside the pool means
      # a real LAN actually uses the range (the residual risk
      # fakeip-range.nix accepts), and fighting DHCP in a loop would be
      # worse than the collision, so that case is only logged. AirDrop
      # survives the strip: AWDL's transport is IPv6 link-local, the IPv4
      # alias is incidental.
      for ifc in $(/sbin/ifconfig -l); do
        case "$ifc" in
          lo0 | utun* | gif* | stf* | anpi* | bridge*) continue ;;
        esac
        for a in $(/sbin/ifconfig "$ifc" 2>/dev/null | /usr/bin/awk '/inet /{print $2}'); do
          # Pure-sh membership test on globs derived from the pool at eval
          # time (fakeip-range.nix shellGlobs) — anchored by case semantics,
          # no external interpreter (see the fakeip binding above for why).
          case "$a" in
            ${fakeipGlob}) ;;
            *) continue ;;
          esac
          case "$ifc" in
            awdl* | llw*)
              log "$ifc holds $a inside the fakeip pool ${fakeip.range} - stripping the alias (it hijacks fakeip routing)"
              /sbin/ifconfig "$ifc" -alias "$a" 2>/dev/null || true
              ;;
            *)
              log "WARNING: $ifc holds $a inside the fakeip pool ${fakeip.range} - a real network uses the range; NOT stripping, fakeips in that subnet will misroute"
              ;;
          esac
        done
      done

      /bin/sleep 30
    done
  '';
in
{
  launchd.daemons.dns-fallback.serviceConfig = {
    ProgramArguments = [
      "/bin/sh"
      "-c"
      script
    ];
    RunAtLoad = true;
    KeepAlive = true;
    ThrottleInterval = 5;
    # This daemon is the DNS repair path during exactly the load storms that
    # starve everything else — same QoS reasoning as sing-box and
    # net-observer: it must keep ticking while a Background-band build storm
    # owns the run queue.
    ProcessType = "Interactive";
    StandardOutPath = "/var/log/dns-fallback.log";
    StandardErrorPath = "/var/log/dns-fallback.log";
  };
}
