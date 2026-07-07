# codebase-memory-mcp — code-intelligence MCP server (DeusData), UI variant.
#
# Prebuilt release binary from GitHub (single self-contained binary with the
# graph-visualisation UI baked in; headroom's own `--code-graph` shells out to
# the very same `codebase-memory-mcp` binary, so putting this on PATH lets both
# a direct Claude Code MCP registration and headroom reuse one binary + one
# on-disk graph cache (~/.cache/codebase-memory-mcp)).
#
# The upstream tarball holds {codebase-memory-mcp, LICENSE, install.sh,
# THIRD_PARTY_NOTICES.md} at the top level — we install just the binary.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  zlib,
}:
let
  version = "0.8.1";
  base = "https://github.com/DeusData/codebase-memory-mcp/releases/download/v${version}";

  # -ui asset per platform. Hashes pinned via `nix store prefetch-file`.
  sources = {
    aarch64-darwin = {
      url = "${base}/codebase-memory-mcp-ui-darwin-arm64.tar.gz";
      hash = "sha256-Ex994KlpGXSmVlAkQ/hsfCnLieYt3EPJVTE0pQdbUvs=";
    };
    x86_64-linux = {
      url = "${base}/codebase-memory-mcp-ui-linux-amd64.tar.gz";
      hash = "sha256-H+XvqmC/BaBOcJjou0kZGKbePzPclbd+ki4CPpcA0XU=";
    };
  };

  src = fetchurl (
    sources.${stdenv.hostPlatform.system}
      or (throw "codebase-memory-mcp: unsupported system ${stdenv.hostPlatform.system}")
  );
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

  meta = {
    description = "High-performance code-intelligence MCP server (knowledge graph, UI variant)";
    homepage = "https://github.com/DeusData/codebase-memory-mcp";
    license = lib.licenses.mit;
    mainProgram = "codebase-memory-mcp";
    platforms = builtins.attrNames sources;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
