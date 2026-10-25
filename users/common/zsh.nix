{ pkgs }:
{
  enable = true;
  enableCompletion = true;
  # zsh-autosuggestions is on Warp's known-incompatible list: its ghost text
  # fights Warp's own input editor, and with the plugin sourced Warp's native
  # autosuggestions/completions stop showing up (reported on the mac
  # 2026-09-25). Warp's documented fix is to gate the plugin on
  # $TERM_PROGRAM — the home-manager toggle can't express a conditional, so
  # the module option stays off and the plugin is sourced manually below.
  # Every non-Warp terminal (ssh, zellij, Terminal.app, thinkpad) keeps it.
  autosuggestion.enable = false;
  initContent = pkgs.lib.mkMerge [
    # mosh sessions land in a persistent multiplexer session, and leaving it
    # ends the mosh session: herdr's default session where herdr is installed
    # (cloud-vm, so the Moshi app can follow agents by their herdr pane),
    # otherwise the zellij session `main`. `herdr` alone attaches to the
    # default session or starts it. mosh-server sets no env var of its own, so
    # detect it as the shell's parent (`comm` is a bare name on Linux, a full
    # path on macOS — hence the glob). Only a plain `mosh host` login gets
    # here: the Moshi app runs `mosh-server new … -- sh -lc '<attach cmd>'`
    # itself, so its sessions never source .zshrc. That is what lets this
    # path load a host's desktop herdr config (hidden sidebar and tab row,
    # see hosts/cloud-vm/home.nix) when one exists. HERDR_ENV guards against
    # nesting: herdr panes keep the env the server started with. mkBefore
    # runs this ahead of oh-my-zsh, which would be thrown away by the exec
    # anyway. Plain ssh and local shells are untouched; home-manager's
    # programs.zellij zsh integration stays off, since it would auto-start
    # zellij in every shell.
    (pkgs.lib.mkBefore ''
      if [[ -o interactive && -z $ZELLIJ && -z $HERDR_ENV ]] \
          && [[ "$(ps -o comm= -p $PPID 2>/dev/null)" == *mosh-server* ]]; then
        if (( $+commands[herdr] )); then
          if [[ -r ''${XDG_CONFIG_HOME:-$HOME/.config}/herdr/desktop.toml ]]; then
            export HERDR_CONFIG_PATH=''${XDG_CONFIG_HOME:-$HOME/.config}/herdr/desktop.toml
          fi
          exec herdr
        elif (( $+commands[zellij] )); then
          exec zellij attach --create main
        fi
      fi
    '')
    ''
      if [[ $TERM_PROGRAM != "WarpTerminal" ]]; then
        source ${pkgs.zsh-autosuggestions}/share/zsh-autosuggestions/zsh-autosuggestions.zsh
      fi
    ''
  ];
  history = {
    extended = true;
    save = 50000;
    share = true;
    size = 50000;
    ignoreSpace = true;
  };
  oh-my-zsh = {
    enable = true;
    plugins = [
      "git"
      "history"
      "brew"
      "docker"
      "sudo"
    ];
  };
  shellAliases = {
    ls = "eza";
    ll = "eza -la --icons";
    ping = "prettyping";
  };
  # sccache's RUSTC_WRAPPER/SCCACHE_CACHE_SIZE moved to users/common/rust.nix,
  # where they live next to the cargo profile that makes caching possible.
}
