{ config, ... }:
{
  sops = {
    defaultSopsFile = ../../secrets/secrets.yaml;
    defaultSopsFormat = "yaml";
    age.keyFile = "/Users/gurinderu/.config/sops/age/keys.txt";
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
