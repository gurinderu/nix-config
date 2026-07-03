# Shared home-manager base for every host/user. Hosts import this, set their
# own `home.username`/`home.stateVersion`, and add host-specific packages and
# programs on top. Only `pkgs` is required here (no unstable), so it works
# under both nix-darwin and NixOS without extra specialArgs wiring.
{ pkgs, ... }:
{
  programs.home-manager.enable = true;
  programs.starship = import ./starship.nix;
  programs.zsh = import ./zsh.nix;
  programs.neovim = import ./neovim.nix;
  programs.git = import ./git.nix;
  programs.direnv = import ./direnv.nix;
  programs.zellij.enable = true;

  # Dev CLI tools wanted on every machine. Add a tool here once and it lands on
  # both the mac and the thinkpad. Host-specific GUI apps and infra tooling
  # (docker/kubectl on mac, firefox/jetbrains/llvm on thinkpad) stay in each
  # host's own module. git/git-lfs come from programs.git above.
  home.packages = with pkgs; [
    htop
    btop
    bat
    ripgrep
    fd
    eza # `ls` alias in zsh.nix
    dust
    procs
    tokei
    prettyping # `ping` alias in zsh.nix
    fzf
    delta
    lazygit
    rustup
    sccache
    protobuf
    gh
    semgrep
    gnupg
    unzip
    wget
    nodejs
    nushell
    mc
    nixd
    pkg-config
  ];
}
