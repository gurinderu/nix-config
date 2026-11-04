# netbird — WireGuard-based overlay mesh (self-hosted control plane, see
# hosts/mac_aarch64/netbird.nix). This is a REPACK of upstream's prebuilt macOS
# (and, for cloud-vm, linux_amd64 — see below) release artifacts, not a source
# build, and that is deliberate:
#
#   * nixpkgs is on 0.71.4 (nixos-26.05) / 0.74.3 (unstable HEAD as of
#     2026-07-29), and its expression builds the UI from `client/ui` — the OLD
#     Fyne interface. NetBird 0.75 replaced that with a Wails 3 + React app
#     living elsewhere in the tree, so packaging it upstream needs a rewritten
#     derivation (Go + an npm frontend build). Until that lands, nixpkgs cannot
#     give us the current desktop app at all.
#   * 0.75 changed the UI<->agent API and upstream states the two MUST be the
#     same version. Shipping both halves from ONE derivation makes that
#     structurally impossible to get wrong — which mixing a nix daemon with a
#     hand-installed .app (the state this machine was in: daemon 0.69.0) does
#     not.
#
# Two artifacts are fetched:
#
#   netbird_<v>_darwin_arm64.tar.gz         CLI + daemon, a plain Mach-O arm64
#                                           binary (ad-hoc / linker-signed).
#   netbird-ui_<v>_darwin_arm64_signed.zip  the GUI. Despite the name this is
#                                           not a bare binary but a complete
#                                           FLAT app bundle: Info.plist,
#                                           _CodeSignature/ and Netbird.icns sit
#                                           directly in netbird_ui_darwin/ next
#                                           to the executable. `codesign -dv`
#                                           reads it as `io.netbird.client`,
#                                           Developer ID team TA739QLA7A,
#                                           notarized. Renaming the directory to
#                                           `Netbird UI.app` is enough to make
#                                           macOS treat it as an app, and does
#                                           not invalidate the signature
#                                           (CodeResources hashes the contents,
#                                           not the enclosing name).
#
# dontFixup is LOAD-BEARING, not a speed-up. fixupPhase would strip and rewrite
# the Mach-O headers, and any byte changed inside a signed bundle invalidates
# the Developer ID signature — Gatekeeper then refuses to launch the app.
# Nothing inside the bundle may be touched, which is also why the vestigial
# installer.sh / uninstaller.sh (helpers meant for the netbirdio/tap cask) are
# kept: they are covered by CodeResources.
#
# The bundle is installed under $out/Applications so nix-darwin's activation
# rsyncs a real copy into /Applications/Nix Apps (it dereferences store
# symlinks into real files), which is what makes it visible to Spotlight and
# Launch Services. A plain symlink would not be indexed.
#
# aarch64-darwin, plus x86_64-linux for cloud-vm (hosts/cloud-vm/netbird.nix).
# The linux side is CLI + daemon only — a headless VM has no use for the UI —
# taken from netbird_<v>_linux_amd64.tar.gz at the SAME version string, so the
# peers on both ends always run one release. That tarball's `netbird` is a
# statically linked, already-stripped ELF (`file` says so), so there is nothing
# for autoPatchelf or fixupPhase to do; dontFixup there just skips a no-op.
# The darwin derivation is kept byte-identical to the darwin-only version of
# this file (same drvPath): the platform split happens around it, not in it.
{
  lib,
  stdenvNoCC,
  fetchurl,
  unzip,
  writeShellApplication,
  curl,
  jq,
  nix,
  gnused,
}:
let
  version = "0.75.1";
  baseUrl = "https://github.com/netbirdio/netbird/releases/download/v${version}";

  cli = fetchurl {
    url = "${baseUrl}/netbird_${version}_darwin_arm64.tar.gz";
    hash = "sha256-HLiRc/r/PEW3GSfomRy0bsbd80HWQp4mOcVym6ONK5Q=";
  };

  ui = fetchurl {
    url = "${baseUrl}/netbird-ui_${version}_darwin_arm64_signed.zip";
    hash = "sha256-l1GIzti10MIUvZNSvppzGEgJhvmvNZbHX06KHjky1Es=";
  };

  # Declared THIRD on purpose: the update script finds hashes by position.
  cliLinux = fetchurl {
    url = "${baseUrl}/netbird_${version}_linux_amd64.tar.gz";
    hash = "sha256-/kLQSaLQGbxV54e0I81ULtvQdlCYACtKtbX+GQhqNAY=";
  };

  darwin = stdenvNoCC.mkDerivation {
    pname = "netbird";
    inherit version;

    # Two unrelated archives, unpacked by hand in installPhase.
    dontUnpack = true;

    nativeBuildInputs = [ unzip ];

    installPhase = ''
      runHook preInstall

      mkdir -p $out/bin "$out/Applications"

      tar xzf ${cli}
      install -Dm555 netbird $out/bin/netbird

      # -x __MACOSX/*: the AppleDouble sidecars the release zip carries. They are
      # NOT part of the signed bundle (CodeResources does not list them), so
      # dropping them is safe — and leaving them would litter $out/Applications
      # with a bogus second entry.
      unzip -q ${ui} -x '__MACOSX/*'
      cp -R netbird_ui_darwin "$out/Applications/Netbird UI.app"

      # The GUI sets LSUIElement=1, so it has no Dock icon and is reachable only
      # from the menu bar once running. This wrapper is the terminal entry point
      # (`netbird-ui`); Spotlight users get the copy under /Applications/Nix Apps.
      # printf rather than a heredoc so the script body carries no leading
      # indentation (a heredoc would embed it and break the shebang), and /bin/sh
      # is hardcoded because dontFixup skips patchShebangs anyway.
      printf '#!/bin/sh\nexec /usr/bin/open -a "%s/Applications/Netbird UI.app" "$@"\n' \
        "$out" > $out/bin/netbird-ui
      chmod 555 $out/bin/netbird-ui

      runHook postInstall
    '';

    # See the header: stripping/rewriting would break the notarized signature.
    dontFixup = true;
  };

  linux = stdenvNoCC.mkDerivation {
    pname = "netbird";
    inherit version;

    # One tarball; only the binary is wanted out of it (the rest is
    # LICENSE/README).
    dontUnpack = true;

    installPhase = ''
      runHook preInstall
      tar xzf ${cliLinux} netbird
      install -Dm555 netbird $out/bin/netbird
      runHook postInstall
    '';

    # Static and already stripped (see the header): nothing to fix up.
    dontFixup = true;
  };
