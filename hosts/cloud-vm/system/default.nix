# Root side of cloud-vm, via numtide/system-manager: the systemd units that
# standalone home-manager cannot own (the user side stays in ../home.nix).
#
#   cloud-vm          every VM: the mesh root CA (./mesh-ca.nix)
#   cloud-vm-netbird  the base + the NetBird client (./netbird.nix) and the
#                     loopback accept its DNS needs (./lo-accept.nix);
#                     only VMs on the NetBird mesh (cloud-vm-1)
#
#   nix run .#system-manager -- switch --flake .#cloud-vm --sudo
#
# (or .#cloud-vm-netbird). Units land in /etc/systemd/system as links into
# /etc/.system-manager-static, and every `wantedBy = [ "multi-user.target" ]`
# becomes system-manager.target, which default.target wants, so they start at
# boot. `activate` can exit 0 with a unit failed (system-manager#581): check
# `systemctl --failed` after a switch.
#
# hmConfig is the evaluated homeConfigurations.cloud-vm, so paths the user side
# owns (the sops secret, ~/.config) come from one place.
{ inputs, hmConfig }:
let
  mk =
    modules:
    inputs.system-manager.lib.makeSystemConfig {
      modules = [ ./base.nix ] ++ modules;
      specialArgs = { inherit hmConfig; };
    };
in
{
  cloud-vm = mk [ ];
  cloud-vm-netbird = mk [
    ./netbird.nix
    ./lo-accept.nix
  ];
}
