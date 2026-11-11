# osewa client on the Mac: `osewa attach cloud-vm-1`, `osewa attach nixos` etc.
# against the servers on cloud-vm (hosts/cloud-vm/osewa.nix) and the NixOS
# thinkpad (hosts/thinkpad-x1-gen12/osewa.nix), both from
# users/common/osewa-server.nix, same pkgs/osewa version on every end.
# Enrolling this Mac is a one-time login per server: `osewa login
# ubuntu@<host> --no-install --name <host>` for a VM, `osewa login
# 0xff@100.77.143.123 --no-install --name nixos` for the thinkpad
# (--no-install is required, see users/common/osewa-server.nix); it keeps the
# device key and hosts.json in ~/.config/osewa.
#
# Auto-update is pinned off: the CLI otherwise checks GitHub daily after
# interactive commands and tries to replace its own (read-only, /nix/store)
# binary. Bump pkgs/osewa instead, and switch the servers along with the Mac.
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
