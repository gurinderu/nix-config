# Claude Code for the 0xff user on NixOS, from github:ryoppippi/nix-claude-code
# (see the flake input) — the same package cloud-vm uses (hosts/cloud-vm/
# home.nix). nixpkgs lags far behind its near-daily releases, and this pulls
# no second nixpkgs instance the way importing nixpkgs-unstable here did.
{
  inputs,
  pkgs,
  ...
}:
{
  home.packages = [ inputs.nix-claude-code.packages.${pkgs.stdenv.hostPlatform.system}.claude ];
}
