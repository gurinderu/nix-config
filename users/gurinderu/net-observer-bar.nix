# net-observer-bar — the observer's menu-bar UI (NSStatusItem + a gpui panel),
# a pure socket client of net-observerd (the daemon is wired in
# hosts/mac_aarch64/default.nix). Unlike the daemon and the CLI this binary
# CANNOT come from the nix flake: gpui's build script compiles Metal shaders
# and needs the macOS Metal Toolchain, which the nix build sandbox does not
# have — the upstream flake deliberately excludes the crate from its package
# (see the cargoBuildFlags comment there). So the binary is built BY HAND on
# this Mac from the dev tree:
#
#   cd ~/projects/my/net-observer \
#     && git checkout <the rev flake.nix pins the net-observer input to> \
#     && cargo build --release -p net-observer-bar \
#     && mkdir -p ~/.local/bin \
#     && cp target/release/net-observer-bar ~/.local/bin/
#
# and this agent only RUNS it — before it existed the bar lived exactly as
# long as the terminal it was launched from, and every reboot/deploy ended
# with "опять нету тулбара". Keep the built rev in step with the pinned
# daemon rev: the bar renders the daemon's StatusSnapshot over the IPC
# socket, and a wire-format skew presents as a confusing "offline"/garbage
# panel. The wrapper prefers the stable ~/.local/bin copy and falls back to
# the dev tree's target/{release,debug} builds so an unfinished setup still
# gets a bar; a missing binary logs and sleeps before exiting so the
# KeepAlive respawn stays quiet instead of crash-looping.
{ config, lib, ... }:
let
  home = config.home.homeDirectory;
  candidates = [
    "${home}/.local/bin/net-observer-bar"
    "${home}/projects/my/net-observer/target/release/net-observer-bar"
    "${home}/projects/my/net-observer/target/debug/net-observer-bar"
  ];
  script = ''
    for b in ${lib.concatMapStringsSep " " lib.escapeShellArg candidates}; do
      [ -x "$b" ] && exec "$b"
    done
    echo "$(/bin/date '+%F %T') no net-observer-bar binary found - build it (cargo build --release -p net-observer-bar in ~/projects/my/net-observer, needs the Metal Toolchain) and cp to ~/.local/bin/"
    /bin/sleep 300
    exit 1
  '';
in
{
  launchd.agents.net-observer-bar = {
    enable = true;
    config = {
      ProgramArguments = [
        "/bin/sh"
        "-c"
        script
      ];
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 10;
      # A menu-bar item can only exist in the Aqua (GUI login) session — in
      # any other session type NSStatusItem has no status bar to attach to.
      LimitLoadToSessionType = "Aqua";
      StandardOutPath = "${home}/Library/Logs/net-observer-bar.log";
      StandardErrorPath = "${home}/Library/Logs/net-observer-bar.log";
    };
  };
}
