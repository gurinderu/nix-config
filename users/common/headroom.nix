# Headroom — local context-compression proxy in front of the interactive
# `claude` CLI (loopback 127.0.0.1:8788), shrinking tool-result payloads before
# they reach api.anthropic.com. Shared across hosts: this single module emits a
# launchd agent on darwin and a systemd user service on linux, so both the mac
# and the thinkpad get it from users/common/home.nix with no per-host copy.
#
# Routing is a global session variable (home.sessionVariables), not a `claude`
# wrapper. It stays isolated from Meridian/opencode because:
#   * Meridian is a launchd agent / systemd service — it does NOT inherit shell
#     session vars, so the claude it spawns in SDK mode keeps hitting Anthropic
#     directly.
#   * opencode targets Meridian via an explicit baseURL (:3456) in opencode.json.
# So only shells (hence interactive Claude Code) pick up the proxy.
#
# Claude Code owns its OAuth (Keychain / credential store); the proxy forwards
# the auth header untouched, so no key lives here. ANTHROPIC_MODEL carries the
# [1m] suffix because Claude Code drops the 1M window behind a custom base URL
# otherwise (headroom issue #1158). We stay on the default token mode: it both
# compresses AND adaptively freezes prefixes to protect Anthropic's native prompt
# cache, so it strictly beats --mode cache (which just disables compression while
# the cache savings — being Anthropic-native — happen either way). HTTP/1.1 to
# upstream (--no-http2) avoids SSLV3_ALERT_BAD_RECORD_MAC on the many streams
# Claude Code cancels (Esc to interrupt). --memory turns on persistent
# per-project memory (sqlite-vec, one DB per workspace), and --memory-db-path
# pins the storage root so per-project DBs don't depend on the service cwd.
{
  inputs,
  pkgs,
  lib,
  config,
  ...
}:
let
  headroom = import ../../pkgs/headroom { inherit pkgs inputs; };
  home = config.home.homeDirectory;
in
# Static top-level structure (`config = mkMerge [...]`) with the platform branched
# inside mkIf — the false branch is dropped before its option (launchd on linux /
# systemd on darwin) is looked up, avoiding the infinite recursion that
# top-level optionalAttrs would cause.
{
  config = lib.mkMerge [
    {
      home.packages = [ headroom ];

      # Global routing for interactive shells. Override per-invocation any time,
      # e.g. `ANTHROPIC_BASE_URL= claude` to bypass.
      home.sessionVariables = {
        ANTHROPIC_BASE_URL = "http://127.0.0.1:8788";
        ANTHROPIC_MODEL = "claude-opus-4-8[1m]";
      };
    }

    (lib.mkIf pkgs.stdenv.isDarwin {
      # launchd won't mkdir for us, so ensure ~/.headroom exists for the memory
      # DB and the JSONL request log the agent writes.
      home.file.".headroom/.keep".text = "";

      launchd.agents.headroom = {
        enable = true;
        config = {
          ProgramArguments = [
            "${headroom}/bin/headroom"
            "proxy"
            "--host"
            "127.0.0.1"
            "--port"
            "8788"
            "--no-http2"
            "--memory"
            "--memory-db-path"
            "${home}/.headroom/memory.db"
            "--log-file"
            "${home}/.headroom/requests.jsonl"
            # Make headroom use the code graph: it shells out to the
            # codebase-memory-mcp binary on PATH. NOTE: its live-reindex watcher
            # binds to the service cwd (a global agent's cwd is not a repo root),
            # so it reuses whatever is already indexed rather than auto-reindexing.
            "--code-graph"
          ];
          RunAtLoad = true;
          KeepAlive = true;
          ThrottleInterval = 30;
          ProcessType = "Background";
          EnvironmentVariables = {
            HOME = home;
            # First run downloads the Kompress ONNX model into ~/.cache/huggingface.
            PATH = "/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin:/usr/bin:/bin";
          };
          StandardOutPath = "${home}/Library/Logs/headroom.log";
          StandardErrorPath = "${home}/Library/Logs/headroom.log";
        };
      };
    })

    (lib.mkIf pkgs.stdenv.isLinux {
      systemd.user.services.headroom = {
        Unit.Description = "Headroom — local context-compression proxy for Claude Code";
        Service = {
          Type = "simple";
          # Memory DB + JSONL request log live under the service state dir
          # (~/.local/state/headroom), created by systemd via StateDirectory.
          # --memory-db-path pins the storage root so per-project DBs
          # (memories/projects/<name>-<hash>/memory.db) don't depend on the cwd.
          StateDirectory = "headroom";
          # --code-graph: headroom shells out to codebase-memory-mcp on PATH.
          ExecStart = "${headroom}/bin/headroom proxy --host 127.0.0.1 --port 8788 --no-http2 --memory --memory-db-path %S/headroom/memory.db --log-file %S/headroom/requests.jsonl --code-graph";
          Restart = "on-failure";
          RestartSec = 5;
        };
        Install.WantedBy = [ "default.target" ];
      };
    })
  ];
}
