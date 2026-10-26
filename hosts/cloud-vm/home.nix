# Home environment for the cloud VM. Common dev tools + zsh/git/neovim/starship/
# direnv/zellij come from ../../users/common/home.nix. Only VM-specific bits
# live here.
{
  inputs,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    ../../users/common/home.nix
    # Moshi iOS app bridge daemon; pairing/hook install stay manual (see module).
    ../../users/common/moshi-hook.nix
    # Mac desktop notifications for herdr agents (spool hook + ssh reader).
    ./herdr-notify.nix
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
  # The clauth plugin's dashboard key and sidebar account row are repeated
  # here because this file does not inherit them from config.toml, where
  # `clauth herdr install` writes them. clauth cannot heal this read-only
  # file, so toggling its delegate_row_text knob only reaches config.toml.
  # The [keys] table makes every default letter binding also fire on the
  # Russian (ЙЦУКЕН, Mac "Russian – PC") letter at the same physical key, so
  # ctrl+b then w works with either layout on. Setting an action replaces its
  # default, so each list keeps the Latin key first. Shifted bindings take the
  # uppercase Cyrillic letter as written ("prefix+Т", not "prefix+shift+т"):
  # mosh delivers shift+т as a bare "Т", and herdr only folds ASCII capitals
  # into shift. Cyrillic letters never coincide with a Latin binding, so
  # nothing collides. config.toml carries a hand-copied [keys] table and the
  # same extra prefix+ф on clauth's binding; after changing this map, copy
  # the [keys] table of the generated desktop.toml over that one.
  xdg.configFile."herdr/desktop.toml".source = (pkgs.formats.toml { }).generate "herdr-desktop.toml" (
    let
      clauthRow = [
        [
          "state_icon"
          "workspace"
          "tab"
        ]
        [ "terminal_title_stripped" ]
        [
          "agent"
          "$clauth"
        ]
      ];
      # Character each physical key types on the Russian layout, unshifted and
      # shifted, for the keys herdr binds by default ("[" opens copy mode).
      russian = {
        a = "ф";
        b = "и";
        c = "с";
        d = "в";
        e = "у";
        g = "п";
        h = "р";
        j = "о";
        k = "л";
        l = "д";
        n = "т";
        o = "щ";
        p = "з";
        q = "й";
        r = "к";
        s = "ы";
        t = "е";
        v = "м";
        w = "ц";
        x = "ч";
        z = "я";
        "[" = "х";
      };
      russianShifted = {
        d = "В";
        g = "П";
        h = "Р";
        j = "О";
        k = "Л";
        l = "Д";
        n = "Т";
        p = "З";
        r = "К";
        t = "Е";
        w = "Ц";
        x = "Ч";
      };
      # "x" -> [ "x" "ч" ]; "shift+x" -> [ "shift+x" "Ч" ].
      withRussian =
        key:
        let
          base = lib.removePrefix "shift+" key;
        in
        [
          key
          (if base == key then russian.${key} else russianShifted.${base})
        ];
      withPrefix = map (key: "prefix+${key}");
      # herdr 0.9.5 defaults (the template in `herdr`'s binary) that use a key
      # the Russian layout moves; ?, tab, minus and 1..9 stay put.
      prefixDefaults = {
        settings = "s";
        detach = "q";
        reload_config = "shift+r";
        open_notification_target = "o";
        workspace_picker = "w";
        goto = "g";
        new_workspace = "shift+n";
        new_worktree = "shift+g";
        rename_workspace = "shift+w";
        close_workspace = "shift+d";
        new_tab = "c";
        rename_tab = "shift+t";
        previous_tab = "p";
        next_tab = "n";
        close_tab = "shift+x";
        rename_pane = "shift+p";
        edit_scrollback = "e";
        copy_mode = "[";
        focus_pane_left = "h";
        focus_pane_down = "j";
        focus_pane_up = "k";
        focus_pane_right = "l";
        swap_pane_left = "shift+h";
        swap_pane_down = "shift+j";
        swap_pane_up = "shift+k";
        swap_pane_right = "shift+l";
        split_vertical = "v";
        close_pane = "x";
        zoom = "z";
        resize_mode = "r";
        toggle_sidebar = "b";
      };
      # Navigate mode (prefix+w) takes these without the prefix.
      navigateDefaults = {
        navigate_pane_left = "h";
        navigate_pane_down = "j";
        navigate_pane_up = "k";
        navigate_pane_right = "l";
      };
    in
    {
      onboarding = false;
      keys =
        lib.mapAttrs (_: key: withPrefix (withRussian key)) prefixDefaults
        // lib.mapAttrs (_: withRussian) navigateDefaults
        // {
          command = [
            {
              key = withPrefix (withRussian "a");
              type = "plugin_action";
              command = "clauth.open";
              description = "clauth accounts";
            }
          ];
        };
      ui = {
        # Pinned (it is herdr's default today): agent notifications on the
        # Mac come from herdr-notify via Warp, so herdr must not also send
        # its own OSC 9/99 to Warp should the default ever change.
        toast.delivery = "off";
        sidebar_start_collapsed = true;
        sidebar_collapsed_mode = "hidden";
        hide_tab_bar_when_single_tab = true;
        sidebar.agents.rows_by_agent = {
          claude = clauthRow;
          codex = clauthRow;
        };
      };
    }
  );

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
