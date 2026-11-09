# NetBird CLI on cloud-vm (`netbird status`, `netbird up`). The daemon is a
# root unit owned by system-manager: ./system/netbird.nix, which also documents
# the first login. Both build the same pkgs/netbird, so the CLI always matches
# the running daemon.
{ pkgs, ... }:
{
  home.packages = [ (pkgs.callPackage ../../pkgs/netbird { }) ];
}
