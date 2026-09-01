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
        # Fully declarative taps: $HOMEBREW_LIBRARY/Taps is a single symlink into
        # the nix store (the taps-env built from the inputs above). mutableTaps =
        # true instead makes each namespace a real writable dir that nix-homebrew
        # mkdir/chown/rsyncs into — which crashes when Taps is ALREADY the store
        # symlink from a prior activation: `mkdir -p Taps/<ns>` and the chown that
        # follows land inside the read-only /nix/store, aborting the rebuild
        # (observed after the nix reinstall: "mkdir /opt/homebrew/Library/Taps"
        # failing). All taps here come from flake inputs and nothing is tapped by
        # hand, so the immutable symlink layout is the correct one; it also lets
        # is_occupied treat the existing store symlink as replaceable, so the
        # switch heals the mismatch with a plain `ln -shf` and no manual cleanup.
        mutableTaps = false;
        autoMigrate = true;
      };
      homebrew = {
        enable = true;
        casks = [
          # Menu bar manager — hides/collapses status icons so they stop
          # disappearing behind the notch. Free Bartender alternative.
          "jordanbaird-ice"
          # Menu bar plugin runner. Hosts the net-observer readout (see
          # ../../users/gurinderu/swiftbar.nix): the gateway RTT from the
          # daemon's last TICK, plus one-click "freeze the pcap ring now".
          # The coworking gateway fails by ramping over ~40s, so the number
          # in the bar is an early warning; noticing it in the log means
          # reading the log, which happens after the network is already gone.
          "swiftbar"
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
          # Keep `darwin-rebuild switch` independent of Homebrew's network. With
          # upgrade=true every switch runs `brew upgrade`, which hits the network
          # and can hang or fail — fatal on this host precisely when you need a
          # rebuild most: a repair switch on the fail-closed Mac (DNS/traffic down)
          # would stall in the brew step. The single managed cask (Ice) is pinned
          # by the flake inputs; upgrade it deliberately with `brew upgrade` when
          # wanted, not implicitly on every rebuild.
          upgrade = false;
        };
      };
    }
    (
      # Takes `config` because the SwiftBar plugin directory below is derived
      # from the user's home rather than hardcoded; the other module blocks in
      # this list are plain attrsets and need no arguments.
      { config, ... }:
      {
      # Launch Ice (menu bar manager) at login, declaratively, instead of
      # relying on its in-app "Launch at login" toggle.
      launchd.user.agents.ice.serviceConfig = {
        ProgramArguments = [ "/Applications/Ice.app/Contents/MacOS/Ice" ];
        RunAtLoad = true;
        KeepAlive = false;
        ProcessType = "Interactive";
      };

      # Same treatment for SwiftBar: launch at login declaratively rather than
      # through its in-app toggle, so a fresh machine gets the net-observer
      # readout from the first switch instead of from someone remembering.
      launchd.user.agents.swiftbar.serviceConfig = {
        ProgramArguments = [ "/Applications/SwiftBar.app/Contents/MacOS/SwiftBar" ];
        RunAtLoad = true;
        KeepAlive = false;
        ProcessType = "Interactive";
      };

      # SwiftBar's plugin folder, declared rather than picked in its first-run
      # dialog. Without this the app opens a folder chooser on launch and the
      # home.file-deployed plugin is simply never found — the widget would look
      # broken on a fresh machine with nothing in any log to say why.
      # PluginDirectory must be a literal path: SwiftBar reads it as a string
      # and does no ~ expansion.
      system.defaults.CustomUserPreferences."com.ameba.SwiftBar" = {
        PluginDirectory = "${config.users.users.gurinderu.home}/.config/swiftbar/plugins";
        # Skip the "choose a plugin folder" first-run flow that would otherwise
        # overwrite the directory set above.
        SwiftBarLaunchedBefore = true;
      };
      }
    )
  ];
}
