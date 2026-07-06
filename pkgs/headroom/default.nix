# Reproducible Headroom proxy build via uv2nix.
#
# Consumes the pinned uv.lock next to this file and materialises a Python 3.12
# virtualenv from prebuilt wheels (sourcePreference = "wheel"), so the build
# needs no compiler, no Rust/maturin, and never pulls torch. The result is a
# venv derivation exposing bin/headroom; run it as `${headroom}/bin/headroom`.
#
# Callers pass the flake inputs (uv2nix, pyproject-nix, pyproject-build-systems)
# plus the target pkgs. See ../../flake.nix for the input definitions.
{
  pkgs,
  inputs,
  python ? pkgs.python312,
}:
let
  inherit (pkgs) lib;

  workspace = inputs.uv2nix.lib.workspace.loadWorkspace {
    workspaceRoot = ./.;
  };

  # Prefer wheels: the [proxy] closure ships manylinux/macos wheels for every
  # dep, so we unpack prebuilt artifacts instead of building from sdist.
  overlay = workspace.mkPyprojectOverlay {
    sourcePreference = "wheel";
  };

  pythonSet =
    (pkgs.callPackage inputs.pyproject-nix.build.packages {
      inherit python;
    }).overrideScope
      (lib.composeManyExtensions [
        inputs.pyproject-build-systems.overlays.default
        overlay
      ]);
in
# The virtualenv for the default (non-dev) dependency group. bin/headroom lives
# here; that is what the launchd agent / systemd unit exec.
pythonSet.mkVirtualEnv "headroom-env" workspace.deps.default
