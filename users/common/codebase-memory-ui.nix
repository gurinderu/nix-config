# codebase-memory-mcp graph UI — one long-lived instance serving the HTTP graph
# visualization on 127.0.0.1:9749. Shared across hosts: this single module emits
# a launchd agent on darwin and a systemd user service on linux, so both the mac
# and the thinkpad get it from users/common/home.nix with no per-host copy.
#
# The graph store is global (~/.cache/codebase-memory-mcp/<project>.db), so this
# one server sees EVERY indexed project regardless of cwd — you switch projects
# inside the UI. Indexing is manual (auto_index is off): index the repos you want
# via the `index_repository` MCP tool or `codebase-memory-mcp cli
# index_repository ...`; they show up here automatically.
#
# codebase-memory-mcp is a stdio MCP server that exits on stdin EOF, so we hold
# stdin open with `tail -f /dev/null`. Claude Code's own per-session servers are
# separate (stdio, no --ui, no port) and write to the same store — no conflict.
{
  pkgs,
  lib,
  config,
  ...
}:
let
  cbm = pkgs.callPackage ../../pkgs/codebase-memory-mcp { };
  cmd = "${pkgs.coreutils}/bin/tail -f /dev/null | ${cbm}/bin/codebase-memory-mcp --ui=true --port=9749";
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
          ProgramArguments = [
            "/bin/sh"
            "-c"
            cmd
          ];
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
    })
    (lib.mkIf pkgs.stdenv.isLinux {
      systemd.user.services.codebase-memory-ui = {
        Unit.Description = "codebase-memory-mcp graph UI (127.0.0.1:9749)";
        Service = {
          Type = "simple";
          ExecStart = "${pkgs.bash}/bin/bash -c '${cmd}'";
          Restart = "on-failure";
          RestartSec = 5;
        };
        Install.WantedBy = [ "default.target" ];
      };
    })
  ];
}
