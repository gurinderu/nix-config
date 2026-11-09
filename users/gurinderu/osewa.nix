# osewa client on the Mac: `osewa attach cloud-vm-1` etc. against the server on
# cloud-vm (hosts/cloud-vm/osewa.nix), same pkgs/osewa version on both ends.
# Enrolling this Mac is a one-time `osewa login --no-install ...` (README
# "osewa"); it keeps the device key and hosts.json in ~/.config/osewa.
#
# Auto-update is pinned off: the CLI otherwise checks GitHub daily after
# interactive commands and tries to replace its own (read-only, /nix/store)
# binary. Bump pkgs/osewa instead, and switch the VM along with the Mac.
{ lib, pkgs, ... }:
let
  osewa = pkgs.callPackage ../../pkgs/osewa { };
in
{
  home.packages = [ osewa ];

  # Rewrites one key of settings.json and keeps the rest; a failure must not
  # abort the switch.
  home.activation.osewaAutoUpdate = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if ! run ${osewa}/bin/osewa set auto-update off </dev/null >/dev/null; then
      echo "osewa: could not set auto-update off (continuing)" >&2
    fi
  '';
}
