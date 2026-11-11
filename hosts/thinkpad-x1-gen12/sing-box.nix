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
  inherit (import ../../users/gurinderu/sing-box-secrets.nix)
    servers
    fields
    secretName
    globals
    globalSecretName
    globalToken
    ;
  sopsFiles = import ../../secrets;

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
  # Global (non-per-server) secrets: plain token replacements; replaceStrings
  # also hits a token inside a larger string ("SING_BOX_HEADSCALE_IP/32").
  globalSubs = lib.mapAttrsToList (key: stem: {
    from = globalToken stem;
    to = config.sops.placeholder.${globalSecretName key};
  }) globals;
  subs = builtins.concatMap subsFor servers ++ globalSubs;

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
  # sha256 of the rendered config the running sing-box loaded — the thinkpad
  # twin of the darwin reloadHash md5 gate. Written by preStart right before
  # every start (so it tracks what the process ACTUALLY loads, not what the
  # reload saw); read by sing-box-config-reload below. Lives in the 0700
  # StateDirectory: the hash is of a file holding credentials.
  configHash = "/var/lib/sing-box/config.sha256";
  sha256 = "${pkgs.coreutils}/bin/sha256sum";
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
    # Stamp the config this start loads for the reload gate. An unreadable
    # config drops the stamp, so the next path trigger restarts once more
    # rather than trusting a hash of nothing.
    if h=$(${sha256} 2>/dev/null < ${lib.escapeShellArg renderedConfig}); then
      (umask 077; printf '%s' "''${h%% *}" > ${configHash}) \
        || echo "sing-box: could not write ${configHash}; the next config trigger will restart once more" >&2
    else
      rm -f ${configHash}
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
    # Host-wide default: thinkpad.yaml (the CI runner and Docker Hub tokens in
    # ./github-runner.nix). The VLESS credentials below come from shared.yaml,
    # which the Mac reads too. Neither file holds the Mac-only SSH keys.
    defaultSopsFile = sopsFiles.thinkpad;
    defaultSopsFormat = "yaml";
    # Derive the age identity from this host's SSH host key — no private age
    # key file to copy around. Its age *public* key (from
    # `ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub`) is the thinkpad-x1-gen12
    # recipient in .sops.yaml; after changing it, run
    # `sops updatekeys secrets/shared.yaml secrets/thinkpad.yaml`.
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

    secrets = builtins.listToAttrs (
      builtins.concatMap (
        n:
        map (f: {
          name = secretName n f;
          value.sopsFile = sopsFiles.shared;
        }) (builtins.attrNames fields)
      ) servers
      ++ map (key: {
        name = globalSecretName key;
        value.sopsFile = sopsFiles.shared;
      }) (builtins.attrNames globals)
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

  # Restart sing-box when sops re-renders the config with a different VALUE
  # (i.e. after a credential rotation in secrets/shared.yaml + nixos-rebuild
  # switch). restartTriggers on the service only catches structural Nix
  # changes; this path unit catches secret-value changes that only affect the
  # rendered file on disk.
  # Using a path unit instead of sops restartUnits avoids the activation-script
  # restart mechanism (/run/nixos/activation-restart-list, which is what
  # sops-nix's restartUnits writes): deprecated in NixOS 26.05 —
  # switch-to-configuration already prints a WARN for it — and removed in 26.11.
  systemd.paths.sing-box-config = {
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = renderedConfig;
      Unit = "sing-box-config-reload.service";
    };
  };

  # sops-nix renders into a fresh /run/secrets.d/N generation on EVERY
  # activation, so the path unit fires on every switch whether or not anything
  # changed. The old unconditional `systemctl restart` therefore bounced the
  # proxy (and the runner VMs' network) on each switch, and on 2026-11-06 it
  # ran while switch-to-configuration was re-executing systemd: "Failed to
  # restart sing-box.service: Transport endpoint is not connected", unit
  # failed. Hence, in order:
  # - content gate: restart only when the rendered file's sha256 differs from
  #   the one preStart stamped for the running process (darwin's md5 gate);
  # - try-restart: a stopped sing-box (switch-to-configuration stops it for a
  #   structural change and starts it again itself) is left alone — that start
  #   loads the new file anyway — and an inactive unit is not a failure;
  # - --no-block: only enqueue the job, never wait on it inside activation;
  # - retry: the bus drops for a moment during a daemon-reexec; a failure
  #   that outlasts ~30s is real and fails the unit.
  # The stamp is NOT written here: preStart writes it on the actual restart.
  systemd.services.sing-box-config-reload = {
    description = "Restart sing-box if the rendered config content changed";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "sing-box-config-reload" ''
        if ! new=$(${sha256} 2>/dev/null < ${lib.escapeShellArg renderedConfig}); then
          echo "sing-box: rendered config unreadable; not restarting" >&2
          exit 0
        fi
        new=''${new%% *}
        old=$(cat ${configHash} 2>/dev/null || :)
        if [ "$new" = "$old" ]; then
          echo "sing-box: rendered config unchanged; no restart"
          exit 0
        fi
        i=0
        until ${config.systemd.package}/bin/systemctl --no-block try-restart sing-box.service; do
          i=$((i + 1))
          if [ "$i" -ge 30 ]; then
            echo "sing-box: try-restart kept failing; giving up" >&2
            exit 1
          fi
          sleep 1
        done
        echo "sing-box: rendered config changed; try-restart queued"
      '';
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
    # A restart, not reloadIfChanged: sing-box 1.13 does reload on SIGHUP
    # (cmd_run.go: check the config, close the instance, create a new one in
    # the same process), but that tears down and rebuilds the TUN and routes
    # just like a restart, so it saves no connection. And it skips
    # ExecStartPre, i.e. the stale-fakeip guard and the config stamp above:
    # a reload after a fakeip pool change would keep the old cache.db.
    serviceConfig = {
      ExecStartPre = "${preStart}";
      ExecStart = "${pkgs.sing-box}/bin/sing-box run -c ${renderedConfig}";
      Restart = "on-failure";
      RestartSec = 5;
      # Writable state dir for experimental.cache_file (fakeip persistence).
      # Creates /var/lib/sing-box (root-owned, this unit runs as root).
      StateDirectory = "sing-box";
      # 0700, not the 0755 default: cache.db is a persistent record of every
      # name resolved through the proxy — and this box runs arbitrary GitHub
      # Actions workflow code. That code now lives in microVMs
      # (github-runner.nix), but the directory stays private regardless.
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
