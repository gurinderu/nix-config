# rtk — "Rust Token Killer": a CLI that filters/compresses command output
# (git, cargo, npm, docker, …) before it reaches an LLM's context window,
# cutting 60–90% of tokens. Integrates with Claude Code via an auto-rewrite
# Bash hook (`rtk init -g`). Upstream ships no flake, so we build the pinned
# release from source with rustPlatform.buildRustPackage.
#
# Notes on the build:
#   * Cargo.lock has zero git dependencies, so a single cargoHash vendors the
#     whole closure — no per-crate outputHashes.
#   * build.rs only concatenates src/filters/*.toml into OUT_DIR at compile
#     time (no network), so it is reproducible in the sandbox.
#   * rusqlite is pulled with the `bundled` feature: it compiles a vendored
#     SQLite in C, needing only the stdenv cc (no system sqlite / pkg-config).
#   * ureq uses rustls, so no OpenSSL / Security-framework wiring is required.
{
  lib,
  rustPlatform,
  fetchFromGitHub,
}:
rustPlatform.buildRustPackage rec {
  pname = "rtk";
  version = "0.43.0";

  src = fetchFromGitHub {
    owner = "rtk-ai";
    repo = "rtk";
    rev = "v${version}";
    hash = "sha256-n5bkPPsrdM4fE5ltocTjlq+JwRgp39yib6S79fci4m4=";
  };

  cargoHash = "sha256-XKUKdhxfnwUCOx9slqx4oUFa09HcosPLVh5Xkh87oSk=";

  # Upstream tests shell out to real tooling (git, the rtk binary, etc.), which
  # is unavailable / non-deterministic in the sandbox. Building the binary is
  # the goal here.
  doCheck = false;

  meta = {
    description = "Rust Token Killer — compresses command output to cut LLM token usage";
    homepage = "https://github.com/rtk-ai/rtk";
    license = lib.licenses.asl20;
    mainProgram = "rtk";
    platforms = lib.platforms.unix;
  };
}
