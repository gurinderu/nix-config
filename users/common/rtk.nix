# rtk — "Rust Token Killer": compresses command output (git, cargo, npm,
# docker, …) before it reaches the LLM context window, cutting 60–90% of
# tokens. Built from source in pkgs/rtk (upstream ships no flake). Shared
# across hosts via users/common/home.nix.
#
# Claude Code integration is a PreToolUse/Bash hook that transparently
# rewrites commands into their rtk equivalents. We wire it declaratively
# WITHOUT turning ~/.claude/settings.json into a read-only /nix/store symlink:
# Claude Code itself writes to that file (permissions, model, …), so a symlink
# would break "always allow" and friends. Instead a home-activation step
# idempotently merges the hook with jq, leaving the file editable. RTK.md (the
# assistant-facing reference for the meta commands the rewrite hook does NOT
# cover) is static, so it ships as a plain home.file, and a `@RTK.md` include
# is merged into ~/.claude/CLAUDE.md the same idempotent way.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  rtk = pkgs.callPackage ../../pkgs/rtk { };
in
{
  home.packages = [ rtk ];

  # Static reference for rtk's meta commands (analytics/discovery/debug) that
  # the rewrite hook doesn't intercept. Safe as a read-only store symlink.
  home.file.".claude/RTK.md".text = ''
    # RTK - Rust Token Killer

    **Usage**: Token-optimized CLI proxy (60-90% savings on dev operations)

    ## Meta Commands (always use rtk directly)

    ```bash
    rtk gain              # Show token savings analytics
    rtk gain --history    # Show command usage history with savings
    rtk discover          # Analyze Claude Code history for missed opportunities
    rtk proxy <cmd>       # Execute raw command without filtering (for debugging)
    ```

    ## Hook-Based Usage

    All other commands are automatically rewritten by the Claude Code hook.
    Example: `git status` -> `rtk git status` (transparent, 0 tokens overhead)
  '';

  # Idempotently merge the rtk PreToolUse/Bash hook into the user's existing
  # ~/.claude/settings.json (kept as a real, editable file). Any prior
  # `rtk hook claude` entry is dropped first, so re-running switch never
  # duplicates it. Also ensure ~/.claude/CLAUDE.md pulls in @RTK.md.
  home.activation.rtkClaudeHook = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    settings="$HOME/.claude/settings.json"
    hook='{"matcher":"Bash","hooks":[{"type":"command","command":"rtk hook claude"}]}'
    if [ -f "$settings" ]; then
      if ${pkgs.jq}/bin/jq --argjson h "$hook" '
            .hooks.PreToolUse = (
              ((.hooks.PreToolUse // [])
                | map(select(any(.hooks[]?; .command == "rtk hook claude") | not)))
              + [$h]
            )
          ' "$settings" > "$settings.rtk.tmp"; then
        run mv -f "$settings.rtk.tmp" "$settings"
      else
        run rm -f "$settings.rtk.tmp"
        echo "rtk: could not patch $settings (left untouched)"
      fi
    fi

    claudemd="$HOME/.claude/CLAUDE.md"
    if [ -f "$claudemd" ]; then
      ${pkgs.gnugrep}/bin/grep -qxF '@RTK.md' "$claudemd" \
        || run sh -c "printf '@RTK.md\n' >> \"$claudemd\""
    else
      run sh -c "printf '@RTK.md\n' > \"$claudemd\""
    fi
  '';
}
