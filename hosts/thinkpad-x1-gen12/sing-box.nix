{
  config,
  pkgs,
  lib,
  ...
}:
let
  # Linux config (placeholder tokens); fills the shared base's platform holes.
  configJson = builtins.toJSON (import ../../users/gurinderu/sing-box-config-linux.nix);

  # Single source of truth for backend servers, fields and tokens (shared with
  # the macOS path so the two can never drift).
  inherit (import ../../users/gurinderu/sing-box-secrets.nix) servers fields secretName;

  # from/to pairs for builtins.replaceStrings. Index-suffixed tokens mean no
  # token is a prefix of another, so list order is irrelevant. `server_port` is
  # special-cased: its token is quoted in the JSON and the quotes are stripped on
  # substitution so the port stays a JSON number.
  subsFor =
    n:
    let
      ph = f: config.sops.placeholder.${secretName n f};
    in
    lib.mapAttrsToList (
      field: stem:
      if field == "server_port" then
        {
          from = ''"server_port":"SING_BOX_PORT_${toString n}"'';
          to = ''"server_port":'' + ph "server_port";
        }
      else
        {
          from = "SING_BOX_${stem}_${toString n}";
          to = ph field;
        }
    ) fields;
  subs = builtins.concatMap subsFor servers;

  # Wait for the old sing-box to release its bbolt exclusive lock on cache.db
  # before starting a new instance. Without this, a Restart=on-failure cycle
  # launches the new process while the old one still drains TUN connections (and
  # holds the flock), causing the new process to time out on open and crash-loop.
  # Mirrors the lsof-wait loop in the macOS launchd wrapper.
  cacheDb = "/var/lib/sing-box/cache.db";
  preStart = pkgs.writeShellScript "sing-box-pre-start" ''
    i=0
    while [ -f ${cacheDb} ] && [ "$i" -lt 30 ] \
        && ! ${pkgs.util-linux}/bin/flock -n ${cacheDb} true 2>/dev/null; do
      sleep 1
      i=$((i + 1))
    done
  '';
in
{
  sops = {
    defaultSopsFile = ../../secrets/secrets.yaml;
    defaultSopsFormat = "yaml";
    # Derive the age identity from this host's SSH host key — no private age
    # key file to copy around. Add the matching age *public* key (from
    # `ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub`) to .sops.yaml and run
    # `sops updatekeys secrets/secrets.yaml` so this host can decrypt.
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

    secrets = builtins.listToAttrs (
      builtins.concatMap (
        n:
        map (f: {
          name = secretName n f;
          value = { };
        }) (builtins.attrNames fields)
      ) servers
    );

    # Render the full config into a root-only file under /run/secrets/rendered,
    # substituting placeholder tokens with the decrypted secret values. The
    # quotes around the "server_port":"SING_BOX_PORT_N" token are stripped so the
    # port stays a JSON number.
    templates."sing-box-config.json".content = builtins.replaceStrings (map (x: x.from) subs) (map (
      x: x.to
    ) subs) configJson;
  };

  # TUN device for the inbound.
  boot.kernelModules = [ "tun" ];

  # Restart sing-box when sops re-renders the config (i.e. after a credential
  # rotation in secrets.yaml + nixos-rebuild switch). restartTriggers on the
  # service only catches structural Nix changes; this path unit catches
  # secret-value changes that only affect the rendered file on disk.
  # Using a path unit instead of sops restartUnits avoids the activation-script
  # restart mechanism deprecated in NixOS 26.11.
  systemd.paths.sing-box-config = {
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = config.sops.templates."sing-box-config.json".path;
      Unit = "sing-box-config-reload.service";
    };
  };

  systemd.services.sing-box-config-reload = {
    description = "Reload sing-box after rendered config change";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.systemd}/bin/systemctl restart sing-box.service";
    };
  };

  systemd.services.sing-box = {
    description = "sing-box proxy";
    wantedBy = [ "multi-user.target" ];
    # sops-nix renders the template during activation, before multi-user.target,
    # so the rendered config is ready by the time this service starts.
    # Start after tailscaled so it has already registered with the control
    # plane before the TUN + strict_route capture all traffic. Without this
    # ordering sing-box wins the race, strict_route drops the control-plane
    # keepalives, and the Tailscale node disappears seconds after joining.
    after = [
      "network-online.target"
      "tailscaled.service"
    ];
    # wants pulls tailscaled.service into the transaction so After= ordering is
    # honoured even during Restart=on-failure cycles (systemd only re-evaluates
    # After= for units that are actively being started, not for bare restarts).
    wants = [
      "network-online.target"
      "tailscaled.service"
    ];
    # ExecStart points at a stable rendered path, so a config-only change wouldn't
    # otherwise restart the unit — sing-box would keep running the old routes. Tie the
    # restart to the config structure (routes, DNS, excludes) so a rebuild reloads it.
    restartTriggers = [ configJson ];
    serviceConfig = {
      ExecStartPre = "${preStart}";
      ExecStart = "${pkgs.sing-box}/bin/sing-box run -c ${
        config.sops.templates."sing-box-config.json".path
      }";
      Restart = "on-failure";
      RestartSec = 5;
      # Writable state dir for experimental.cache_file (fakeip persistence).
      # Creates /var/lib/sing-box (root-owned, this unit runs as root).
      StateDirectory = "sing-box";
      # Runs as root (no User=) so auto_route can install routes and open
      # /dev/net/tun; these caps are what the TUN inbound actually needs.
      CapabilityBoundingSet = [
        "CAP_NET_ADMIN"
        "CAP_NET_RAW"
        "CAP_NET_BIND_SERVICE"
      ];
      AmbientCapabilities = [
        "CAP_NET_ADMIN"
        "CAP_NET_RAW"
      ];
      # Prevent privilege escalation via setuid/setgid binaries spawned from
      # within sing-box (e.g. a future plugin or vulnerable helper).
      NoNewPrivileges = true;
    };
  };
}
