# tailscale CLI on cloud-vm. The daemon is a root unit owned by
# system-manager (./system/tailscale.nix, which also covers the move off apt);
# both use the same pkgs.tailscale, so the CLI always matches the daemon.
# Root commands need the full path (sudo's secure_path lacks the nix
# profile): `sudo ~/.nix-profile/bin/tailscale set ...`.
#
# Login: the bootstrap joins a new VM to the tailnet without a browser, as
# tag:cloud-vm, from the sops secret tailscale_oauth (an OAuth client secret,
# scope auth_keys, declared in ./mesh-ca.nix and decrypted to
# ~/.config/sops-nix/secrets/tailscale_oauth). The CLI turns a `tskey-client-`
# --auth-key into a one-off auth key itself; `?ephemeral=false&preauthorized=true`
# after the secret sets that key's options. The bootstrap passes it as
# `--auth-key=file:<root-only temp file>` so it never shows up in argv.
{ pkgs, ... }:
{
  home.packages = [ pkgs.tailscale ];
}