in
# overrideAttrs only adds passthru and meta, neither of which reaches the
# derivation itself, so the darwin drvPath is unchanged by the wrapping.
(if stdenvNoCC.hostPlatform.isDarwin then darwin else linux).overrideAttrs (_: {
  passthru.updateScript = writeShellApplication {
    name = "netbird-update";
    runtimeInputs = [
      curl
      jq
      nix
      gnused
    ];
    text = ''
      # Bump this file to the newest upstream release: resolve the latest tag,
      # re-prefetch both darwin artifacts and the linux_amd64 CLI, rewrite
      # version + all three hashes. Run it by hand (`nix run
      # .#netbird.updateScript`), then rebuild — 0.75 requires the daemon and
      # the UI to move together, and they do here because both come from this
      # one version string (as does cloud-vm's daemon).
      target="''${1:-$PWD/pkgs/netbird/default.nix}"
      [ -f "$target" ] || { echo "not found: $target" >&2; exit 1; }

      tag=$(curl -fsSL https://api.github.com/repos/netbirdio/netbird/releases/latest | jq -r .tag_name)
      new="''${tag#v}"
      old=$(sed -n 's/^  version = "\(.*\)";$/\1/p' "$target")
      if [ "$new" = "$old" ]; then
        echo "netbird already at $old"
        exit 0
      fi
      echo "netbird $old -> $new"

      base="https://github.com/netbirdio/netbird/releases/download/$tag"
      cli_hash=$(nix store prefetch-file --json --hash-type sha256 \
        "$base/netbird_''${new}_darwin_arm64.tar.gz" | jq -r .hash)
      ui_hash=$(nix store prefetch-file --json --hash-type sha256 \
        "$base/netbird-ui_''${new}_darwin_arm64_signed.zip" | jq -r .hash)
      linux_hash=$(nix store prefetch-file --json --hash-type sha256 \
        "$base/netbird_''${new}_linux_amd64.tar.gz" | jq -r .hash)

      # Replace each hash by its CURRENT literal rather than by line position:
      # the `hash =` lines are otherwise indistinguishable to sed, and
      # anchoring on the old value keeps the edit correct however the file is
      # later reformatted. The darwin CLI archive is declared first, the UI
      # second, the linux CLI third.
      # Base64 SRI never contains `|`, so it is safe as the s||| delimiter.
      old_cli=$(sed -n 's|^    hash = "\(sha256-[^"]*\)";$|\1|p' "$target" | sed -n 1p)
      old_ui=$(sed -n 's|^    hash = "\(sha256-[^"]*\)";$|\1|p' "$target" | sed -n 2p)
      old_linux=$(sed -n 's|^    hash = "\(sha256-[^"]*\)";$|\1|p' "$target" | sed -n 3p)
      sed -i \
        -e "s|^  version = \".*\";$|  version = \"$new\";|" \
        -e "s|$old_cli|$cli_hash|" \
        -e "s|$old_ui|$ui_hash|" \
        -e "s|$old_linux|$linux_hash|" \
        "$target"
      echo "cli: $cli_hash"
      echo "ui:  $ui_hash"
      echo "linux: $linux_hash"
    '';
  };

  meta = {
    description =
      if stdenvNoCC.hostPlatform.isDarwin then
        "NetBird client (daemon, CLI and the 0.75+ Wails desktop app) for macOS"
      else
        "NetBird client (daemon and CLI) for Linux";
    homepage = "https://netbird.io";
    changelog = "https://github.com/netbirdio/netbird/releases/tag/v${version}";
    license = lib.licenses.bsd3;
    mainProgram = "netbird";
    platforms = [
      "aarch64-darwin"
      "x86_64-linux"
    ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
