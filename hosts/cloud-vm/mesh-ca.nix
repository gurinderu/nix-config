# Trust the Fluence NetBird mesh root CA system-wide on cloud-vm, so curl,
# git, nix and anything else using the distro bundle accept the mesh's TLS
# hosts without --cacert.
#
# The cert sits sops-encrypted in secrets/cloud-vm.yaml (key mesh_root_ca;
# recipients in .sops.yaml), decrypted by the sops-nix home-manager module
# with this VM's own age key at ~/.config/sops/age/keys.txt (the bootstrap
# makes it and prints its public key). Decrypted secrets live under
# ~/.local/state instead of the upstream default $XDG_RUNTIME_DIR, so they
# survive a reboot and the root unit finds them at boot even before (or
# without) the user's systemd instance.
#
# The sops-nix activation step is wrapped below so a failed decrypt warns
# instead of failing the whole switch; `systemctl --user status sops-nix` then
# shows why. A new VM: add its public key to .sops.yaml, run `sops updatekeys
# secrets/cloud-vm.yaml` (with the admin key), push, pull and switch.
#
# Getting it into the system store needs root, which standalone home-manager
# lacks: the root units (mesh-ca.path watching ~/.config/sops-nix, and
# mesh-ca.service) live in ./system/mesh-ca.nix, applied by system-manager.
#
# Check: `ls /etc/ssl/certs/fluence-mesh-root-ca.pem`; `journalctl -u
# mesh-ca` logs each run.
{
  config,
  inputs,
  lib,
  ...
}:
{
  imports = [ inputs.sops-nix.homeManagerModules.sops ];

  sops = {
    defaultSopsFile = (import ../../secrets).cloud-vm;
    defaultSopsFormat = "yaml";
    age.keyFile = "${config.home.homeDirectory}/.config/sops/age/keys.txt";
    defaultSecretsMountPoint = "${config.xdg.stateHome}/sops-nix/secrets.d";
    secrets.mesh_root_ca = { };
  };

  # Upstream's step, but a failed decrypt only warns (see the header), and it
  # runs after reloadSystemd so the first switch already has the unit.
  home.activation.sops-nix = lib.mkForce (
    lib.hm.dag.entryAfter [ "reloadSystemd" ] ''
      if [ -z "''${DRY_RUN:-}" ]; then
        sn_state=$(${config.systemd.user.systemctlPath} --user is-system-running 2>&1 || true)
        if [ "$sn_state" = running ] || [ "$sn_state" = degraded ]; then
          ${config.systemd.user.systemctlPath} --user restart sops-nix \
            || echo "sops-nix: decrypt failed; is this VM's age key a recipient of secrets/cloud-vm.yaml? (see hosts/cloud-vm/mesh-ca.nix)" >&2
        fi
        unset sn_state
      fi
    ''
  );
}
