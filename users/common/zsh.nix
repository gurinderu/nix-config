{
  enable = true;
  enableCompletion = true;
  autosuggestion = {
    enable = true;
  };
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
  initContent = ''
    export RUSTC_WRAPPER="$(which sccache)"
    export SCCACHE_CACHE_SIZE="32G"
  '';
}
