# osewa — persistent remote terminals: QUIC, falling back to a TLS WebSocket
# where UDP is blocked, sessions held on the host (libghostty-vt keeps the
# screen), port forwards and exec over the same connection. Server on cloud-vm
# (hosts/cloud-vm/osewa.nix), client on the Mac (users/gurinderu/osewa.nix).
#
# REPACK of upstream's prebuilt release binaries, not a source build: the
# build needs Zig plus a pinned libghostty-vt checkout fetched by upstream's
# Makefile, and the release is what `osewa login` itself would put on a host.
# Each release asset is one gzipped executable, osewa-<os>-<arch>.gz;
# fetchurl pins the .gz, whose sha256 is the one in the release's SHA256SUMS
# (converted to SRI). Version and protocol must match on both ends (upstream
# checks `version --json`; a mismatched pair refuses to attach), and both come
# from this one version string.
#
#   linux-amd64   statically linked musl ELF, already stripped (`file` says
#                 so): nothing for autoPatchelf or fixupPhase to do.
#   darwin-arm64  Developer ID signed and notarized Mach-O. dontFixup is
#                 LOAD-BEARING here: stripping or rewriting the binary
#                 invalidates the signature.
#
# Self-update cannot replace a /nix/store binary and must not try: the server
# checks hourly and the CLI daily unless auto-update is off, which both hosts'
# modules pin (OSEWA_AUTO_UPDATE=off in the unit, `osewa set auto-update off`
# at activation). Bump this file instead: `nix run .#osewa.updateScript`.
{
  lib,
  stdenvNoCC,
  fetchurl,
  writeShellApplication,
  curl,
  jq,
  nix,
  gnused,
  gawk,
}:
let
  version = "0.1.0";
  sources = {
    aarch64-darwin = {
      asset = "osewa-darwin-arm64.gz";
      hash = "sha256-OhJb+ZcsoiaipLOi6bwoBvVsDyw+pvu5bs8Dn2hfgAk=";
    };
    x86_64-linux = {
      asset = "osewa-linux-amd64.gz";
      hash = "sha256-jH6Q/6qM7QlYIWwh5wjIeLvW3m6nOwk4L4bXOiqTovM=";
    };
  };
  system = stdenvNoCC.hostPlatform.system;
  src = sources.${system} or (throw "osewa: no upstream release for ${system}");
in
stdenvNoCC.mkDerivation {
  pname = "osewa";
  inherit version;

  src = fetchurl {
    url = "https://github.com/rjyo/osewa/releases/download/v${version}/${src.asset}";
    inherit (src) hash;
  };

  # A bare .gz of one file, not an archive: stdenv's unpacker has nothing to
  # make a source directory from.
  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    gzip -dc $src > $out/bin/osewa
    chmod 555 $out/bin/osewa
    runHook postInstall
  '';

  # See the header: static and stripped on linux, signed on darwin.
  dontFixup = true;

  passthru.updateScript = writeShellApplication {
    name = "osewa-update";
    runtimeInputs = [
      curl
      jq
      nix
      gnused
      gawk
    ];
    text = ''
      # Bump this file to the newest upstream release: the version from the
      # latest release's build.json (what upstream's install.sh pins "latest"
      # to), both hashes from that release's SHA256SUMS. Run it by hand, then
      # switch cloud-vm and the Mac together (see the header).
      target="''${1:-$PWD/pkgs/osewa/default.nix}"
      [ -f "$target" ] || { echo "not found: $target" >&2; exit 1; }

      new=$(curl -fsSL https://github.com/rjyo/osewa/releases/latest/download/build.json | jq -r .osewa)
      old=$(sed -n 's/^  version = "\(.*\)";$/\1/p' "$target")
      if [ "$new" = "$old" ]; then
        echo "osewa already at $old"
        exit 0
      fi
      echo "osewa $old -> $new"

      sums=$(curl -fsSL "https://github.com/rjyo/osewa/releases/download/v$new/SHA256SUMS")
      args=(-e "s|^  version = \".*\";$|  version = \"$new\";|")
      for asset in osewa-darwin-arm64.gz osewa-linux-amd64.gz; do
        hex=$(awk -v f="$asset" '$2 == f { print $1 }' <<<"$sums")
        [ -n "$hex" ] || { echo "$asset missing from SHA256SUMS" >&2; exit 1; }
        sri=$(nix hash convert --hash-algo sha256 --to sri "$hex")
        # The hash line right after this asset's line. Base64 SRI never
        # contains `|`, so it is safe as the s||| delimiter.
        args+=(-e "/asset = \"$asset\";/{n;s|hash = \".*\";|hash = \"$sri\";|}")
        echo "$asset: $sri"
      done
      sed -i "''${args[@]}" "$target"
    '';
  };

  meta = {
    description = "Persistent remote terminals over QUIC with TLS WebSocket fallback";
    homepage = "https://osewa.dev";
    changelog = "https://github.com/rjyo/osewa/releases/tag/v${version}";
    license = lib.licenses.asl20;
    mainProgram = "osewa";
    platforms = builtins.attrNames sources;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
