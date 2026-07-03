{
  inputs,
  self,
  nix-darwin,
  home-manager,
  pkgs-unstable,
  sops-nix,
}:

nix-darwin.lib.darwinSystem {
  system = "aarch64-darwin";
  modules = [
    ./configuration.nix
    home-manager.darwinModules.home-manager
    {
      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
      # Back up (don't clobber) pre-existing files home-manager takes over, e.g.
      # ~/.config/opencode/package.json left by an earlier opencode run before
      # opencode-craft.nix managed it. Mirrors the thinkpad host.
      home-manager.backupFileExtension = "bak";
      home-manager.extraSpecialArgs = {
        inherit inputs pkgs-unstable sops-nix;
        inherit (inputs) nix-colors;
      };
      home-manager.users.gurinderu =
        { pkgs, ... }:
        {
          imports = [
            ../../users/gurinderu/home.nix
            ../../users/gurinderu/darwin.nix
          ];
        };
    }
    inputs.nix-homebrew.darwinModules.nix-homebrew
    {
      nix-homebrew = {
        enable = true;
        # No Intel-only `arch -x86_64 brew` casks are used (the Brewfile is
        # empty), so the Rosetta /usr/local Homebrew prefix is dead weight. Off.
        enableRosetta = false;
        user = "gurinderu";
        taps = {
          "homebrew/homebrew-core" = inputs.homebrew-core;
          "homebrew/homebrew-cask" = inputs.homebrew-cask;
          "homebrew/homebrew-bundle" = inputs.homebrew-bundle;
        };
        mutableTaps = true;
        autoMigrate = true;
      };
      homebrew = {
        enable = true;
        casks = [
          # Menu bar manager — hides/collapses status icons so they stop
          # disappearing behind the notch. Free Bartender alternative.
          "jordanbaird-ice"
        ];
        onActivation = {
          # Taps are pinned to the nix store (read-only, root-owned) via the
          # homebrew-{core,cask,bundle} flake inputs. autoUpdate makes brew run
          # `brew update`, which git-syncs and chmods those tap files and fails
          # with `apply2files: Permission denied`. Keep it off and update taps
          # with `nix flake update homebrew-core homebrew-cask homebrew-bundle`.
          autoUpdate = false;
          # No brew packages are declared here (the rendered Brewfile is empty),
          # so cleanup="zap" had nothing legitimate to remove — it only tried to
          # untap homebrew/cask + homebrew/bundle, which nix-homebrew manages.
          # Homebrew 6.0 started prompting "proceed with cleanup? [y/n]" before
          # doing so, and during activation stdin is not a TTY, so the rebuild
          # hung looping on "Invalid input". Nothing to clean here -> disable it.
          # (If brew packages are ever managed here and hand-installed ones
          # should be removed, switch to "zap" AND declare the taps in
          # homebrew.taps so cleanup leaves nix-homebrew's taps alone.)
          cleanup = "none";
          upgrade = true;
        };
      };
    }
    {
      # Launch Ice (menu bar manager) at login, declaratively, instead of
      # relying on its in-app "Launch at login" toggle.
      launchd.user.agents.ice.serviceConfig = {
        ProgramArguments = [ "/Applications/Ice.app/Contents/MacOS/Ice" ];
        RunAtLoad = true;
        KeepAlive = false;
        ProcessType = "Interactive";
      };
    }
  ];
}
