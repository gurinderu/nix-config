# `nix run github:gurinderu/nix-config#bootstrap -- [tailscale-hostname]`:
# sets up a fresh Ubuntu VM (Nix already installed) as the cloud-vm host. The
# body is ./bootstrap.sh; home-manager is the flake's own pinned input.
{
  pkgs,
  home-manager,
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
  ''
  + builtins.readFile ./bootstrap.sh;
}
