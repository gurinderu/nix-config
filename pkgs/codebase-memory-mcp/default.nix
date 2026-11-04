# codebase-memory-mcp — code-intelligence MCP server (DeusData), UI variant.
#
# Prebuilt release binary from GitHub (single self-contained binary with the
# graph-visualisation UI — "CBM Lens" since 0.12 — baked in). Putting this on
# PATH lets a direct Claude Code MCP registration use one binary + one on-disk
# graph cache (~/.cache/codebase-memory-mcp).
#
# Since 0.10 the stdio servers coordinate through a per-user daemon that
# checks each client's build fingerprint; the UI service
# (users/common/codebase-memory-ui.nix) and the MCP servers on PATH are this
# same store path, so they always agree. An index-format bump (0.11, 0.12)
# means the first index of each project after an upgrade is a full rebuild.
#
# The upstream tarball holds {codebase-memory-mcp, LICENSE, install.sh,
# THIRD_PARTY_NOTICES.md} at the top level — we install just the binary.
# Hashes are the ones in the release's checksums.txt, converted to SRI.
# Self-update (`codebase-memory-mcp update`) cannot replace a /nix/store
# binary; bump this file instead: `nix run .#codebase-memory-mcp.updateScript`.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  zlib,
  writeShellApplication,
  curl,
  jq,
  nix,
  gnused,
  gawk,
}:
let
  version = "0.12.1";
  base = "https://github.com/DeusData/codebase-memory-mcp/releases/download/v${version}";

  # -ui asset per platform.
  sources = {
    aarch64-darwin = {
      asset = "codebase-memory-mcp-ui-darwin-arm64.tar.gz";
      hash = "sha256-m/y+OEFLR5aaPh0cGZn1NXQJOHyG+j0kIhtUWCZ2YNI=";
    };
    x86_64-linux = {
      asset = "codebase-memory-mcp-ui-linux-amd64.tar.gz";
      hash = "sha256-hFMBUUXwcsG5sBnL3QLOqMxvGMxeEWA23SCZJjHGOMc=";
    };
  };

  source =
    sources.${stdenv.hostPlatform.system}
      or (throw "codebase-memory-mcp: unsupported system ${stdenv.hostPlatform.system}");
  src = fetchurl {
    url = "${base}/${source.asset}";
    inherit (source) hash;
  };
in
stdenv.mkDerivation {
  pname = "codebase-memory-mcp";
  inherit version src;

  # Tarball extracts several files at the top level, not into a single dir.
  sourceRoot = ".";

  # The -ui Linux release is NOT static: it dynamically links libstdc++.so.6,
  # libgcc_s.so.1 (both from the C++ runtime, stdenv.cc.cc.lib) and libz.so.1
  # (zlib). autoPatchelfHook rewrites the NEEDED entries against these; without
  # them on buildInputs it aborts with "could not satisfy dependency". Darwin
  # needs neither the hook nor the libs.
  nativeBuildInputs = lib.optionals stdenv.isLinux [ autoPatchelfHook ];
  buildInputs = lib.optionals stdenv.isLinux [
    stdenv.cc.cc.lib
    zlib
  ];

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true; # never strip a vendored prebuilt binary

  installPhase = ''
    runHook preInstall
    install -Dm755 codebase-memory-mcp $out/bin/codebase-memory-mcp
    install -Dm644 LICENSE $out/share/codebase-memory-mcp/LICENSE
    runHook postInstall
  '';

  passthru.updateScript = writeShellApplication {
    name = "codebase-memory-mcp-update";
    runtimeInputs = [
      curl
      jq
      nix
      gnused
      gawk
    ];
    text = ''
      # Bump this file to the newest upstream release (GitHub's "latest",
      # which skips prereleases): the version from its tag, both hashes from
      # that release's checksums.txt. Run it by hand, then rebuild.
      target="''${1:-$PWD/pkgs/codebase-memory-mcp/default.nix}"
      [ -f "$target" ] || { echo "not found: $target" >&2; exit 1; }

      tag=$(curl -fsSL https://api.github.com/repos/DeusData/codebase-memory-mcp/releases/latest | jq -r .tag_name)
      new="''${tag#v}"
      old=$(sed -n 's/^  version = "\(.*\)";$/\1/p' "$target")
      if [ "$new" = "$old" ]; then
        echo "codebase-memory-mcp already at $old"
        exit 0
      fi
      echo "codebase-memory-mcp $old -> $new"

      sums=$(curl -fsSL "https://github.com/DeusData/codebase-memory-mcp/releases/download/$tag/checksums.txt")
      args=(-e "s|^  version = \".*\";$|  version = \"$new\";|")
      for asset in codebase-memory-mcp-ui-darwin-arm64.tar.gz codebase-memory-mcp-ui-linux-amd64.tar.gz; do
        hex=$(awk -v f="$asset" '$2 == f { print $1 }' <<<"$sums")
        [ -n "$hex" ] || { echo "$asset missing from checksums.txt" >&2; exit 1; }
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
    description = "High-performance code-intelligence MCP server (knowledge graph, UI variant)";
    homepage = "https://github.com/DeusData/codebase-memory-mcp";
    changelog = "https://github.com/DeusData/codebase-memory-mcp/releases/tag/v${version}";
    license = lib.licenses.mit;
    mainProgram = "codebase-memory-mcp";
    platforms = builtins.attrNames sources;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
