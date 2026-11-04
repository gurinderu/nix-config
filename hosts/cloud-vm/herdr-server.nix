# herdr server as a systemd user unit with a memory cap.
#
# By default the first `herdr` client (the mosh login in users/common/zsh.nix,
# or the Moshi app) spawns `herdr server` itself, detached into that login's
# session scope, with no limit of its own. On 2026-10-26 one cargo test pane
# grew to 13.6G, the kernel's global OOM killer fired on the 29G, swapless
# VM, and since that server was a hand-started transient unit (OOMPolicy=stop
# by default) systemd tore down the whole unit, every pane with it.
#
# Here the server runs in its own unit, so every pane is in its cgroup:
#   * MemoryHigh=20G throttles and reclaims the cgroup before the rest of the
#     VM feels it; MemoryMax=24G makes the kernel OOM-kill inside the cgroup
#     (the biggest process, i.e. the runaway pane) before the global OOM
#     killer picks anything system-wide.
#   * OOMPolicy=continue keeps the unit, the server and the other panes up
#     after such a kill; Restart=on-failure brings the server back if the
#     server process itself dies.
#   * X-RestartIfChanged=false: a switch that changes this unit (a herdr bump
#     changes ExecStart) must not restart it, which would end every pane. The
#     new ExecStart takes effect on the next manual restart.
#
# Clients need no change: `herdr` connects to ~/.config/herdr/herdr.sock
# (from $HOME) and only spawns a server when nothing listens there. If a
# client starts while this unit is down, it spawns an unmanaged server
# again; `systemctl --user status herdr-server` and `pgrep -af 'herdr server'`
# tell which one is running.
#
# The environment mirrors what the client-spawned server had (its panes
# inherit it): PATH with the nix profile first, and HERDR_CONFIG_PATH on
# desktop.toml as the Mac's mosh login sets it. The user manager provides
# HOME, USER, SHELL, LANG, XDG_RUNTIME_DIR and SSH_AUTH_SOCK. Unlike panes
# of a login-spawned server, these carry no SSH_CONNECTION.
#
# autostart = false: the unit is defined but neither enabled nor started, so
# a switch leaves a running client-spawned server alone. Cutover (README
# "herdr server unit"): stop the old server, `systemctl --user start
# herdr-server`, then flip autostart to true and switch, which adds
# default.target.wants (linger is on, so it then comes up at boot).
# `systemctl --user enable` doesn't work for this: home-manager owns the unit
# file and, while autostart is false, it has no [Install] section.
{
  inputs,
  lib,
  pkgs,
  ...
}:
let
  herdr = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.herdr;
  autostart = false;
in
{
  systemd.user.services.herdr-server = {
    Unit = {
      Description = "herdr server (memory-capped)";
      X-RestartIfChanged = false;
    };
    Service = {
      ExecStart = "${herdr}/bin/herdr server";
      WorkingDirectory = "%h";
      Environment = [
        "PATH=%h/.nix-profile/bin:%h/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        "NIX_PROFILES=/nix/var/nix/profiles/default %h/.nix-profile"
        "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
        "HERDR_CONFIG_PATH=%h/.config/herdr/desktop.toml"
      ];
      MemoryHigh = "20G";
      MemoryMax = "24G";
      OOMPolicy = "continue";
      Restart = "on-failure";
      RestartSec = 1;
    };
    Install = lib.mkIf autostart { WantedBy = [ "default.target" ]; };
  };
}
