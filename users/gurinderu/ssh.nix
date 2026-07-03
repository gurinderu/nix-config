{ config, ... }:
{
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    settings = {
      "*" = {
        IdentityFile = [
          config.sops.secrets.ssh_ed25519.path
          config.sops.secrets.ssh_ed25519_2.path
          config.sops.secrets.ssh_rsa.path
        ];
        AddKeysToAgent = "yes";
      };
    };
  };
}
