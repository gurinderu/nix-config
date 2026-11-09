# `nix run github:gurinderu/nix-config#bootstrap -- [tailscale-hostname]`:
# sets up a fresh Ubuntu VM (Nix already installed) as the cloud-vm host. The
# body is ./bootstrap.sh; home-manager and system-manager are the flake's own
# pinned inputs.
{
  pkgs,
  home-manager,
  system-manager,
}:
pkgs.writeShellApplication {
  name = "bootstrap";
  runtimeInputs = with pkgs; [
    age
    coreutils
    curl
    git
    gnugrep
    gnused
  ];
  text = ''
    HOME_MANAGER=${home-manager}/bin/home-manager
    SYSTEM_MANAGER=${system-manager}/bin/system-manager
  ''
  + builtins.readFile ./bootstrap.sh;
}
