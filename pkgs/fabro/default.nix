# fabro — "the dark software factory": a single static Rust binary with the web
# UI embedded. Upstream ships no flake; the from-source build would require a
# Bun/JS frontend build, so we pin the released musl-static binary instead.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:
stdenv.mkDerivation rec {
  pname = "fabro";
  version = "0.254.0";

  src = fetchurl {
    url = "https://github.com/fabro-sh/fabro/releases/download/v${version}/fabro-x86_64-unknown-linux-musl.tar.gz";
    hash = "sha256-J/96kwlQoyL81d69un419j6ZkXkWnMuq2+UCCQCU17A=";
  };

  sourceRoot = ".";

  # musl build is normally fully static (autoPatchelf becomes a no-op); kept as a
  # safety net in case the release links the musl loader dynamically.
  nativeBuildInputs = [ autoPatchelfHook ];

  installPhase = ''
    runHook preInstall
    install -Dm755 "$(find . -type f -name fabro | head -1)" "$out/bin/fabro"
    runHook postInstall
  '';

  meta = {
    description = "Fabro — open-source workflow-graph orchestrator for AI coding agents";
    homepage = "https://fabro.sh";
    license = lib.licenses.mit;
    mainProgram = "fabro";
    platforms = [ "x86_64-linux" ];
  };
}
