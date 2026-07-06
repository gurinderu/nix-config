# Headroom proxy for the 0xff user on NixOS — mirrors the mac module
# (../../users/gurinderu/headroom.nix). Sits in front of the interactive
# `claude` CLI (loopback 127.0.0.1:8788) and compresses tool-result payloads
# before they reach api.anthropic.com.
#
# Routing is a global session variable (home.sessionVariables), not a wrapper.
# Meridian stays opencode-only and unaffected: it is a systemd user service, so
# the claude it spawns does not inherit shell session vars, and opencode targets
# Meridian by explicit baseURL (:3456). See the mac module for the full rationale.
{
  inputs,
  pkgs,
  ...
}:
let
  headroom = import ../../pkgs/headroom { inherit pkgs inputs; };
in
{
  home.packages = [ headroom ];

  home.sessionVariables = {
    ANTHROPIC_BASE_URL = "http://127.0.0.1:8788";
    ANTHROPIC_MODEL = "claude-opus-4-8[1m]";
  };

  # Headroom as a systemd user service, loopback 127.0.0.1:8788. HTTP/1.1 to
  # upstream (--no-http2) avoids SSLV3_ALERT_BAD_RECORD_MAC on the many cancelled
  # streams Claude Code produces (Esc to interrupt).
  systemd.user.services.headroom = {
    Unit.Description = "Headroom — local context-compression proxy for Claude Code";
    Service = {
      Type = "simple";
      # Persistent per-project memory (SQLite) + JSONL request log both live under
      # the service state dir (~/.local/state/headroom), which systemd creates for
      # us via StateDirectory. --memory-db-path pins the storage root so per-project
      # DBs (memories/projects/<name>-<hash>/memory.db) don't depend on the cwd.
      StateDirectory = "headroom";
      # --mode cache: freeze prior turns to maximise Anthropic prefix-cache hits
      # (cache savings dominate compression ~50:1 in /stats). Reversible; measure
      # via /stats before/after.
      ExecStart = "${headroom}/bin/headroom proxy --host 127.0.0.1 --port 8788 --no-http2 --mode cache --memory --memory-db-path %S/headroom/memory.db --log-file %S/headroom/requests.jsonl";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "default.target" ];
  };
}
