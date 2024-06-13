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
    plugins = [ "git" "history" "brew" "docker" "sudo" ];
  };
  shellAliases = {
    ls = "eza";
    ll = "eza -la --icons";
    ping = "prettyping";
  };
  initExtra = ''
    source "$HOME/.sdkman/bin/sdkman-init.sh"
    export PATH=$HOME/.cargo/bin:$PATH
    export RUSTC_WRAPPER="$(which sccache)"
    export SCCACHE_CACHE_SIZE="32G"
  '';
}
