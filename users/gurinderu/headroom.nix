# Headroom — local context-compression proxy in front of the interactive
# `claude` CLI. It sits between Claude Code and api.anthropic.com and shrinks
# tool-result payloads (SmartCrusher / ONNX INT8) before they burn context.
#
# Topology (Meridian is untouched and stays opencode-only):
#   opencode            -> meridian :3456 -> claude(SDK) -> api.anthropic.com
#   interactive claude  -> headroom :8788 -> api.anthropic.com
#
# Routing is a global session variable (home.sessionVariables) rather than a
# `claude` wrapper. This stays isolated from Meridian/opencode because:
#   * Meridian is a launchd agent — launchd does NOT read shell session vars,
#     only its own plist EnvironmentVariables, so the claude it spawns in SDK
#     mode never sees ANTHROPIC_BASE_URL and keeps hitting Anthropic directly.
#   * opencode targets Meridian via an explicit baseURL (:3456) in opencode.json,
#     which takes precedence over the env var.
# So only shells (hence interactive Claude Code) pick up the proxy.
#
# Claude Code owns its OAuth (macOS Keychain `Claude Code-credentials`); the
# proxy forwards the auth header untouched, so no key lives here. ANTHROPIC_MODEL
# carries the [1m] suffix because Claude Code drops the 1M window behind a custom
# base URL otherwise (headroom issue #1158).
{
  inputs,
  pkgs,
  config,
  ...
}:
let
  headroom = import ../../pkgs/headroom { inherit pkgs inputs; };
in
{
  home.packages = [ headroom ];

  # launchd won't mkdir for us, so ensure ~/.headroom exists for the memory DB
  # and the JSONL request log the agent writes below.
  home.file.".headroom/.keep".text = "";

  # Global routing for interactive shells. Override per-invocation any time, e.g.
  # `ANTHROPIC_BASE_URL= claude` to bypass, or `ANTHROPIC_MODEL=… claude`.
  home.sessionVariables = {
    ANTHROPIC_BASE_URL = "http://127.0.0.1:8788";
    ANTHROPIC_MODEL = "claude-opus-4-8[1m]";
  };

  # Run Headroom as a per-user launchd agent, loopback 127.0.0.1:8788. HTTP/1.1
  # to upstream (--no-http2): Claude Code cancels streams often (Esc to
  # interrupt), and cancelled HTTP/2 streams on a shared connection can trigger
  # SSLV3_ALERT_BAD_RECORD_MAC (see `headroom proxy --help`).
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
        # Persistent per-project memory + JSONL request log under ~/.headroom.
        # --memory-db-path pins the storage root; per-project DBs land under
        # memories/projects/<name>-<hash>/memory.db, so no cross-project bleed.
        "--memory"
        "--memory-db-path"
        "${config.home.homeDirectory}/.headroom/memory.db"
        "--log-file"
        "${config.home.homeDirectory}/.headroom/requests.jsonl"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 30;
      ProcessType = "Background";
      EnvironmentVariables = {
        HOME = config.home.homeDirectory;
        # First run downloads the Kompress ONNX model into ~/.cache/huggingface.
        PATH = "/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin:/usr/bin:/bin";
      };
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/headroom.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/headroom.log";
    };
  };
}
