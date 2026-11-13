# moshi-hook — host-side daemon + CLI for the Moshi iOS app: installs Claude
# Code (and other agent) hooks, serves the local Unix-socket bridge and the
# 127.0.0.1:24543 gateway, and keeps the WebSocket to Moshi for the inbox,
# Live Activities, usage and remote approvals.
#
# REPACK of upstream's prebuilt release, not a source build: the Go source
# (github.com/rjyo/moshi) is private, and rjyo/homebrew-moshi is only a tap
# whose formula downloads these same CDN tarballs. Hashes are the ones in
# upstream's checksums.txt (https://cdn.getmoshi.app/hook/v<ver>/checksums.txt),
# converted to SRI; bump version + all four hashes together with ./update.sh
# (upstream deletes old releases from the CDN, so keep this current).
#
#   Linux:  a single statically linked Go binary (plus README/docs) at the
#           archive root, hence sourceRoot = ".".
#   Darwin: the signed MoshiHook.app bundle the brew formula installs (it also
#           carries `mata`, the simulator host). dontFixup is LOAD-BEARING on
#           darwin: stripping would invalidate the code signature.
#
# Self-update (`moshi-hook update`, and the daemon's `auto-update auto`
# default) cannot replace a /nix/store binary; bump this file instead and set
# `moshi-hook set auto-update off` on the host.
{
  lib,
  stdenvNoCC,
  fetchurl,
}:
let
  version = "0.4.54";
  sources = {
    x86_64-linux = {
      asset = "moshi-hook_Linux_x86_64.tar.gz";
      hash = "sha256-SxPdAppaMe4r3bl7uVY/KBLuwP8exzDpIp00xQ6PeLk=";
    };
    aarch64-linux = {
      asset = "moshi-hook_Linux_arm64.tar.gz";
      hash = "sha256-sSkYsvIsmDhJTFPl/B3K2nXmbDcN57f5DTZSugJrmG0=";
    };
    aarch64-darwin = {
      asset = "moshi-hook-app_Darwin_arm64.tar.gz";
      hash = "sha256-vELnwNxsE+tBXXPo7FkYObSkQsbKOAYQudA3svjm12Q=";
    };
    x86_64-darwin = {
      asset = "moshi-hook-app_Darwin_x86_64.tar.gz";
      hash = "sha256-imUhozHNcnNMvf7GpI2LTorpK8F2xp4mCMQNklUi5LU=";
    };
  };
  system = stdenvNoCC.hostPlatform.system;
  src = sources.${system} or (throw "moshi-hook: no upstream release for ${system}");
in
stdenvNoCC.mkDerivation {
  pname = "moshi-hook";
  inherit version;

  src = fetchurl {
    url = "https://cdn.getmoshi.app/hook/v${version}/${src.asset}";
    inherit (src) hash;
  };

  sourceRoot = ".";
  dontConfigure = true;
  dontBuild = true;
  dontFixup = stdenvNoCC.hostPlatform.isDarwin;

  installPhase = ''
    runHook preInstall
  ''
  + (
    if stdenvNoCC.hostPlatform.isDarwin then
      ''
        mkdir -p $out/Applications $out/bin
        cp -R MoshiHook.app $out/Applications/
        ln -s $out/Applications/MoshiHook.app/Contents/MacOS/moshi-hook $out/bin/moshi-hook
        if [ -e $out/Applications/MoshiHook.app/Contents/MacOS/mata ]; then
          ln -s $out/Applications/MoshiHook.app/Contents/MacOS/mata $out/bin/mata
        fi
      ''
    else
      ''
        install -Dm755 moshi-hook $out/bin/moshi-hook
        mkdir -p $out/share/doc/moshi-hook
        cp -R README.md docs $out/share/doc/moshi-hook/
      ''
  )
  + ''
    # The brew formula and install.sh both ship a `moshi` alias.
    ln -s moshi-hook $out/bin/moshi
    runHook postInstall
  '';

  meta = {
    description = "Daemon + CLI bridging AI coding agents (Claude Code hooks) to the Moshi iOS app";
    homepage = "https://getmoshi.app";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames sources;
    mainProgram = "moshi-hook";
  };
}
