# NetBird client — WireGuard overlay mesh against a self-hosted control plane
# (netbird.infrahub.cloudless.dev). The package is a repack of upstream's macOS
# release artifacts; see pkgs/netbird/default.nix for why it is not taken from
# nixpkgs.
#
# Why a *daemon* (system, root) rather than a per-user agent: like sing-box, the
# client creates a utun interface and installs routes, which an agent running as
# the logged-in user cannot do. Both the `netbird` CLI and the GUI are only
# clients of this daemon over /var/run/netbird.sock — neither brings the tunnel
# up on its own.
#
# Started at boot (RunAtLoad) since 2026-09-05, by request — it began as a
# manual-only job. KeepAlive = SuccessfulExit=false resurrects it after a
# crash (an always-on mesh peer nobody watches must not die silently) while a
# graceful stop still sticks: netbird's service runner exits 0 on SIGTERM, so
# `launchctl kill TERM` takes the peer down and it STAYS down until the next
# boot or kickstart. If that ever turns out false in practice (TERM followed
# by an immediate respawn in netbird.out.log), drop back to KeepAlive = false
# and rely on the boot start alone. Manual control:
#
#   sudo launchctl kickstart system/org.nixos.netbird    # bring the peer up
#   sudo launchctl kill TERM system/org.nixos.netbird    # take it down
#   netbird status                                       # inspect
#   netbird-ui                                           # menu-bar app
#
# Two caveats owned deliberately with the always-on flip:
#
# - Hostile guest networks: a mesh client hole-punching without a direct path
#   sprays STUN/ICE UDP continuously, which is exactly what got this machine's
#   IP ban-cycled by the coworking MikroTik in July (then: tailscale in relay
#   mode). If the ban cycle comes back with netbird always on, the kill
#   command above is the first experiment.
# - utun churn/count: net-observer.nix documents utun churn as kernel-panic
#   exposure (2026-09-03, mbuf path); this adds one LONG-LIVED utun at boot,
#   which is the cheap end of that trade — the panic correlate is churn from
#   restart storms, not a stable extra interface.
#
# (nix-darwin prefixes daemon labels with `org.nixos.`, hence the label above
# rather than a bare `netbird`.)
#
# This replaces a hand-installed 0.69.0 from upstream's .pkg, whose own
# /Library/LaunchDaemons/netbird.plist must be removed — both jobs bind the same
# /var/run/netbird.sock and would fight over it.
{ pkgs, ... }:
let
  netbird = pkgs.callPackage ../../pkgs/netbird { };

  # Where the client keeps its profile. NOTE for the 0.69 -> 0.75 migration: the
  # default profile file moved from /var/lib/netbird/config.json to
  # /var/lib/netbird/default.json when 0.75 introduced multi-profile support.
  stateDir = "/var/lib/netbird";

  # netbird rotates and gzips client.log itself, so this needs no logrotate
  # entry (unlike the sing-box/net-observer logs in ./sing-box.nix).
  logDir = "/var/log/netbird";

  # Self-hosted control plane. Kept in sync with the direct-out bypass in
  # users/gurinderu/sing-box-config-darwin.nix — without that rule this hostname
  # resolves to a fakeip and the whole control plane is routed into the VLESS
  # proxy, so the peer can never register. (Verified 2026-07-29: a plain lookup
  # of this name returns 198.18.2.192.)
  managementUrl = "https://netbird.infrahub.cloudless.dev:443";

  start = pkgs.writeShellScript "netbird-start" ''
    mkdir -p ${stateDir} ${logDir}
    chmod 700 ${stateDir}

    # Stops netbird binding its outbound control-plane sockets straight to the
    # physical interface (the "system supports advanced routing" path). That
    # bind is what let management/signal/relay bypass the sing-box TUN entirely
    # — visible in client.log as connections from the en0 address rather than
    # the TUN's 172.19.0.1 — which put them on the direct path no route rule
    # could reach. With it off they follow the normal routing table into the
    # TUN, where the control-plane rule in users/gurinderu/sing-box-config-darwin.nix
    # sends them through the proxy. Peer/relay traffic is raw IP with no domain
    # to match, so it still falls through to direct.
    export NB_DISABLE_CUSTOM_ROUTING=true

    # Wait (bounded) for the sing-box TUN before dialing out. The control
    # plane's direct path from this network is documented broken (TLS
    # completes, nothing returns, 30s dial deadline — see the bypass rule in
    # users/gurinderu/sing-box-config-darwin.nix): the management session only
    # works THROUGH the proxy, and launchd has no daemon ordering, so an
    # unguarded boot start races sing-box onto the dead direct path and sits
    # in a retry loop (plus the STUN/ICE spray the header warns about). The
    # gate mirrors dns-fallback's TUN probe. Bounded at 5 min, then start
    # anyway: on a non-RU network the direct path is fine, and if sing-box is
    # down long-term netbird's own retries are no worse than they were before
    # this guard existed.
    i=0
    while [ "$i" -lt 300 ] && ! /sbin/ifconfig | /usr/bin/grep -q 'inet 172\.19\.0\.1 '; do
      /bin/sleep 5
      i=$((i + 5))
    done
    [ "$i" -ge 300 ] && echo "netbird-start: sing-box TUN not up after ''${i}s, starting on the direct path anyway"

    exec ${netbird}/bin/netbird service run \
      --log-level info \
      --daemon-addr unix:///var/run/netbird.sock \
      --log-file ${logDir}/client.log \
      --management-url ${managementUrl}
  '';
in
{
  # Puts `netbird` and the `netbird-ui` launcher on PATH, and — because the
  # package ships $out/Applications — makes nix-darwin rsync the signed app
  # bundle into /Applications/Nix Apps, where Spotlight and Launch Services can
  # find it.
  environment.systemPackages = [ netbird ];

  launchd.daemons.netbird.serviceConfig = {
    # Same /nix-on-a-separate-APFS-volume hazard as sing-box: launchd has no
    # ordering between daemons, so exec through /bin/wait4path (system volume,
    # always mounted) instead of spawning a store path directly. Relevant here
    # even without RunAtLoad, because a kickstart issued early in a login
    # session can still race the darwin-store mount.
    ProgramArguments = [
      "/bin/sh"
      "-c"
      "/bin/wait4path /nix/store && exec ${start}"
    ];

    # Auto-start at boot; resurrect only after a CRASH (non-zero exit), so a
    # manual TERM still sticks — see the header comment for the trade-off,
    # the verification caveat, and the hostile-network warning.
    RunAtLoad = true;
    KeepAlive = {
      SuccessfulExit = false;
    };

    StandardOutPath = "/var/log/netbird.out.log";
    StandardErrorPath = "/var/log/netbird.err.log";
  };
}
