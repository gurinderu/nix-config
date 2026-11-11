# osewa server on cloud-vm: the unit, the ~/.local/bin/osewa symlink and the
# auto-update pin come from users/common/osewa-server.nix (its header explains
# each choice, enrollment and the PATH of a non-interactive ssh on this host).
# The Mac enrolls with `osewa login ubuntu@<host> --no-install --name <host>`
# (users/gurinderu/osewa.nix).
#
# What is cloud-vm's own lives outside nix: lingering for the user service
# (`sudo loginctl enable-linger ubuntu`) and the ufw rules that keep 7322
# TCP+UDP to tailscale0, both done by the bootstrap
# (hosts/cloud-vm/bootstrap.nix). osewa sets SSH_CONNECTION (ending in port
# 7322) for its sessions, so they attach to herdr like ssh and mosh logins
# (users/common/herdr.nix).
{
  imports = [ ../../users/common/osewa-server.nix ];
}
