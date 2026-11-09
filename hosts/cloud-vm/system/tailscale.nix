# tailscaled on cloud-vm, owned by system-manager instead of the tailscale apt
# repo. Every VM gets it (base config). The CLI on the user's PATH is the same
# pkgs.tailscale (../tailscale.nix), so client and daemon always match.
#
# Why: one version source for both VMs (they had drifted: apt 1.104.4 on
# cloud-vm-1, 1.102.4 on cloud-vm-2), bumped with the flake lock like
# everything else, instead of an apt repo outside the config.
#
# The unit mirrors the apt one (/usr/lib/systemd/system/tailscaled.service of
# the tailscale .deb): same --state/--socket, so the node keeps its identity
# from /var/lib/tailscale without a re-login; the same directories, Type,
# Restart and ordering; `--cleanup` on stop. /etc/default/tailscaled is gone:
# both VMs had FLAGS="" and the default port, so the port is set here.
#
# PATH is the distro's (cloudVm.servicePath), not the nix wrapper's: the
# nixpkgs bin/tailscaled is a shell wrapper that prepends nix iptables and
# iproute2. tailscaled shells out to iptables for its ts-* chains, and those
# must come from the same /usr/sbin/iptables (nf_tables backend here) that ufw
# and ../lo-accept.nix drive, so the unit execs the unwrapped binary. The
# build fails if nixpkgs ever drops the wrapper's .tailscaled-wrapped.
#
# X-StopOnRemoval=false: if this module is ever dropped, system-manager would
# otherwise stop tailscaled on the switch, and with it the only way in (ssh,
# mosh and osewa are allowed on tailscale0 only).
#
# Migration from apt (2026-11-09): system-manager links this unit into
# /etc/systemd/system, which shadows the .deb's /usr/lib unit of the same
# name; a switch does not restart an already running unit, so after it
# `sudo systemctl restart tailscaled` moves the daemon onto the nix binary.
# Then the package is removed with /usr/sbin/policy-rc.d returning 101 (its
# prerm would otherwise `stop tailscaled.service`, i.e. this unit; its postrm
# `mask` is a no-op while the /etc link exists), and tailscale.list plus the
# archive keyring are deleted so apt cannot bring it back. Never `apt purge
# tailscale` afterwards: dpkg keeps it in state rc, and its postrm purge runs
# `rm -rf /var/lib/tailscale` (the node key). A tailscaled restart puts its
# ts-input jump above netbird's `-i wt0 -j ACCEPT` (see ./netbird.nix); on
# cloud-vm-1 ../lo-accept.nix re-runs with it and moves the wt0 accept back
# above, no netbird restart needed.
#
# Roll back to apt: re-add the repo (https://pkgs.tailscale.com/stable/ubuntu,
# or tailscale.com/install.sh), `apt-get install tailscale`, then
# `sudo rm /etc/systemd/system/tailscaled.service
# /etc/systemd/system/system-manager.target.wants/tailscaled.service &&
# sudo systemctl daemon-reload && sudo systemctl restart tailscaled` and drop
# this module. State in /var/lib/tailscale is shared by both.
#
# Root CLI: sudo's secure_path lacks the nix profile, so use
# `sudo ~/.nix-profile/bin/tailscale up|set ...`; non-root `tailscale status`
# works as is.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  tailscaled = pkgs.runCommand "tailscaled-unwrapped-${pkgs.tailscale.version}" { } ''
    test -x ${pkgs.tailscale}/bin/.tailscaled-wrapped
    mkdir -p $out/bin
    ln -s ${pkgs.tailscale}/bin/.tailscaled-wrapped $out/bin/tailscaled
  '';
  port = 41641;
in
{
  systemd.services.tailscaled = {
    description = "Tailscale node agent";
    documentation = [ "https://tailscale.com/docs/" ];
    wants = [ "network-pre.target" ];
    after = [
      "network-pre.target"
      "NetworkManager.service"
      "systemd-resolved.service"
    ];
    wantedBy = [ "multi-user.target" ];
    environment.PATH = lib.mkForce config.cloudVm.servicePath;
    unitConfig.X-StopOnRemoval = false;
    serviceConfig = {
      Type = "notify";
      ExecStart = "${tailscaled}/bin/tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock --port=${toString port}";
      ExecStopPost = "${tailscaled}/bin/tailscaled --cleanup";
      Restart = "on-failure";
      RuntimeDirectory = "tailscale";
      RuntimeDirectoryMode = "0755";
      StateDirectory = "tailscale";
      StateDirectoryMode = "0700";
      CacheDirectory = "tailscale";
      CacheDirectoryMode = "0750";
    };
  };
}
