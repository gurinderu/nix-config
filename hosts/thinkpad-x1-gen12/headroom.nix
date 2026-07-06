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
      ExecStart = "${headroom}/bin/headroom proxy --host 127.0.0.1 --port 8788 --no-http2";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "default.target" ];
  };
}
