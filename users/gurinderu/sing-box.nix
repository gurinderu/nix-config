{
  pkgs,
  lib,
  config,
  ...
}:
let
  secrets = import ./sing-box-secrets.nix;

  singBoxConfig = pkgs.writeTextFile {
    name = "sing-box-config.json";
    text = builtins.toJSON (import ./sing-box-config-darwin.nix);
  };

  # One substitution spec per (server, field), generated from the shared
  # single-source-of-truth so this path can never drift from the NixOS one.
  # Each becomes a `subst <token> <secretKey> <mode>` line the activation loop
  # consumes; mode "port" strips the surrounding quotes so the port stays a JSON
  # number, mode "str" is a plain token replacement.
  specLines = lib.concatLists (
    map (
      n:
      lib.mapAttrsToList (
        field: stem:
        let
          isPort = field == "server_port";
          token =
            if isPort then
              ''"server_port":"SING_BOX_PORT_${toString n}"''
            else
              "SING_BOX_${stem}_${toString n}";
        in
        "subst ${lib.escapeShellArg token} ${lib.escapeShellArg (secrets.secretName n field)} ${
          if isPort then "port" else "str"
        }"
      ) secrets.fields
    ) secrets.servers
  );
in
{
  home.activation.singBoxConfig = config.lib.dag.entryAfter [ "writeBoundary" "sops-nix" ] ''
    # The rendered config holds the decrypted VLESS secrets in cleartext, so
    # everything created here must be private. umask 077 closes the window
    # between `> config.json` and the chmod below where the file would otherwise
    # be created world-readable (default umask 022).
    umask 077
    CONFIG_DIR="${config.home.homeDirectory}/.config/sing-box"
    export SOPS_AGE_KEY_FILE="${config.sops.age.keyFile}"

    $DRY_RUN_CMD mkdir -p "$CONFIG_DIR"
    # The launchd daemon reads this as root regardless of the user-dir perms.
    $DRY_RUN_CMD chmod 700 "$CONFIG_DIR"

    # Decrypt the whole secrets file ONCE into JSON (one sops invocation instead
    # of one per field), then pull each value out with jq.
    ALL_SECRETS=$(${pkgs.sops}/bin/sops -d --output-type json "${config.sops.defaultSopsFile}")

    # Build the sed substitutions for every backend server. Tokens carry the
    # index suffix so order does not matter.
    SED_ARGS=()
    subst() {
      # $1 = token, $2 = sops key, $3 = mode (str|port)
      local value
      # Fail loudly on a missing key instead of substituting the literal "null"
      # jq -r would otherwise emit (which sing-box only rejects later, opaquely).
      value=$(${pkgs.jq}/bin/jq -er --arg k "$2" '.[$k]' <<<"$ALL_SECRETS") || {
        echo "sing-box: missing secret $2 in ${config.sops.defaultSopsFile}" >&2
        exit 1
      }
      # Escape sed REPLACEMENT metacharacters (& \ and the | delimiter) so the
      # substitution is literal — matching the Linux replaceStrings path exactly,
      # regardless of what characters a secret value contains.
      local repl
      repl=$(printf '%s' "$value" | ${pkgs.gnused}/bin/sed -e 's/[&\\|]/\\&/g')
      if [ "$3" = "port" ]; then
        SED_ARGS+=( -e "s|$1|\"server_port\":$repl|g" )
      else
        SED_ARGS+=( -e "s|$1|$repl|g" )
      fi
    }
    ${lib.concatStringsSep "\n    " specLines}

    # Render atomically: substitute into a private temp file, validate it, then
    # rename over the live config in one step. Three bugs this closes:
    #   1. A dry run must NOT touch the live file. `$DRY_RUN_CMD sed ... > file`
    #      does not protect the redirect — the shell opens (truncates) the target
    #      before DRY_RUN_CMD (echo) runs, so a dry run used to blow away
    #      config.json and fill it with the echoed command line, which embeds the
    #      DECRYPTED secrets. Guard the whole write on DRY_RUN_CMD instead.
    #   2. `sed > config.json` is truncate-then-stream: the launchd WatchPaths
    #      reload (hosts/mac_aarch64/sing-box.nix) can fire mid-write and hand
    #      sing-box a half-written file. rename(2) is atomic — readers see either
    #      the whole old file or the whole new one.
    #   3. No validation: a substitution bug (or a leftover SING_BOX_ placeholder)
    #      shipped straight to the daemon, which only rejected it opaquely at
    #      reload. `sing-box check` fails the activation and leaves the last-good
    #      config in place instead.
    render_config() {
      local tmp
      tmp=$(${pkgs.coreutils}/bin/mktemp "$CONFIG_DIR/.config.json.XXXXXX")
      ${pkgs.gnused}/bin/sed "''${SED_ARGS[@]}" ${singBoxConfig} > "$tmp"
      chmod 600 "$tmp"
      if ! ${pkgs.sing-box}/bin/sing-box check -c "$tmp" 2>&1; then
        echo "sing-box: rendered config failed validation - keeping existing config.json" >&2
        rm -f "$tmp"
        exit 1
      fi
      # Belt-and-suspenders: no placeholder token may survive into production.
      if ${pkgs.gnugrep}/bin/grep -q 'SING_BOX_' "$tmp"; then
        echo "sing-box: unsubstituted SING_BOX_ placeholder in rendered config - aborting" >&2
        rm -f "$tmp"
        exit 1
      fi
      mv -f "$tmp" "$CONFIG_DIR/config.json"
    }

    if [ -n "''${DRY_RUN_CMD:-}" ]; then
      echo "would render, validate and atomically install $CONFIG_DIR/config.json"
    else
      render_config
    fi
  '';
}
