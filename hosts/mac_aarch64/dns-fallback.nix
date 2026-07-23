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
# reads the ACTUAL system DNS (networksetup -getdnsservers) and drives it to
# the state the current TUN reality demands:
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
# Coupling with sing-box-netreload: flipping DNS makes configd rewrite
# resolv.conf, which is sing-box-netreload's WatchPaths trigger. Left alone
# that would kickstart (kill+relaunch) the very sing-box we just recovered on
# the re-pin. set_dns() touches a flip flag that netreload honours (skips its
# kickstart if the flag is fresh) — see hosts/mac_aarch64/sing-box.nix.
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

    log() { echo "$(/bin/date '+%F %T') $1"; }

    # Current DNS of the first managed service, normalized to a space-joined
    # line (the pin, or "8.8.8.8 1.1.1.1"). set_dns always writes every
    # service together, so the first is representative. The "There aren't any
    # DNS Servers set on X." message when unset never equals a wanted value.
    current_dns() {
      /usr/sbin/networksetup -getdnsservers "''${SERVICES[0]}" \
        | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/ *$//'
    }

    # Apply DNS to every managed service. Touch FLIP first so sing-box-netreload
    # skips the kickstart it would otherwise do in response to the resolv.conf
    # rewrite we are about to cause. $1 is intentionally unquoted so a
    # multi-server value word-splits into separate networksetup arguments.
    set_dns() {
      /usr/bin/touch "$FLIP"
      for svc in "''${SERVICES[@]}"; do
        /usr/sbin/networksetup -setdnsservers "$svc" $1
      done
    }

    MISS=0
    while true; do
      if [ -e "$DISABLE" ]; then
        /bin/sleep 30
        continue
      fi
      CUR=$(current_dns)
      if /sbin/ifconfig | /usr/bin/grep -q 'inet ${tunAddressRe} '; then
        MISS=0
        if [ "$CUR" != "$WANT_PIN" ]; then
          set_dns "$WANT_PIN"
          log "TUN present, DNS was '$CUR' - re-pinned to $WANT_PIN"
        fi
      else
        MISS=$((MISS + 1))
        if [ "$MISS" -ge 4 ] && [ "$CUR" != "$WANT_FALLBACK" ]; then
          set_dns "$WANT_FALLBACK"
          log "TUN absent for $MISS checks, DNS was '$CUR' - fallback $WANT_FALLBACK engaged"
        fi
      fi
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
    StandardOutPath = "/var/log/dns-fallback.log";
    StandardErrorPath = "/var/log/dns-fallback.log";
  };
}
