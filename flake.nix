{
  description = "System flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:LnL7/nix-darwin/nix-darwin-26.05";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    nix-colors.url = "github:misterio77/nix-colors";
    nix-homebrew.url = "github:zhaofengli-wip/nix-homebrew";
    homebrew-core = {
      url = "github:homebrew/homebrew-core";
      flake = false;
    };
    homebrew-cask = {
      url = "github:homebrew/homebrew-cask";
      flake = false;
    };
    homebrew-bundle = {
      url = "github:homebrew/homebrew-bundle";
      flake = false;
    };
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
    # Meridian: local proxy that exposes the Claude subscription as Anthropic /
    # OpenAI API endpoints (opencode talks to it on loopback 127.0.0.1:3456).
    # Our own Rust port — a single static binary built with rustPlatform,
    # replacing the TypeScript/Bun original (rynfar/meridian). Kept on its own
    # nixpkgs (no `follows`) so its package builds as pinned. The Rust flake uses
    # flake-utils.eachDefaultSystem and exposes packages.<system>.default plus an
    # overlays.default (-> pkgs.meridian); it has no `systems`/home-manager-module
    # surface, so consumers wire the service themselves (launchd on mac, a
    # systemd user unit on the thinkpad).
    meridian.url = "github:gurinderu/meridian";
    # craft: personal Claude Code / opencode engineering skills, review agents,
    # and audit/triage workflows. Not a Nix flake (flake = false) — we consume
    # the repo tree as a store path and symlink its opencode adapter into
    # ~/.config/opencode (see modules/opencode-craft.nix). Advance with
    # `nix flake update craft`.
    craft = {
      url = "github:gurinderu/craft";
      flake = false;
    };
    # net-observer: the Rust rewrite of the shell net-observer LaunchDaemon
    # (hosts/mac_aarch64/net-observer.nix). Provides darwinModules.default, which
    # owns the launchd job, and packages.<system>.net-observerd. Kept on its own
    # nixpkgs (no `follows`): the daemon's rust-toolchain.toml pins the compiler
    # and libduckdb-sys builds its own DuckDB engine, so pointing it at this
    # host's nixpkgs would only risk a mismatch it cannot use.
    #
    # Was a temporary `git+file:` input while the packaging work sat unpushed;
    # that made this flake depend on a working copy on this machine and
    # reproducible nowhere else. Now upstream, so it is a plain github: URL and
    # the config evaluates on any host again. Advance it with
    # `nix flake update net-observer`.
    net-observer.url = "github:gurinderu/net-observer";
    # verstak: structured-inquiry skill set (github:verstak-ai/skills). Like
    # craft, not a Nix flake (flake = false) — we consume the repo tree as a
    # store path and symlink its skills/ dirs into ~/.config/opencode/skills
    # (see modules/opencode-verstak.nix). Advance with `nix flake update verstak`.
    verstak = {
      url = "github:verstak-ai/skills";
      flake = false;
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      nixpkgs-unstable,
      nix-darwin,
      home-manager,
      sops-nix,
      ...
    }:
    let
      mkPkgsUnstable =
        system:
        import nixpkgs-unstable {
          inherit system;
          config.allowUnfree = true;
        };
    in
    {
      formatter.aarch64-darwin = nixpkgs.legacyPackages.aarch64-darwin.nixfmt-tree;
      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt-tree;

      # rtk (Rust Token Killer) built from source. Exposed per-host so
      # `nix build .#rtk` works and home-manager can reference it.
      packages.aarch64-darwin.rtk = nixpkgs.legacyPackages.aarch64-darwin.callPackage ./pkgs/rtk { };

      # netbird: repacked upstream macOS release (daemon + CLI + the 0.75 Wails
      # desktop app). Exposed so `nix build .#netbird` and
      # `nix run .#netbird.updateScript` work; the mac host consumes it via
      # callPackage in hosts/mac_aarch64/netbird.nix.
      packages.aarch64-darwin.netbird =
        nixpkgs.legacyPackages.aarch64-darwin.callPackage ./pkgs/netbird
          { };
      packages.x86_64-linux.rtk = nixpkgs.legacyPackages.x86_64-linux.callPackage ./pkgs/rtk { };

      darwinConfigurations."mac_aarch64" = import ./hosts/mac_aarch64 {
        inherit
          inputs
          self
          nix-darwin
          home-manager
          sops-nix
          ;
        pkgs-unstable = mkPkgsUnstable "aarch64-darwin";
      };

      darwinPackages = self.darwinConfigurations."mac_aarch64".pkgs;

      # Mechanical eval coverage for the Mac host. `nix flake check` forces
      # system.build.toplevel for nixosConfigurations but has NO darwin
      # equivalent — proven empirically 2026-09-05: a flake with a
      # guaranteed-throwing darwinConfigurations entry still gets "all checks
      # passed!". So without this line every hosts/mac_aarch64 change ships
      # with zero eval coverage, and the first sign of a bad option (e.g. a
      # nix-darwin bump renaming nix.gc.* — its removed-option stubs are
      # already in the locked rev) is a failed `darwin-rebuild switch` on the
      # fail-closed Mac. `.system` is the derivation whose eval forces the
      # whole module tree; from Linux run
      # `nix flake check --all-systems` (or eval the drvPath directly) to
      # exercise it.
      checks.aarch64-darwin.mac-system = self.darwinConfigurations."mac_aarch64".system;

      nixosConfigurations."thinkpad-x1-gen12" = import ./hosts/thinkpad-x1-gen12 {
        inherit
          inputs
          self
          nixpkgs
          home-manager
          ;
      };
    };
}
