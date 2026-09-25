# socktainer — Docker Engine API (v1.51, partial) served on a unix socket on
# top of Apple's `container` framework (macOS 26+, Apple Silicon). This is a
# REPACK of upstream's prebuilt release binary, not a source build, and that
# is deliberate: the stable brew formula installs the very same release zip
# (only `--head` builds compile, and those need Xcode 26 — a toolchain nix
# cannot provide), and the binary is signed, so rebuilding buys nothing.
#
# The zip contains exactly one file, the arm64 Mach-O `socktainer`, at the
# archive root — hence dontUnpack + a manual unzip in installPhase (stdenv's
# unpacker refuses an archive that yields no directory).
#
# dontFixup is LOAD-BEARING: fixupPhase would strip the Mach-O, and any byte
# changed in a signed binary invalidates its signature.
#
# Version pin: socktainer 1.2.1 speaks Apple container 1.2.0's XPC exactly —
# the data-plane pkg pinned in /usr/local/bin (see
# hosts/mac_aarch64/socktainer.nix for that story). Bump the two together.
{
  lib,
  stdenvNoCC,
  fetchurl,
  unzip,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "socktainer";
  version = "1.2.1";

  src = fetchurl {
    url = "https://github.com/socktainer/socktainer/releases/download/v${finalAttrs.version}/socktainer.zip";
    hash = "sha256-7zCTag7kl/mwSXT3d+AN8/N8O5pV5DU6nPeXrIEfW54=";
  };

  dontUnpack = true;
  dontFixup = true;

  nativeBuildInputs = [ unzip ];

  installPhase = ''
    runHook preInstall
    unzip -q $src
    install -Dm755 socktainer $out/bin/socktainer
    runHook postInstall
  '';

  meta = {
    description = "Docker-compatible REST API on top of Apple container";
    homepage = "https://github.com/socktainer/socktainer";
    license = lib.licenses.asl20;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "aarch64-darwin" ];
    mainProgram = "socktainer";
  };
})
