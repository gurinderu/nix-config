# Shared home-manager base for every host/user. Hosts import this, set their
# own `home.username`/`home.stateVersion`, and add host-specific packages and
# programs on top. Only `pkgs` is required here (no unstable), so it works
# under both nix-darwin and NixOS without extra specialArgs wiring.
{ pkgs, ... }:
let
  # Code-intelligence MCP server on PATH (UI variant). See pkgs/codebase-memory-mcp.
  codebase-memory-mcp = pkgs.callPackage ../../pkgs/codebase-memory-mcp { };
in
{
  imports = [
    ./codebase-memory-ui.nix
    ./rtk.nix
    ./rust.nix
    ./ssh.nix
  ];

  programs.home-manager.enable = true;

  # User-local binaries (pipx, cargo-installed tools, ad-hoc scripts) on PATH.
  # home-manager writes this into hm-session-vars.sh, which zsh sources — the
  # nix-native equivalent of appending to ~/.profile.
  home.sessionPath = [ "$HOME/.local/bin" ];

  programs.starship = import ./starship.nix;
  programs.zsh = import ./zsh.nix { inherit pkgs; };
  programs.neovim = import ./neovim.nix;
  programs.git = import ./git.nix;
  programs.gh = import ./gh.nix;
  programs.direnv = import ./direnv.nix;
  # Tokyo Night. zellij switches dark/light when the terminal reports its
  # palette (CSI 2031, passes through ssh); `theme` is the fallback for
  # terminals that don't.
  programs.zellij = {
    enable = true;
    # Stock tokyo-night paints the focused frame green in normal mode and only
    # orange in pane/tab/resize/... modes, and the active mode ribbon shares
    # the active tab's green — easy to lose track of which mode you're in.
    # Derive "-modal" variants from zellij's bundled themes with a red
    # frame_highlight (the theme's own red) so any non-normal mode is
    # unmistakable.
    themes =
      let
        modal =
          name: red:
          pkgs.runCommand "zellij-${name}-modal.kdl" { } ''
            sed -e 's/${name} {/${name}-modal {/' \
                -e '/frame_highlight {/{n;s/base .*/base ${red}/}' \
              ${pkgs.zellij-unwrapped.src}/zellij-utils/assets/themes/${name}.kdl > $out
          '';
      in
      {
        tokyo-night-modal = modal "tokyo-night" "247 118 142";
        tokyo-night-light-modal = modal "tokyo-night-light" "140 67 81";
      };
    settings = {
      theme = "tokyo-night-modal";
      theme_dark = "tokyo-night-modal";
      theme_light = "tokyo-night-light-modal";
    };
  };

  # Dev CLI tools wanted on every machine. Add a tool here once and it lands on
  # both the mac and the thinkpad. Host-specific GUI apps and infra tooling
  # (docker/kubectl on mac, firefox/jetbrains/llvm on thinkpad) stay in each
  # host's own module. git/git-lfs come from programs.git above, gh from
  # programs.gh above.
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
    semgrep
    gnupg
    unzip
    wget
    nodejs
    nushell
    mc
    mosh # servers accept it over tailscale only (see each host's firewall)
    nixd
    pkg-config
    codebase-memory-mcp
  ];
}
