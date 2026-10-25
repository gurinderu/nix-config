# moshi-hook daemon for the Moshi iOS app (agent inbox, Live Activities,
# usage, remote permission prompts). Package: pkgs/moshi-hook (repacked
# upstream release). Same shape as codebase-memory-ui.nix: one module emitting
# a systemd user service on linux and a launchd agent on darwin, so any host
# can import it. Currently imported by hosts/cloud-vm/home.nix only.
#
# Activation also runs `moshi-hook install` for the claude and codex targets
# and pins auto-update off (see home.activation.moshiHookAgents below). Still
# manual, once per host (needs a token from the phone):
#   moshi-hook pair --token <token from Moshi app>   # Settings -> Hooks
#   moshi-hook doctor
#
# The daemon reads the host identity only at startup, so one started before
# pairing stays socket-only ("no HostID") until restarted. A watcher on the
# pairing-only file (host.json in the state dir, written by `pair` / `host
# setup`) restarts it instead: moshi-hook-pairing.path + a oneshot
# `try-restart` on linux, a WatchPaths agent doing `kickstart -k` on darwin.
# config.toml is deliberately not watched: activation's `moshi-hook set`
# rewrites it on every switch, which would restart the daemon each time.
#
# Do NOT also run `moshi-hook service install`: on linux it writes its own
# ~/.config/systemd/user/moshi-hook.service, which clashes with the unit
# home-manager links at the same path (and runs a second daemon on darwin).
#
# The unit mirrors upstream's own (`service install` template: Type=simple,
# `serve`, Restart=on-failure, RestartSec=5, WorkingDirectory=%h), except PATH:
# upstream hard-codes /usr/local/bin:/usr/bin:/bin, which hides nix-provided
# tmux/zellij/git/claude from the daemon's multiplexer and session detection.
{
  pkgs,
  lib,
  config,
  ...
}:
let
  moshi-hook = pkgs.callPackage ../../pkgs/moshi-hook { };
  # Upstream's state dir: $XDG_STATE_HOME/moshi on linux, Application
  # Support on darwin. `pair` writes host.json there and nothing else does.
  hostJson =
    if pkgs.stdenv.isDarwin then
      "${config.home.homeDirectory}/Library/Application Support/Moshi/host.json"
    else
      "${config.xdg.stateHome}/moshi/host.json";
  path = lib.concatStringsSep ":" [
    "${config.home.profileDirectory}/bin"
    "/usr/local/bin"
    "/usr/bin"
    "/bin"
  ];
in
{
  config = lib.mkMerge [
    {
      home.packages = [ moshi-hook ];

      # Let upstream's own installer write the agent hooks on every switch,
      # rather than copying them into a jq merge that would drift with each
      # release. Claude: ~10 hook entries plus the moshi-plugin dir,
      # CLAUDE_CODE_PLUGIN_DIRS and the moshi-visuals skill. Codex:
      # ~/.codex/hooks.json, `[features] hooks = true` in ~/.codex/config.toml
      # and the moshi-visuals skill. Re-running is required anyway: every
      # hook command (and the plugin) embeds the binary's resolved /nix/store
      # path, so a package bump leaves them stale until `install` runs again.
      # Verified per target with a scratch HOME: idempotent (no duplicate
      # entries on re-run), leaves user hooks and config alone, and with
      # stdin on /dev/null it skips the interactive first-run prompt.
      #
      # Ordered after rtk.nix's jq merge into ~/.claude/settings.json (which
      # keeps entries it does not own), so both edits land in the same pass.
      # Nothing here manages ~/.codex, so codex needs no ordering. One
      # install per target, so a failure only warns about that agent: a
      # broken Moshi integration must not abort the whole switch.
      #
      # Also pins auto-update off. The setting lives only in
      # ~/.config/moshi/config.toml ([gateway] auto_update, no env var), and
      # owning that file via home.file would make it read-only and break
      # `moshi-hook set`. `set` edits the key in place and keeps everything
      # else, so running it here is the declarative-enough route.
      home.activation.moshiHookAgents =
        lib.hm.dag.entryAfter
          [
            "writeBoundary"
            "rtkClaudeHook"
          ]
          ''
            if ! run ${moshi-hook}/bin/moshi-hook set auto-update off </dev/null; then
              echo "moshi-hook: could not set auto-update off (continuing)" >&2
            fi
            if ! run ${moshi-hook}/bin/moshi-hook install --target claude </dev/null; then
              echo "moshi-hook: 'install --target claude' failed; Claude Code hooks not refreshed (continuing)" >&2
            fi
            if ! run ${moshi-hook}/bin/moshi-hook install --target codex </dev/null; then
              echo "moshi-hook: 'install --target codex' failed; Codex hooks not refreshed (continuing)" >&2
            fi
          '';
    }
    (lib.mkIf pkgs.stdenv.isDarwin {
      launchd.agents.moshi-hook = {
        enable = true;
        config = {
          ProgramArguments = [
            "${moshi-hook}/bin/moshi-hook"
            "serve"
          ];
          RunAtLoad = true;
          KeepAlive = true;
          ThrottleInterval = 5;
          ProcessType = "Background";
          WorkingDirectory = config.home.homeDirectory;
          EnvironmentVariables = {
            HOME = config.home.homeDirectory;
            PATH = path;
          };
          StandardOutPath = "${config.home.homeDirectory}/Library/Logs/moshi-hook.log";
          StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/moshi-hook.log";
        };
      };

      # Restart the daemon when pairing changes (see header). The label is
      # home-manager's default for launchd.agents.moshi-hook.
      launchd.agents.moshi-hook-pairing = {
        enable = true;
        config = {
          ProgramArguments = [
            "/bin/sh"
            "-c"
            "exec /bin/launchctl kickstart -k gui/$(/usr/bin/id -u)/org.nix-community.home.moshi-hook"
          ];
          WatchPaths = [ hostJson ];
          ProcessType = "Background";
        };
      };
    })
    (lib.mkIf pkgs.stdenv.isLinux {
      systemd.user.services.moshi-hook = {
        Unit = {
          Description = "Moshi hook daemon (agent hooks bridge, gateway 127.0.0.1:24543)";
          After = [ "network-online.target" ];
        };
        Service = {
          Type = "simple";
          ExecStart = "${moshi-hook}/bin/moshi-hook serve";
          Restart = "on-failure";
          RestartSec = 5;
          WorkingDirectory = "%h";
          Environment = [ "PATH=${path}" ];
        };
        Install.WantedBy = [ "default.target" ];
      };

      # Restart the daemon when pairing changes (see header). PathChanged
      # fires once the writer closes the file (or renames it into place), and
      # try-restart is a no-op while the daemon is stopped.
      systemd.user.paths.moshi-hook-pairing = {
        Unit.Description = "Restart moshi-hook when its pairing (host.json) changes";
        Path.PathChanged = hostJson;
        Install.WantedBy = [ "default.target" ];
      };
      systemd.user.services.moshi-hook-pairing = {
        Unit.Description = "Restart moshi-hook to pick up new pairing";
        Service = {
          Type = "oneshot";
          ExecStart = "${config.systemd.user.systemctlPath} --user try-restart moshi-hook.service";
        };
      };
    })
  ];
}
