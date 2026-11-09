{ config, ... }:
{
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    settings = {
      # `ssh nixos` from this Mac -> the NixOS laptop over Tailscale. Pinned to
      # the tailnet IP directly, NOT the hostname: bare `nixos` resolves to a
      # sing-box fakeip (whatever pool users/gurinderu/fakeip-range.nix
      # currently holds) and dead-ends in the proxy, and MagicDNS is off on
      # this host, so only the fixed 100.x address is reliable. Tailscale
      # IPs are stable per node, so hardcoding is safe.
      "nixos" = {
        HostName = "100.77.143.123";
        User = "0xff";
      };
      # The cloud VMs by their full MagicDNS name: bare `cloud-vm-N` hits the
      # same fakeip dead end, while `*.ts.net` goes to MagicDNS through
      # sing-box (the ts.net rule in sing-box-config.nix).
      "cloud-vm-*" = {
        HostName = "%h.tail411887.ts.net";
        User = "ubuntu";
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
