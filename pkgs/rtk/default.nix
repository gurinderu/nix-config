# rtk — "Rust Token Killer": a CLI that filters/compresses command output
# (git, cargo, npm, docker, …) before it reaches an LLM's context window,
# cutting 60–90% of tokens. Integrates with Claude Code via an auto-rewrite
# Bash hook (`rtk init -g`). Upstream ships no flake, so we build the pinned
# release from source with rustPlatform.buildRustPackage.
#
# EDITION: since 1.0 the default build links `rtk-engine` (engine/, BUSL-1.1:
# source-available, unfree to nixpkgs). We build the Apache-2.0 edition
# upstream ships as `rtk-oss` (`--no-default-features`): the same `rtk`
# binary with the hook rewrite system and every command filter, minus the
# engine-only `rtk pipeline`, PostToolUse compression and delegation tasks —
# none of which this config uses (users/common/rtk.nix wires only the
# PreToolUse `rtk hook claude`). Keeps the derivation free, so `nix flake
# check` and the hosts need no allowUnfree for it.
#
# Notes on the build:
#   * Cargo.lock has zero git dependencies, so a single cargoHash vendors the
#     whole closure — no per-crate outputHashes. It is a workspace (rtk, text,
#     engine, plugin) whose root package is the default member, so plain
#     `cargo build` builds only the `rtk` binary; proxy/ (rtk-proxy) is not a
#     member and is not built.
#   * build.rs only concatenates src/filters/*.toml into OUT_DIR at compile
#     time (no network), so it is reproducible in the sandbox.
#   * rusqlite is pulled with the `bundled` feature: it compiles a vendored
#     SQLite in C, needing only the stdenv cc (no system sqlite / pkg-config).
#   * ureq uses rustls, so no OpenSSL / Security-framework wiring is required.
#
# Bump: `nix run .#rtk.updateScript` from the repo root (nix-update against
# GitHub releases, which skips upstream's many dev-*-rc prereleases, and
# refreshes both the src hash and cargoHash).
{
  lib,
  rustPlatform,
  fetchFromGitHub,
  writeShellApplication,
  nix-update,
}:
rustPlatform.buildRustPackage rec {
  pname = "rtk";
  version = "1.1.0";

  src = fetchFromGitHub {
    owner = "rtk-ai";
    repo = "rtk";
    rev = "v${version}";
    hash = "sha256-RlMGWDGSvKvbRjZ/duJNdVrnqY7B4dM/5IWVJ5LUzjg=";
  };

  cargoHash = "sha256-rPkrAUgeEktzpNBPAw3xVJS7QSUS0lKGsBDWv3MlE8I=";

  # The Apache-2.0 `rtk-oss` edition; see the header.
  buildNoDefaultFeatures = true;

  # Upstream tests shell out to real tooling (git, the rtk binary, etc.), which
  # is unavailable / non-deterministic in the sandbox. Building the binary is
  # the goal here.
  doCheck = false;

  passthru.updateScript = writeShellApplication {
    name = "rtk-update";
    runtimeInputs = [ nix-update ];
    text = ''
      # Run from the repo root: resolves .#rtk for the current system and
      # rewrites pkgs/rtk/default.nix in place.
      exec nix-update --flake --use-github-releases rtk "$@"
    '';
  };

  meta = {
    description = "Rust Token Killer — compresses command output to cut LLM token usage";
    homepage = "https://github.com/rtk-ai/rtk";
    changelog = "https://github.com/rtk-ai/rtk/blob/v${version}/CHANGELOG.md";
    license = lib.licenses.asl20;
    mainProgram = "rtk";
    platforms = lib.platforms.unix;
  };
}
