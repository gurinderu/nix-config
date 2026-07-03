# Shared opencode configuration: the declarative ~/.config/opencode/opencode.json
# plus the craft/verstak skill modules. Both hosts — mac
# (users/gurinderu/opencode.nix) and thinkpad
# (hosts/thinkpad-x1-gen12/opencode.nix) — import this so the
# provider/model/plugin/lsp block can't silently diverge between machines. Host
# files keep only their host-specific bits (opencode package source, the
# Meridian service definition).
#
# Auth is handled by the local Meridian proxy (see ../users/gurinderu/meridian.nix
# and the thinkpad service), which bridges the Claude subscription OAuth token to
# a standard Anthropic endpoint on 127.0.0.1:3456. opencode talks to it as the
# built-in "anthropic" provider with the baseURL overridden; the api_key is a
# throwaway placeholder (the real OAuth token lives in Meridian / the Claude Code
# Keychain entry).
{
  pkgs,
  ...
}:
{
  # craft skills/agents/commands/plugin (see ./opencode-craft.nix) and
  # verstak skills (see ./opencode-verstak.nix).
  imports = [
    ./opencode-craft.nix
    ./opencode-verstak.nix
  ];

  # Declarative global config at ~/.config/opencode/opencode.json.
  xdg.configFile."opencode/opencode.json".text = builtins.toJSON {
    "$schema" = "https://opencode.ai/config.json";
    # Route the built-in anthropic provider through Meridian (loopback :3456).
    # Meridian swaps the dummy key for the real Claude subscription OAuth token.
    provider = {
      anthropic = {
        options = {
          apiKey = "dummy";
          # opencode's @ai-sdk/anthropic appends "/messages" to baseURL (the
          # default is .../v1), so the "/v1" must be here or requests 404.
          baseURL = "http://127.0.0.1:3456/v1";
        };
      };
    };
    model = "anthropic/claude-sonnet-4-6";
    plugin = [
      # Warp agent notifications: in-app/desktop alerts on opencode events.
      "@warp-dot-dev/opencode-warp"
      # superpowers: git-backed plugin that auto-registers its skill set (no
      # symlinks — the official opencode install; also satisfies craft's
      # superpowers:* deferrals). opencode/bun installs it from git at startup.
      "superpowers@git+https://github.com/obra/superpowers.git#v6.0.3"
    ];
    # nixd is already on the home profile; pin the store path so the Nix LSP
    # works regardless of PATH ordering at the time opencode starts.
    lsp = {
      nixd = {
        command = [ "${pkgs.nixd}/bin/nixd" ];
      };
    };
  };
}
