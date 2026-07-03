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

    $DRY_RUN_CMD ${pkgs.gnused}/bin/sed "''${SED_ARGS[@]}" ${singBoxConfig} > "$CONFIG_DIR/config.json"
    $DRY_RUN_CMD chmod 600 "$CONFIG_DIR/config.json"
  '';
}
