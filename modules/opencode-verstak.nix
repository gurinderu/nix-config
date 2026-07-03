# Wire the verstak skill set (github:verstak-ai/skills) into opencode by
# symlinking each skills/<name> dir (one that carries a SKILL.md) into
# ~/.config/opencode/skills. verstak ships ONLY skills — no opencode agents/
# commands/plugin adapter like craft has — so this module is skills-only.
#
# Source is the pinned `verstak` flake input (flake = false -> the repo tree as
# a store path), so `nix flake update verstak` is what advances it. The skill
# dirs (incl. their references/) become read-only store symlinks. Skill names
# are disjoint from craft's, so this module's xdg.configFile entries don't
# collide with opencode-craft.nix.
#
# Shared by both hosts (mac + thinkpad).
{
  lib,
  inputs,
  ...
}:
let
  verstak = inputs.verstak;

  isDir = _: type: type == "directory";

  # skills/: one symlink per skill dir that actually carries a SKILL.md.
  skillNames = builtins.filter (n: builtins.pathExists "${verstak}/skills/${n}/SKILL.md") (
    builtins.attrNames (lib.filterAttrs isDir (builtins.readDir "${verstak}/skills"))
  );
in
{
  xdg.configFile = lib.listToAttrs (
    map (n: lib.nameValuePair "opencode/skills/${n}" { source = "${verstak}/skills/${n}"; }) skillNames
  );
}
