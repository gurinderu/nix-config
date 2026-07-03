# Wire the craft plugin (github:gurinderu/craft) into opencode, mirroring
# craft's own `opencode/install.sh --global`: symlink craft's skills, review
# agents, and audit/triage commands into ~/.config/opencode and load the
# craft-rust workflow plugin.
#
# Source is the pinned `craft` flake input (flake = false -> the repo tree as a
# store path), so `nix flake update craft` is what advances it. Skills/agents/
# commands/plugin are read-only store symlinks. The plugin's npm deps
# (@opencode-ai/plugin, @opencode-ai/sdk) are declared in
# ~/.config/opencode/package.json so opencode runs `bun install` for them at
# startup, caching into ~/.cache/opencode/node_modules — the plugin dir itself
# never needs to be writable.
#
# Shared by both hosts (mac + thinkpad). superpowers:* deferrals in craft skills
# go inert without superpowers installed; the Rust knowledge is self-contained.
{
  lib,
  inputs,
  ...
}:
let
  craft = inputs.craft;

  isDir = _: type: type == "directory";
  isMd = name: type: type == "regular" && lib.hasSuffix ".md" name;

  # Top-level skills/: one symlink per skill dir that actually carries a SKILL.md.
  skillNames = builtins.filter (n: builtins.pathExists "${craft}/skills/${n}/SKILL.md") (
    builtins.attrNames (lib.filterAttrs isDir (builtins.readDir "${craft}/skills"))
  );
  # opencode/agents/*.md and opencode/commands/*.md: one symlink per file.
  agentFiles = builtins.attrNames (
    lib.filterAttrs isMd (builtins.readDir "${craft}/opencode/agents")
  );
  commandFiles = builtins.attrNames (
    lib.filterAttrs isMd (builtins.readDir "${craft}/opencode/commands")
  );

  links = entries: lib.listToAttrs (map (e: lib.nameValuePair e.dst { source = e.src; }) entries);
in
{
  xdg.configFile =
    (links (
      map (n: {
        dst = "opencode/skills/${n}";
        src = "${craft}/skills/${n}";
      }) skillNames
    ))
    // (links (
      map (n: {
        dst = "opencode/agents/${n}";
        src = "${craft}/opencode/agents/${n}";
      }) agentFiles
    ))
    // (links (
      map (n: {
        dst = "opencode/commands/${n}";
        src = "${craft}/opencode/commands/${n}";
      }) commandFiles
    ))
    // {
      # Whole plugin dir as one auto-loaded plugin (opencode reads plugins/*).
      "opencode/plugins/craft-rust".source = "${craft}/opencode/plugin";

      # opencode runs `bun install` against this at startup so the local plugin
      # resolves @opencode-ai/{plugin,sdk} from ~/.cache/opencode/node_modules.
      "opencode/package.json".text = builtins.toJSON {
        name = "opencode-config";
        private = true;
        dependencies = {
          "@opencode-ai/plugin" = "*";
          "@opencode-ai/sdk" = "*";
        };
      };
    };
}
