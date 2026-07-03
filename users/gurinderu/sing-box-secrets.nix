# Single source of truth for the per-server VLESS secret fields and their
# placeholder tokens. Shared by BOTH substitution paths so they can never drift:
#   - macOS  (users/gurinderu/sing-box.nix): sed over decrypted sops values at
#     home-manager activation time.
#   - NixOS  (hosts/thinkpad-x1-gen12/sing-box.nix): sops.templates +
#     builtins.replaceStrings rendering placeholders into a root-only file.
#
# Adding a field or a backend server is therefore a one-file change here.
{
  # 1-based backend server indices. Each contributes a sing_box_vless_N_* secret
  # set and the matching SING_BOX_*_N placeholders in sing-box-config.nix.
  servers = [
    1
    2
    3
    4
  ];

  # sops key field -> placeholder token stem (the SING_BOX_<STEM>_N form emitted
  # by mkVless in sing-box-config.nix). The 1-based index suffix _N is appended
  # per server so no token is a prefix of another — safe for sed / replaceStrings
  # in any order (e.g. SING_BOX_SERVER_1 is not a prefix of SING_BOX_SERVER_NAME_1).
  # `server_port` is special-cased by both call sites: its token is quoted in the
  # JSON ("server_port":"SING_BOX_PORT_N") and the quotes are stripped on
  # substitution so the port stays a JSON number.
  fields = {
    server = "SERVER";
    server_port = "PORT";
    uuid = "UUID";
    public_key = "PUBLIC_KEY";
    short_id = "SHORT_ID";
    server_name = "SERVER_NAME";
  };

  secretName = n: f: "sing_box_vless_${toString n}_${f}";
}
