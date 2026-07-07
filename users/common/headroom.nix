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
# Claude Code cancels (Esc to interrupt).
#
# --no-rate-limit: headroom's default TokenBucketRateLimiter (60 req/min,
# 100k tok/min) fast-fails bursts with a LOCAL 429 (never reaching Anthropic)
# to smooth traffic. Parallel workflow fan-outs (dozens of subagents, ~76k
# tokens each) blow that bucket in seconds and every shed request surfaces as
# "API Error: 429" in Claude Code — with zero real 429s from Anthropic. We do
# our own pacing, so disable the local bucket and let requests hit Anthropic
# directly (the real 5h/weekly subscription limits still apply upstream).
#
# --memory REMOVED: its server-side retrieval (headroom_retrieve) forced every
# stream:true request into a buffered stream:false upstream call. On large Opus
# outputs (20k+ tokens) that meant 200-300s of a silent connection, which
# upstream/idle timeouts reset mid-flight — surfacing as "Connection closed
# mid-response" and a doom-loop of failing retries (each retry re-ran the whole
# 300s generation). It also injected the memory tools into the cached prefix,
# busting Anthropic's native prompt cache (~1.5M cache tokens/day re-sent as
# fresh input) and so tripping the subscription's short-term rate limit (429
# "Server is temporarily limiting requests"). Persistent memory wasn't even
# resolving per-project here (memory_project_unresolved -> empty), so we paid
# the buffering cost for nothing. Dropped until it can stream.
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
      # launchd won't mkdir for us, so ensure ~/.headroom exists for the JSONL
      # request log the agent writes.
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
            "--no-rate-limit"
            "--log-file"
            "${home}/.headroom/requests.jsonl"
          ];
          RunAtLoad = true;
          KeepAlive = true;
          ThrottleInterval = 30;
          ProcessType = "Background";
          EnvironmentVariables = {
            HOME = home;
            # First run downloads the Kompress ONNX model into ~/.cache/huggingface.
            PATH = "/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin:/usr/bin:/bin";
            # Output shaper: trim model output tokens toward the learned verbosity
            # level. HOLDOUT is a FRACTION in [0,1] (not a percent): 0.2 keeps ~20%
            # of conversations unshaped for an honest A/B ("measured") number in
            # `headroom output-savings`. A value >= 1 sends everything to control.
            HEADROOM_OUTPUT_SHAPER = "1";
            HEADROOM_OUTPUT_HOLDOUT = "0.2";
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
          # JSONL request log lives under the service state dir
          # (~/.local/state/headroom), created by systemd via StateDirectory.
          StateDirectory = "headroom";
          # Output shaper (trim output tokens to the learned verbosity level);
          # HOLDOUT is a FRACTION in [0,1]: 0.2 keeps ~20% unshaped for an honest
          # A/B "measured" number (>= 1 would send everything to control).
          Environment = [
            "HEADROOM_OUTPUT_SHAPER=1"
            "HEADROOM_OUTPUT_HOLDOUT=0.2"
          ];
          # NOTE: no --code-graph here. On a global always-on proxy its cwd is /,
          # and headroom's code-graph watcher has no project-root override, so it
          # recursively watches / and fires `index_repository {"repo_path":"/"}`.
          # Code-graph is served instead by the direct Claude Code MCP (which runs
          # codebase-memory-mcp per-project in the repo cwd) + the UI daemon.
          ExecStart = "${headroom}/bin/headroom proxy --host 127.0.0.1 --port 8788 --no-http2 --no-rate-limit --log-file %S/headroom/requests.jsonl";
          Restart = "on-failure";
          RestartSec = 5;
        };
        Install.WantedBy = [ "default.target" ];
      };
    })
  ];
}
