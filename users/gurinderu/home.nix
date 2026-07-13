{
  inputs,
  pkgs,
  pkgs-unstable,
  sops-nix,
  config,
  ...
}:
{
  imports = [
    ../common/home.nix
    inputs.nix-colors.homeManagerModules.default
    sops-nix.homeManagerModules.sops
    ./sops.nix
    ./ssh.nix
    ./sing-box.nix
    ./opencode.nix
    ./meridian.nix
    ./netdiag.nix
    #./zed.nix
  ];

  home = {
    username = "gurinderu";
    # Common dev tools + zsh/git/neovim/starship/direnv/zellij come from
    # ../common/home.nix. Only mac-specific packages live here.
    packages = [
      pkgs.oh-my-zsh
      pkgs.spaceship-prompt
      pkgs.docker
      pkgs.docker-compose
      pkgs.slack
      pkgs.lnav
      pkgs.kubectl
      pkgs-unstable.talosctl
      pkgs.helix
      pkgs.coreutils
      pkgs.libvirt
      pkgs.sing-box
      pkgs.hwloc
      # Claude Code from unstable (stable lags far behind its near-daily
      # releases). The in-store auto-updater is disabled; bump via nix.
      pkgs-unstable.claude-code
      #pkgs-unstable.warp-terminal
    ];
  };

  # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
  home.stateVersion = "23.11";
}
