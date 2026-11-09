# Trust the Fluence NetBird mesh root CA system-wide on cloud-vm, so curl,
# git, nix and anything else using the distro bundle accept the mesh's TLS
# hosts without --cacert. Every VM gets it (base config).
#
# The user side is ../mesh-ca.nix: the cert sits sops-encrypted in
# secrets/cloud-vm.yaml (key mesh_root_ca) and the sops-nix home-manager module
# decrypts it with the VM's own age key under ~/.local/state, so it survives a
# reboot and is there at boot even before (or without) the user's systemd
# instance.
#
# A system unit cannot be ordered after the user's sops-nix.service, so the
# trigger is the decrypted file itself: mesh-ca.path watches the sops-nix
# directory in ~/.config, where every sops-nix run swaps the secrets symlink to
# a new generation, and starts mesh-ca.service. That copies the cert to
# /usr/local/share/ca-certificates (0644) only when the content differs and
# then runs update-ca-certificates. mesh-ca.service is also wanted at boot
# (system-manager.target), so a boot re-checks it. A missing secret (a new VM
# whose key is not a recipient yet) is logged and skipped, exit 0.
#
# The path unit is wanted by paths.target as before, and by
# system-manager.target too: system-manager only starts that target on a
# switch, so without it a fresh VM would not watch until its first reboot.
#
# Check: `ls /etc/ssl/certs/fluence-mesh-root-ca.pem`; `journalctl -u mesh-ca`
# logs each run.
{
  config,
  hmConfig,
  lib,
  pkgs,
  ...
}:
let
  secretPath = hmConfig.sops.secrets.mesh_root_ca.path;
  # Directory where sops-nix swaps the secrets symlink on every run.
  watchDir = "${hmConfig.xdg.configHome}/sops-nix";
  dst = "/usr/local/share/ca-certificates/fluence-mesh-root-ca.crt";

  script = pkgs.writeShellScript "mesh-ca" ''
    set -eu
    src=${lib.escapeShellArg secretPath}
    dst=${lib.escapeShellArg dst}
    if ! ${pkgs.gnugrep}/bin/grep -q 'BEGIN CERTIFICATE' "$src" 2>/dev/null; then
      echo "no decrypted cert at $src (not a sops recipient yet?); skipping"
      exit 0
    fi
    if ${pkgs.diffutils}/bin/cmp -s "$src" "$dst" \
      && [ -e /etc/ssl/certs/fluence-mesh-root-ca.pem ]; then
      exit 0
    fi
    mkdir -p "$(dirname "$dst")"
    tmp=$(mktemp "$dst.XXXXXX")
    cat "$src" > "$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$dst"
    echo "installed $dst"
    /usr/sbin/update-ca-certificates
  '';
in
{
  systemd.services.mesh-ca = {
    description = "Install the Fluence mesh root CA into the system trust store";
    wantedBy = [ "multi-user.target" ];
    environment.PATH = lib.mkForce config.cloudVm.servicePath;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = script;
    };
  };

  systemd.paths.mesh-ca = {
    description = "Watch the decrypted Fluence mesh root CA";
    wantedBy = [
      "paths.target"
      "multi-user.target"
    ];
    pathConfig = {
      PathChanged = watchDir;
      Unit = "mesh-ca.service";
    };
  };
}
