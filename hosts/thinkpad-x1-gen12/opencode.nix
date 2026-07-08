# opencode + Meridian for the 0xff user on NixOS.
#
# Meridian is now our Rust port (github:gurinderu/meridian); its flake ships no
# home-manager module, so we define the systemd user service here directly
# (mirrors the mac launchd agent). opencode comes from unstable (same pattern as
# before for claude-code); this host has no pkgs-unstable wiring so we
# instantiate it locally.
#
# The opencode.json config and the craft/verstak skill modules are shared with
# the mac host via ../../modules/opencode-config.nix.
{
  inputs,
  pkgs,
  ...
}:
let
  # opencode iterates fast; pull from unstable so we stay current.
  # This host has no pkgs-unstable module arg, so instantiate it here.
  pkgsUnstable = import inputs.nixpkgs-unstable {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  meridian = inputs.meridian.packages.${pkgs.stdenv.hostPlatform.system}.default;
in
{
  imports = [ ../../modules/opencode-config.nix ];

  # Meridian as a systemd user service, loopback 127.0.0.1:3456. The Rust port's
  # `serve` takes the bind as flags (default 8787) — pin --port 3456 so opencode's
  # baseURL is unchanged. It spawns the `claude` CLI, so give it an explicit
  # --claude path plus curl (OAuth refresh) on PATH; MERIDIAN_HOST/PORT only steer
  # the `meridian profile use` CLI.
  systemd.user.services.meridian = {
    Unit.Description = "Meridian — local Claude-subscription proxy (Anthropic/OpenAI API)";
    Service = {
      Type = "simple";
      ExecStart = "${meridian}/bin/meridian serve --host 127.0.0.1 --port 3456 --claude ${pkgsUnstable.claude-code}/bin/claude";
      Environment = [
        "MERIDIAN_HOST=127.0.0.1"
        "MERIDIAN_PORT=3456"
        "PATH=${
          pkgs.lib.makeBinPath [
            pkgsUnstable.claude-code
            pkgs.curl
            pkgs.coreutils
          ]
        }"
      ];
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "default.target" ];
  };

  home.packages = [
    meridian
    pkgsUnstable.opencode
    pkgsUnstable.claude-code
  ];
}
