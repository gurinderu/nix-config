# net-observer-bar — the observer's menu-bar UI (NSStatusItem + a gpui panel),
# a pure socket client of net-observerd (the daemon is wired in
# hosts/mac_aarch64/default.nix). Before this agent existed the bar lived
# exactly as long as the terminal it was launched from, and every
# reboot/deploy ended with "опять нету тулбара".
#
# Where the binary comes from, in preference order:
#
#   1. The nix-built package from the net-observer input, when the pinned rev
#      ships one. Upstream gained it with the gpui `runtime_shaders` switch
#      (shaders compile once at app launch via the system Metal framework),
#      which removed the build-time Metal Toolchain dependency that had made
#      the bar unpackageable. The reference is CONDITIONAL on the package
#      existing so an input rev predating it (e.g. main's un-pinned rev)
#      still evaluates — the agent then just falls through to the paths
#      below. With the package present the bar is always the exact rev the
#      daemon runs, which matters: they speak an IPC snapshot format, and a
#      skew presents as a confusing "offline" panel.
#
#   2. Hand-built fallbacks: ~/.local/bin, then the dev tree's
#      target/{release,debug} — reached only when no store package exists
#      (a locally hacked bar is trialled by running the dev binary
#      directly; the agent always prefers the store copy when there is
#      one, keeping the always-on bar in step with the daemon).
#
# A missing binary everywhere logs an instruction and sleeps before exiting
# so the KeepAlive respawn stays quiet instead of crash-looping.
{
  inputs,
  config,
  lib,
  pkgs,
  ...
}:
let
  home = config.home.homeDirectory;
  barPackages = inputs.net-observer.packages.${pkgs.stdenv.hostPlatform.system} or { };
  storeBar = lib.optional (
    barPackages ? net-observer-bar
  ) "${barPackages.net-observer-bar}/bin/net-observer-bar";
  candidates = storeBar ++ [
    "${home}/.local/bin/net-observer-bar"
    "${home}/projects/my/net-observer/target/release/net-observer-bar"
    "${home}/projects/my/net-observer/target/debug/net-observer-bar"
  ];
  script = ''
    for b in ${lib.concatMapStringsSep " " lib.escapeShellArg candidates}; do
      [ -x "$b" ] && exec "$b"
    done
    echo "$(/bin/date '+%F %T') no net-observer-bar binary found - pin an input rev that packages it, or build one by hand (cargo build --release -p net-observer-bar) into ~/.local/bin/"
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
