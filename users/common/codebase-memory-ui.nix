# codebase-memory-mcp graph UI — one long-lived instance serving the HTTP graph
# visualization on 127.0.0.1:9749. Shared across hosts: this single module emits
# a launchd agent on darwin and a systemd user service on linux, so the mac, the
# thinkpad and cloud-vm all get it from users/common/home.nix with no per-host
# copy.
#
# The graph store is global (~/.cache/codebase-memory-mcp/<project>.db), so this
# one server sees EVERY indexed project regardless of cwd — you switch projects
# inside the UI. Indexing is manual (auto_index is off): index the repos you want
# via the `index_repository` MCP tool or `codebase-memory-mcp cli
# index_repository ...`; they show up here automatically.
#
# Process layout (0.12): `codebase-memory-mcp --ui=true` is only a stdio
# frontend. It spawns (or joins) the per-user daemon
# (`codebase-memory-mcp --cbm-daemon-internal`, same cgroup), and that daemon is
# what listens on 9749. The daemon lives only while it has a client, so the
# frontend must stay up as that client. The frontend exits on stdin EOF, so
# startScript points its stdin at a FIFO it holds open itself (O_RDWR, so it
# never sees EOF) and then execs. cbm is the unit's main process, with no shell
# or `tail` in front of it.
#
# The frontend does NOT notice when the daemon goes away (verified: a SIGTERM to
# the daemon logs `daemon.lifetime_end reason=stop_requested` and the frontend
# idles on, with nothing on 9749). Supervising the frontend alone is not enough,
# so a periodic check (a timer on linux, a StartInterval agent on darwin) probes
# the port and restarts the service when the UI stops answering.
#
# `--ui`/`--port` are persisted into ~/.cache/codebase-memory-mcp, so any daemon
# (one spawned by a Claude Code stdio session too) serves the UI on 9749. Claude
# Code's own per-session servers are separate stdio clients of the same daemon
# and store, so there is no conflict.
{
  pkgs,
  lib,
  config,
  ...
}:
let
  cbm = pkgs.callPackage ../../pkgs/codebase-memory-mcp { };
  port = 9749;
  url = "http://127.0.0.1:${toString port}/";

  startScript = pkgs.writeShellScript "codebase-memory-ui" ''
    set -eu
    dir=$(${pkgs.coreutils}/bin/mktemp -d)
    ${pkgs.coreutils}/bin/mkfifo "$dir/stdin"
    exec 0<>"$dir/stdin"
    ${pkgs.coreutils}/bin/rm -rf "$dir"
    exec ${cbm}/bin/codebase-memory-mcp --ui=true --port=${toString port}
  '';

  # Exit 0 when the UI answers. Retries ride out a (re)start in progress.
  probe = ''
    for _ in 1 2 3; do
      if ${pkgs.curl}/bin/curl -fsS -o /dev/null -m 5 ${url}; then
        exit 0
      fi
      ${pkgs.coreutils}/bin/sleep 10
    done
    echo "codebase-memory-ui: no answer on ${url}; restarting" >&2
  '';

  # home-manager's default label for launchd.agents.codebase-memory-ui.
  launchdTarget = "gui/$(/usr/bin/id -u)/org.nix-community.home.codebase-memory-ui";
in
# Keep the top-level structure static (`config = mkMerge [...]`) and branch the
# platform inside mkIf — the false branch is dropped before its option (launchd
# on linux / systemd on darwin) is ever looked up, and nothing here depends on
# `config`, so there is no infinite recursion.
{
  config = lib.mkMerge [
    (lib.mkIf pkgs.stdenv.isDarwin {
      launchd.agents.codebase-memory-ui = {
        enable = true;
        config = {
          ProgramArguments = [ "${startScript}" ];
          RunAtLoad = true;
          KeepAlive = true;
          ThrottleInterval = 30;
          ProcessType = "Background";
          EnvironmentVariables = {
            HOME = config.home.homeDirectory;
            PATH = "/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin:/usr/bin:/bin";
          };
          StandardOutPath = "${config.home.homeDirectory}/Library/Logs/codebase-memory-ui.log";
          StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/codebase-memory-ui.log";
        };
      };

      # Liveness probe (see header). It skips the check when the agent is not
      # loaded, and `kickstart -k` restarts the frontend and its daemon.
      launchd.agents.codebase-memory-ui-check = {
        enable = true;
        config = {
          ProgramArguments = [
            "${pkgs.writeShellScript "codebase-memory-ui-check" ''
              /bin/launchctl print ${launchdTarget} >/dev/null 2>&1 || exit 0
              ${probe}
              exec /bin/launchctl kickstart -k ${launchdTarget}
            ''}"
          ];
          StartInterval = 120;
          ProcessType = "Background";
          StandardOutPath = "${config.home.homeDirectory}/Library/Logs/codebase-memory-ui.log";
          StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/codebase-memory-ui.log";
        };
      };
    })
    (lib.mkIf pkgs.stdenv.isLinux {
      systemd.user.services.codebase-memory-ui = {
        Unit.Description = "codebase-memory-mcp graph UI (127.0.0.1:${toString port})";
        Service = {
          Type = "simple";
          ExecStart = "${startScript}";
          # Any exit of the long-lived frontend is unexpected, clean or not.
          Restart = "always";
          RestartSec = 5;
        };
        Install.WantedBy = [ "default.target" ];
      };

      # Liveness probe (see header). No-op while the service is stopped.
      systemd.user.services.codebase-memory-ui-check = {
        Unit.Description = "Restart codebase-memory-ui when its UI stops answering";
        Service = {
          Type = "oneshot";
          ExecStart = "${pkgs.writeShellScript "codebase-memory-ui-check" ''
            ${config.systemd.user.systemctlPath} --user is-active --quiet codebase-memory-ui.service || exit 0
            ${probe}
            exec ${config.systemd.user.systemctlPath} --user restart codebase-memory-ui.service
          ''}";
        };
      };
      systemd.user.timers.codebase-memory-ui-check = {
        Unit.Description = "Periodic liveness check of the codebase-memory-mcp graph UI";
        Timer = {
          OnActiveSec = "2min";
          OnUnitActiveSec = "2min";
        };
        Install.WantedBy = [ "timers.target" ];
      };
    })
  ];
}
