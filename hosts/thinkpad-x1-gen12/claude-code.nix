# Claude Code for the 0xff user on NixOS, from unstable (stable lags far behind
# its near-daily releases). This host has no pkgs-unstable module arg, so we
# instantiate it locally.
{
  inputs,
  pkgs,
  ...
}:
let
  pkgsUnstable = import inputs.nixpkgs-unstable {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
in
{
  home.packages = [ pkgsUnstable.claude-code ];
}
