# infinity — hydro-project's coding-agent runtime (Rust): the `infinity` CLI,
# which also runs the daemon in-process (`infinity daemon`), plus the
# `sandbox-local` RAP tool server (file/git/shell tools under bubblewrap).
# Upstream ships no flake and no releases yet, so we build a pinned commit.
#
# Added on top: `infinity-provider-openai-compat` (./provider-openai-compat,
# ~150 lines, Apache-2.0 like upstream), a model provider for any
# OpenAI-compatible Chat Completions endpoint. The thinkpad points it at a
# local llama.cpp server (hosts/thinkpad-x1-gen12/local-agents.nix). It is
# copied in as a workspace member, so it builds against the exact in-tree
# provider crates; ./Cargo.lock is upstream's lock plus that one member.
#
# Notes on the build:
#   * Only the three binaries' packages are built (cargoBuildFlags); the
#     workspace also holds Lambda/Slack/Bedrock crates we do not use. The
#     `bundled-web` feature (embeds a web UI built with npm) stays off.
#   * sandbox-local's build.rs runs `bwrap --version` and, if that fails,
#     tries to compile bubblewrap from a downloaded tarball — so bubblewrap
#     is a nativeBuildInput. At runtime the binary is wrapped with it on PATH.
#   * Tests need network, sockets and bwrap namespaces: doCheck = false.
#
# Bump: set `rev` to a new upstream commit, set `hash` to lib.fakeHash and
# build to get the real one; then regenerate ./Cargo.lock from the new
# upstream lock: clone at that rev, copy ./provider-openai-compat to
# crates/infinity-provider-openai-compat, add it to the workspace members,
# run `cargo metadata --format-version 1 >/dev/null`, copy Cargo.lock back.
{
  lib,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  makeWrapper,
  bubblewrap,
  openssl,
}:
rustPlatform.buildRustPackage {
  pname = "infinity";
  version = "0.2.0-unstable-2026-11-05";

  src = fetchFromGitHub {
    owner = "hydro-project";
    repo = "infinity";
    rev = "e1a3e4b36e5f6143e03a59a7ad86e1abacfd22e8";
    hash = "sha256-FchPEeywVkfF0oJ4VBNhqtp+tMZ4QvIoP4qzBQX/cZA=";
  };

  cargoLock.lockFile = ./Cargo.lock;

  postPatch = ''
    cp -r ${./provider-openai-compat} crates/infinity-provider-openai-compat
    chmod -R u+w crates/infinity-provider-openai-compat
    substituteInPlace Cargo.toml --replace-fail \
      '"crates/infinity-provider-rig",' \
      '"crates/infinity-provider-rig", "crates/infinity-provider-openai-compat",'
    cp ${./Cargo.lock} Cargo.lock
  '';

  cargoBuildFlags = [
    "-p"
    "infinity-agent-cli"
    "-p"
    "sandbox-local"
    "-p"
    "infinity-provider-openai-compat"
  ];

  nativeBuildInputs = [
    pkg-config
    bubblewrap
    makeWrapper
  ];
  buildInputs = [ openssl ];

  doCheck = false;

  postInstall = ''
    wrapProgram $out/bin/sandbox-local --prefix PATH : ${lib.makeBinPath [ bubblewrap ]}
  '';

  meta = {
    description = "Infinity coding agents (CLI + daemon, local sandbox) with an OpenAI-compatible model provider";
    homepage = "https://github.com/hydro-project/infinity";
    license = lib.licenses.asl20;
    mainProgram = "infinity";
    platforms = lib.platforms.linux;
  };
}
