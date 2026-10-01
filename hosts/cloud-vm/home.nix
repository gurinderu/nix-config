# Home environment for the cloud VM. Common dev tools + zsh/git/neovim/starship/
# direnv/zellij come from ../../users/common/home.nix. Only VM-specific bits
# live here.
{ inputs, pkgs, ... }:
{
  imports = [ ../../users/common/home.nix ];

  home = {
    # Claude Code from github:ryoppippi/nix-claude-code (see the flake input).
    # From numtide's llm-agents.nix: clauth (multi-account manager / usage
    # monitor) and codegraph (semantic code-intelligence MCP for agents).
    packages = [
      inputs.nix-claude-code.packages.${pkgs.stdenv.hostPlatform.system}.claude
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.clauth
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.codegraph
    ];

    # Default login user on Ubuntu cloud images.
    username = "ubuntu";
    homeDirectory = "/home/ubuntu";
  };

  # Interactive ssh logins land in a persistent zellij session: a dropped
  # connection reattaches to the same panes on the next login, and leaving
  # zellij (detach or exit) closes the ssh shell too. Skipped inside zellij,
  # for `ssh host cmd` (not interactive, so .zshrc never runs) and on dumb
  # terminals. If zellij itself fails, the plain shell stays as a fallback.
  programs.zsh.initContent = ''
    if [[ -n $SSH_CONNECTION && -z $ZELLIJ && $TERM != dumb ]]; then
      zellij attach --create main && exit
    fi
  '';

  # Non-NixOS host: puts nix-provided XDG data/terminfo/locale where distro
  # programs look for them.
  targets.genericLinux.enable = true;

  # ~/.config/nix/nix.conf. Nix here is a single-user install owned by this
  # user, so these substituters apply without any trusted-users setup.
  # Binary caches for the agent inputs: clauth/codegraph build from source, and
  # cache.numtide.com only hits because llm-agents keeps its own nixpkgs pin.
  nix = {
    package = pkgs.nix;
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      extra-substituters = [
        "https://cache.numtide.com"
        "https://ryoppippi.cachix.org"
      ];
      extra-trusted-public-keys = [
        "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
        "ryoppippi.cachix.org-1:b2LbtWNvJeL/qb1B6TYOMK+apaCps4SCbzlPRfSQIms="
      ];
    };
  };

  home.stateVersion = "26.05";
}
