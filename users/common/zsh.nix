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
  initContent = ''
    if [[ $TERM_PROGRAM != "WarpTerminal" ]]; then
      source ${pkgs.zsh-autosuggestions}/share/zsh-autosuggestions/zsh-autosuggestions.zsh
    fi
  '';
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
