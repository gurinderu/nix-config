# tailscale CLI on cloud-vm. The daemon is a root unit owned by
# system-manager (./system/tailscale.nix, which also covers the move off apt);
# both use the same pkgs.tailscale, so the CLI always matches the daemon.
# Root commands need the full path (sudo's secure_path lacks the nix
# profile): `sudo ~/.nix-profile/bin/tailscale set ...`.
{ pkgs, ... }:
{
  home.packages = [ pkgs.tailscale ];
}
