# Meridian (gurinderu/meridian, Rust port) — local proxy that exposes the Claude
# subscription as Anthropic/OpenAI API endpoints, so tools (opencode) can drive
# the Max subscription instead of a pay-per-token API key.
#
# The Rust port does not call Anthropic directly: it spawns the real `claude`
# CLI in SDK streaming mode, so the CLI owns the OAuth (macOS Keychain
# `Claude Code-credentials`). The proxy itself is unauthenticated, so it binds
# loopback only. `serve` takes the bind address as flags — `--host`/`--port`,
# default 8787 — so we pass `--port 3456` to keep opencode's baseURL unchanged
# (MERIDIAN_HOST/PORT only steer the `meridian profile use` CLI, not the bind).
#
# Prereq: log in once with Claude Code (`claude login` / `claude setup-token`)
# so the OAuth token exists in the Keychain for the spawned CLI to read.
{
  inputs,
  pkgs,
  pkgs-unstable,
  config,
  ...
}:
let
  meridian = inputs.meridian.packages.${pkgs.stdenv.hostPlatform.system}.default;
in
{
  home.packages = [ meridian ];

  # Run Meridian as a per-user launchd agent (the Rust flake ships no service
  # module). Binds 127.0.0.1:3456 (loopback) and needs the GUI login session to
  # reach the login Keychain and the `claude` CLI it spawns.
  launchd.agents.meridian = {
    enable = true;
    config = {
      ProgramArguments = [
        "${meridian}/bin/meridian"
        "serve"
        "--host"
        "127.0.0.1"
        "--port"
        "3456"
        # Pin the `claude` store path (same package that's on the home profile)
        # rather than relying on PATH lookup — mirrors the thinkpad host, so the
        # spawn can't silently break if claude-code leaves the profile.
        "--claude"
        "${pkgs-unstable.claude-code}/bin/claude"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 30;
      ProcessType = "Background";
      EnvironmentVariables = {
        HOME = config.home.homeDirectory;
        # Point the `meridian profile use` CLI at this instance.
        MERIDIAN_HOST = "127.0.0.1";
        MERIDIAN_PORT = "3456";
        # /usr/bin for `security` (Keychain); the per-user nix profile and the
        # system profile for the `claude` binary (now installed via nix) that
        # Meridian's auth helpers may call.
        PATH = "/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin";
      };
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/meridian.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/meridian.log";
    };
  };
}
