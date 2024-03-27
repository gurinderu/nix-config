# This is your home-manager configuration file
# Use this to configure your home environment (it replaces ~/.config/nixpkgs/home.nix)
{ inputs
, lib
, config
, pkgs
, ...
}: {
  # You can import other home-manager modules here
  imports = [
    # If you want to use home-manager modules from other flakes (such as nix-colors):
    inputs.nix-colors.homeManagerModules.default
  ];

  home = {
    username = "gurinderu";
    packages = [
      pkgs.neovim
      pkgs.zsh
      pkgs.oh-my-zsh
      pkgs.starship
      pkgs.spaceship-prompt
      pkgs.htop
      pkgs.unzip
      pkgs.wget
      pkgs.gnupg
      pkgs.mc
      pkgs.nixpkgs-fmt
      pkgs.git
      pkgs.nerdfonts
      pkgs.rustup
      pkgs.bat
      pkgs.tokei
      pkgs.fd
      pkgs.procs
      pkgs.eza
      pkgs.du-dust
      pkgs.nushell
      pkgs.prettyping
      pkgs.pkg-config
      pkgs.hwloc

      # docker 
      pkgs.docker
      pkgs.docker-compose
      pkgs.colima
      pkgs.docker-credential-helpers

      pkgs.slack
    ];
  };



  # Add stuff for your user as you see fit:
  # home.packages = with pkgs; [ slack ];

  # Enable home-manager and git
  programs.home-manager.enable = true;
  programs.git = {
    enable = true;
    userName = "Nick Pavlov";
    userEmail = "gurinderu@gmail.com";
  };
  programs.ssh.enable = true;
  programs.starship = import ./starship.nix;
  programs.zsh = import ./zsh.nix;
  programs.neovim = import ./neovim.nix;

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
  home.stateVersion = "23.11";

}
