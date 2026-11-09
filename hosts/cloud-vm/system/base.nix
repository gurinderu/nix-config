# What every cloud-vm's system-manager config shares.
#
# The distro keeps owning everything else; these settings make sure
# system-manager does not reach for it:
# - userborn (users.users) is on by default upstream. It would rewrite root's
#   shell to /run/system-manager/sw/bin/bash (system-manager#563), assumes
#   Debian GIDs and can hang boot with a separate /var (#479). Users and groups
#   stay the distro's (adduser, chsh from the bootstrap).
# - nix.enable stays false (the upstream default): the bootstrap writes
#   /etc/nix/nix.conf, and the daemon runs from root's nix profile.
# - No setuid wrappers and no core packages (see below), so system-manager's
#   PATH additions stay empty and the distro's binaries keep winning.
# - Rootless podman (../podman.nix) needs setuid newuidmap/newgidmap: those are
#   apt's `uidmap` (/usr/bin, installed by the bootstrap). pkgs.shadow must
#   not go into environment.systemPackages, upstream asserts against it.
#
# The services here force PATH to systemd's own default (servicePath below)
# instead of the NixOS module's store-only PATH, matching the hand-linked
# units this replaced: they call distro tools (update-ca-certificates,
# iptables, whatever netbird execs) that expect the distro userland.
{ lib, ... }:
{
  options.cloudVm.servicePath = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
    default = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
    description = "systemd's default PATH, which the units here keep.";
  };

  config = {
    nixpkgs.hostPlatform = "x86_64-linux";
    services.userborn.enable = false;
    nix.enable = false;
    # The setuid wrappers (mount, umount) and the core packages (bash,
    # nologin) upstream adds would go first on PATH via /etc/profile.d and
    # /etc/environment.d, shadowing the distro's own binaries in every login
    # shell and user service. Nothing here needs either.
    security.enableWrappers = false;
    environment.corePackages = lib.mkForce [ ];
  };

  imports = [
    ./mesh-ca.nix
    ./tailscale.nix
  ];
}
