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
# It is deliberately NOT started automatically: RunAtLoad and KeepAlive are both
# off, so launchd loads the job at boot but leaves it stopped. Drive it by hand:
#
#   sudo launchctl kickstart system/org.nixos.netbird    # bring the peer up
#   sudo launchctl kill TERM system/org.nixos.netbird    # take it down
#   netbird status                                       # inspect
#   netbird-ui                                           # menu-bar app
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

    # Manual control, as requested: launchd loads the job but never starts it,
    # and does not resurrect it when it exits or is killed.
    RunAtLoad = false;
    KeepAlive = false;

    StandardOutPath = "/var/log/netbird.out.log";
    StandardErrorPath = "/var/log/netbird.err.log";
  };
}
