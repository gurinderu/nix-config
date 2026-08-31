{ config, ... }:
{
  sops = {
    defaultSopsFile = ../../secrets/secrets.yaml;
    defaultSopsFormat = "yaml";
    age.keyFile = "/Users/gurinderu/.config/sops/age/keys.txt";
    # Keep decrypted secrets on persistent storage. The upstream default is
    # "%r/secrets.d", and on darwin `%r` expands to `getconf
    # DARWIN_USER_TEMP_DIR` (/var/folders/.../T) -- which macOS wipes on boot.
    # Every secret here is reached through a symlink chain that ends in this
    # directory (~/.ssh/id_ed25519 -> ~/.config/sops-nix/secrets/ssh_ed25519 ->
    # <mount point>/<generation>/ssh_ed25519), so after a reboot the whole chain
    # dangled and only a fresh `darwin-rebuild switch` restored it. Secrets sit
    # decrypted on disk either way -- this only stops them from evaporating.
    defaultSecretsMountPoint = "${config.xdg.stateHome}/sops-nix/secrets.d";
    secrets = {
      anthropic_api_key = { };
      ssh_ed25519 = {
        path = "/Users/gurinderu/.ssh/id_ed25519";
        mode = "0600";
      };
      ssh_ed25519_2 = {
        path = "/Users/gurinderu/.ssh/id_ed25519_2";
        mode = "0600";
      };
      ssh_rsa = {
        path = "/Users/gurinderu/.ssh/id_rsa";
        mode = "0600";
      };
      ssh_ed25519_pub = {
        path = "/Users/gurinderu/.ssh/id_ed25519.pub";
        mode = "0644";
      };
      ssh_ed25519_2_pub = {
        path = "/Users/gurinderu/.ssh/id_ed25519_2.pub";
        mode = "0644";
      };
      ssh_rsa_pub = {
        path = "/Users/gurinderu/.ssh/id_rsa.pub";
        mode = "0644";
      };
      github_token_read = { };
    };
  };
}
