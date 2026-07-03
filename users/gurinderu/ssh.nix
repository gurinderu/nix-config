{ config, ... }:
{
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    settings = {
      # `ssh nixos` from this Mac -> the NixOS laptop over Tailscale. Pinned to
      # the tailnet IP directly, NOT the hostname: bare `nixos` resolves to a
      # sing-box fakeip (198.18.x.x) and dead-ends in the proxy, and MagicDNS is
      # off on this host, so only the fixed 100.x address is reliable. Tailscale
      # IPs are stable per node, so hardcoding is safe.
      "nixos" = {
        HostName = "100.77.143.123";
        User = "0xff";
      };
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
