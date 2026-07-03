# Emergency DNS fallback for the fail-closed pin in configuration.nix.
#
# The system DNS is pinned to the sing-box TUN (networking.dns = 172.19.0.1).
# That pin is written into macOS SystemConfiguration and PERSISTS across
# reboots and even across nix itself dying — while the TUN routes and the
# sing-box daemon do not. Observed 2026-07-03: a macOS update dropped the
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
# Logic: if the sing-box TUN address is absent for >= 4 consecutive 30s checks
# (~2 min — long enough for wait4path plus a normal boot to win the race),
# flip DNS on the known network services to public resolvers and remember that
# in a state file under /var/run (tmpfs, so a reboot resets the state). As
# soon as the TUN reappears, restore the pin. If the daemon never touched DNS
# (no state file), it never writes anything — manual repair-session overrides
# are not fought over.
#
# The ordinary wedge (sing-box process alive but stuck) keeps its existing
# recovery path — KeepAlive + the net-observer watchdog kickstart. This
# daemon only reacts to the TUN address vanishing entirely.
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
  tunDns = lib.head config.networking.dns;
  fallbackDns = "8.8.8.8 1.1.1.1";
  # networksetup wants the UI service names, same list as knownNetworkServices.
  services = config.networking.knownNetworkServices;
  perService = dns:
    lib.concatMapStringsSep "\n      "
      (s: ''/usr/sbin/networksetup -setdnsservers "${s}" ${dns}'')
      services;
  script = ''
    STATE=/var/run/dns-fallback.engaged
    MISS=0
    while true; do
      if /sbin/ifconfig | /usr/bin/grep -q 'inet ${tunDns} '; then
        MISS=0
        if [ -f "$STATE" ]; then
          ${perService tunDns}
          rm -f "$STATE"
          echo "$(/bin/date '+%F %T') TUN back - DNS re-pinned to ${tunDns}"
        fi
      else
        MISS=$((MISS+1))
        if [ "$MISS" -ge 4 ] && [ ! -f "$STATE" ]; then
          ${perService fallbackDns}
          : > "$STATE"
          echo "$(/bin/date '+%F %T') TUN absent for $MISS checks - DNS fallback ${fallbackDns} engaged"
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
