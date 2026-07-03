# opencode (anomalyco/opencode) — open-source terminal AI coding agent.
# Pulled from nixpkgs-unstable so we track releases that land there before stable.
#
# The shared provider/model/plugin/lsp config and the craft/verstak skill
# modules live in ../../modules/opencode-config.nix (imported below) so this host
# and the thinkpad host can't diverge. Only the package source is host-specific.
{
  pkgs-unstable,
  ...
}:
{
  imports = [ ../../modules/opencode-config.nix ];

  home.packages = [ pkgs-unstable.opencode ];
}
