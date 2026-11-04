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
  # Must match the mkVless calls there: 7 (the RU exit) is no longer emitted,
  # so it is not listed either and activation doesn't require its
  # sing_box_vless_7_* keys.
  servers = [
    1
    2
    3
    4
    5
    6
    8
  ];

  # Per-server VLESS transport (structural, NOT secret). Each node's address,
  # port, UUID and Reality keys are the sensitive bits and live only in sops
  # (sing_box_vless_N_*); this repo is public, so comments here and elsewhere
  # refer to nodes by label and index, never by address. "tcp" is XTLS-Reality
  # with flow=xtls-rprx-vision; "grpc" is Reality over gRPC (gun) with no flow.
  # Consumed by mkVless in sing-box-config.nix. Indices absent here default to
  # "tcp". sing-box 1.13 has no xhttp transport, so the subscription's two xhttp
  # nodes are intentionally omitted (their hosts are covered by the grpc nodes).
  transports = {
    "1" = "tcp"; # 🇩🇪 Germany 1 (node 1)
    "2" = "grpc"; # 🇩🇪 Germany 2 (node 2, same host as node 1)
    "3" = "grpc"; # 🇩🇪 Germany 3 (node 3)
    "4" = "tcp"; # 🇵🇱 Poland 1 (node 4)
    "5" = "grpc"; # 🇵🇱 Poland 2 (node 5, same host as node 4)
    "6" = "grpc"; # 🇵🇱 Poland 3 (node 6)
    "7" = "tcp"; # 🇩🇪 Germany bridge 1 (node 7, Yandex Cloud / RU exit)
    "8" = "tcp"; # foreign exit (node 8, kept, not in subscription)
  };

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
