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
    {
      # Stamp each generation with the flake revision. Now that generations
      # auto-expire (nix.gc, 14d), the profile symlink dates alone no longer
      # answer "which config was live during that incident" for anything older
      # than the window — the stamp keeps `darwin-version --configuration-revision`
      # (and the generation's own metadata) forensically useful. A dirty tree
      # records dirtyRev, marking the generation as not reproducible from git.
      system.configurationRevision = self.rev or self.dirtyRev or null;
    }
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
    # net-observerd: the Rust rewrite of the shell observer. It runs ALONGSIDE
    # hosts/mac_aarch64/net-observer.nix, deliberately — that shell daemon is the
    # behavioural oracle the rewrite is checked against, and its watchdog
    # kickstart is still the only auto-recovery on this machine. Retiring it is a
    # separate, later step, and not before an acting handler replaces the
    # watchdog. NB the acting bar moved on 2026-09-05: the shell watchdog now
    # also carries an escalating kick backoff (5→60 min, reset on healthy tun),
    # a job-gone detector (`launchctl print` says the sing-box service is
    # missing → bootstrap it back), and a BTM-failure notification — the Rust
    # acting handler must cover those too before the shell daemon can retire
    # (its current trigger engine implements only the flat 5-min backoff).
    #
    # The two must not share a log: the module's logFile therefore defaults to
    # /var/log/net-observerd.log while the shell daemon keeps
    # /var/log/net-observer.log. launchd opens StandardOutPath itself and two jobs
    # pointed at one file interleave, which would corrupt the very record the
    # migration is being judged against.
    inputs.net-observer.darwinModules.default
    { services.net-observer.enable = true; }
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
          # @beta (0.11.13-dev.2), not the stable 0.11.12: stable is from
          # Oct 2024 and crashes ~3s after launch on macOS 26 (EXC_BREAKPOINT
          # in Ice's own code, identical signature in every report, observed
          # 2026-09-03/04 — upstream issues #821/#867/#940). The macOS 26
          # compatibility fixes only exist in the dev pre-releases.
          "jordanbaird-ice@beta"
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
    {
      # Launch Ice (menu bar manager) at login, declaratively, instead of
      # relying on its in-app "Launch at login" toggle.
      # KeepAlive = { SuccessfulExit = false; }, not plain `true`: launchd
      # should only relaunch Ice after it dies badly (nonzero exit or a
      # signal), not after the user quits it deliberately (a clean Quit exits
      # 0, which SuccessfulExit=false does not restart) — with `true` Ice
      # could never be closed by hand, it would just bounce back. Observed
      # 2026-09-03: Ice crashed ("last terminating signal = Trace/BPT trap: 5",
      # runs = 1, job state = exited) and with the previous KeepAlive = false
      # it just stayed dead — no menu-bar manager until a manual relaunch.
      launchd.user.agents.ice.serviceConfig = {
        ProgramArguments = [ "/Applications/Ice.app/Contents/MacOS/Ice" ];
        RunAtLoad = true;
        KeepAlive = {
          SuccessfulExit = false;
        };
        ProcessType = "Interactive";
      };
    }
  ];
}
