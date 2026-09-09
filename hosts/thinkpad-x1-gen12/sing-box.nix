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
  #
  # Then the stale-fakeip cache guard, ported from the darwin start script
  # (hosts/mac_aarch64/sing-box.nix): cache.db persists fakeip mappings, and
  # entries from a previous pool survive a pool change — sing-box then keeps
  # serving addresses the current route rules no longer send to the TUN,
  # silently blackholing this box's proxied traffic (the pool moved three
  # times in one week of 2026-09; the mac needed a 13-minute incident to
  # learn the stamp must reflect the config the process ACTUALLY loads, not
  # the build-time constant). Reading the range from the sops-rendered file
  # is safe here precisely because of that lesson — and unlike darwin there
  # is no rendered-later race to fall back around: sops-nix renders during
  # activation, before this unit starts, so the darwin fallback-to-build-time
  # branch is deliberately dropped. An unreadable config yields an empty
  # $want: the guard skips (never wipes on a guess) and sing-box itself fails
  # loudly on the same file right after.
  cacheDb = "/var/lib/sing-box/cache.db";
  renderedConfig = config.sops.templates."sing-box-config.json".path;
  preStart = pkgs.writeShellScript "sing-box-pre-start" ''
    i=0
    while [ -f ${cacheDb} ] && [ "$i" -lt 30 ] \
        && ! ${pkgs.util-linux}/bin/flock -n ${cacheDb} true 2>/dev/null; do
      sleep 1
      i=$((i + 1))
    done

    # NB on first activation the stamp is missing, so an existing cache.db is
    # wiped once — its pool is unknown, same rationale as the darwin guard.
    stamp=/var/lib/sing-box/fakeip-range
    want=$(${pkgs.jq}/bin/jq -r 'first(.dns.servers[]? | .inet4_range // empty)' \
      ${lib.escapeShellArg renderedConfig} 2>/dev/null)
    if [ -z "$want" ]; then
      # Readable-but-rangeless config (a future rename of inet4_range) must
      # be distinguishable from a working guard — darwin logs on the same
      # condition.
      echo "sing-box: could not read inet4_range from the rendered config; skipping the stale-fakeip guard this start" >&2
    elif [ "$(cat "$stamp" 2>/dev/null)" != "$want" ]; then
      wiped=1
      if [ -e ${cacheDb} ]; then
        echo "sing-box: fakeip pool is now $want; dropping cache.db with its stale mappings"
        rm -f ${cacheDb} || wiped=0
      fi
      # Stamp only when the wipe happened (or nothing needed wiping): a stamp
      # over a surviving old-pool cache.db would disarm the guard forever.
      if [ "$wiped" = 1 ]; then
        printf '%s' "$want" > "$stamp" \
          || echo "sing-box: could not write the fakeip stamp; the guard will re-wipe next start" >&2
      else
        echo "sing-box: could not remove stale cache.db; NOT stamping $want so the guard retries next start" >&2
      fi
    fi
    # The guard is hygiene, never a start blocker: this script is the unit's
    # ExecStartPre (no "-" prefix), so a non-zero tail here would crash-loop
    # sing-box on Restart=on-failure — e.g. a failed stamp write on a full
    # /var would take the proxy down over an optional wipe. Always succeed.
    exit 0
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
      PathChanged = renderedConfig;
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
      # Rendering happens in activation today (sops.useSystemdActivation is
      # false), so this entry is a no-op — systemd ignores ordering against a
      # unit that does not exist. It is here for the day the flag's default
      # (systemd.sysusers.enable) flips rendering to a sysinit-time unit:
      # without the ordering, the ExecStartPre guard and sing-box itself
      # would read a stale or absent rendered config at boot.
      "sops-install-secrets.service"
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
      ExecStart = "${pkgs.sing-box}/bin/sing-box run -c ${renderedConfig}";
      Restart = "on-failure";
      RestartSec = 5;
      # Writable state dir for experimental.cache_file (fakeip persistence).
      # Creates /var/lib/sing-box (root-owned, this unit runs as root).
      StateDirectory = "sing-box";
      # 0700, not the 0755 default: cache.db is a persistent record of every
      # name resolved through the proxy, and arbitrary GitHub Actions
      # workflow code runs on this box as local users (github-runner.nix).
      # The darwin twin of this directory is chmod 700 for the same reason.
      StateDirectoryMode = "0700";
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
