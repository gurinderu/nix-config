# Home environment for the cloud VM. Common dev tools + zsh/git/neovim/starship/
# direnv/zellij come from ../../users/common/home.nix. Only VM-specific bits
# live here.
{ inputs, pkgs, ... }:
{
  imports = [
    ../../users/common/home.nix
    # Moshi iOS app bridge daemon; pairing/hook install stay manual (see module).
    ../../users/common/moshi-hook.nix
    # Disabled for now, together with the warpify flake input.
    # inputs.warpify.homeManagerModules.default
  ];

  # warpify CLI + zellij plugin. The module links the wasm into the data dir,
  # adds load_plugins (with zellij:link) to programs.zellij.settings, and
  # pre-grants the plugin's permissions at activation — don't repeat any of it.
  # Disabled for now.
  # programs.warpify = {
  #   enable = true;
  #   # Every client that connects gets its own tab instead of sharing
  #   # the focused one. Applies to new zellij sessions only.
  #   onConnect = "new-tab";
  # };

  home = {
    # Claude Code from github:ryoppippi/nix-claude-code (see the flake input).
    # From numtide's llm-agents.nix: clauth (multi-account manager / usage
    # monitor), codegraph (semantic code-intelligence MCP for agents) and
    # herdr (agent-aware terminal multiplexer; not in our stable nixpkgs).
    # mosh logins attach to herdr (see users/common/zsh.nix), and the
    # moshi-hook daemon finds it on ~/.nix-profile/bin to follow agents by
    # their herdr pane.
    packages = [
      inputs.nix-claude-code.packages.${pkgs.stdenv.hostPlatform.system}.claude
      inputs.codex-cli-nix.packages.${pkgs.stdenv.hostPlatform.system}.default
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.clauth
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.codegraph
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.herdr
    ];

    # Default login user on Ubuntu cloud images.
    username = "ubuntu";
    homeDirectory = "/home/ubuntu";
  };

  # Interactive ssh logins land in a persistent zellij session: a dropped
  # connection reattaches to the same panes on the next login, and leaving
  # zellij (detach or exit) closes the ssh shell too. Skipped inside zellij
  # and herdr (whose panes inherit SSH_CONNECTION from the login that started
  # its server), for `ssh host cmd` (not interactive, so .zshrc never runs)
  # and on dumb terminals. If zellij itself fails, the plain shell stays as a
  # fallback.
  programs.zsh.initContent = ''
    if [[ -n $SSH_CONNECTION && -z $ZELLIJ && -z $HERDR_ENV && $TERM != dumb ]]; then
      zellij attach --create main && exit
    fi
  '';

  # herdr UI for the desktop: the plain mosh login from the Mac loads this
  # file via HERDR_CONFIG_PATH (users/common/zsh.nix), so Warp shows only the
  # panes. The sidebar starts collapsed to zero width (prefix+b brings it
  # back) and the tab row hides while a workspace has a single tab; herdr has
  # no setting that hides it with several tabs. These keys are read by each
  # attaching client, so the Moshi app, which attaches on its own without this
  # file, keeps the full UI (or herdr's mobile layout at phone widths).
  # ~/.config/herdr/config.toml stays unmanaged so herdr's settings UI can
  # write it; this file does not inherit from it. onboarding = false since
  # herdr would otherwise try to record finishing onboarding in this
  # read-only file.
  xdg.configFile."herdr/desktop.toml".source = (pkgs.formats.toml { }).generate "herdr-desktop.toml" {
    onboarding = false;
    ui = {
      sidebar_start_collapsed = true;
      sidebar_collapsed_mode = "hidden";
      hide_tab_bar_when_single_tab = true;
    };
  };

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
