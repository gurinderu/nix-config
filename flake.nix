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
      packages.x86_64-linux.rtk = nixpkgs.legacyPackages.x86_64-linux.callPackage ./pkgs/rtk { };
      packages.x86_64-linux.fabro = nixpkgs.legacyPackages.x86_64-linux.callPackage ./pkgs/fabro { };

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

      nixosConfigurations."thinkpad-x1-gen12" = import ./hosts/thinkpad-x1-gen12 {
        inherit
          inputs
          nixpkgs
          home-manager
          ;
      };
    };
}
