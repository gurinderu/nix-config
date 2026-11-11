# osewa server on cloud-vm: the unit, the ~/.local/bin/osewa symlink and the
# auto-update pin come from users/common/osewa-server.nix (its header explains
# each choice, enrollment and the PATH of a non-interactive ssh on this host).
# The Mac enrolls with `osewa login ubuntu@<host> --no-install --name <host>`
# (users/gurinderu/osewa.nix).
#
# What is cloud-vm's own lives outside nix: lingering for the user service
# (`sudo loginctl enable-linger ubuntu`) and the ufw rules that keep 7322
# TCP+UDP to tailscale0, both done by the bootstrap
# (hosts/cloud-vm/bootstrap.nix). Sessions carry no SSH_CONNECTION, so the
# zellij auto-attach in home.nix stays out of them.
{
  imports = [ ../../users/common/osewa-server.nix ];
}
