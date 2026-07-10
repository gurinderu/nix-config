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
    5
    6
    7
    8
  ];

  # Per-server VLESS transport (structural, NOT secret — the server IP/keys are
  # the sensitive bits and stay in sops). "tcp" is XTLS-Reality with
  # flow=xtls-rprx-vision; "grpc" is Reality over gRPC (gun) with no flow.
  # Consumed by mkVless in sing-box-config.nix. Indices absent here default to
  # "tcp". sing-box 1.13 has no xhttp transport, so the subscription's two xhttp
  # nodes are intentionally omitted (their IPs are covered by the grpc nodes).
  transports = {
    "1" = "tcp"; # 🇩🇪 Germany 1        94.103.168.85:443
    "2" = "grpc"; # 🇩🇪 Germany 2        94.103.168.85:2053
    "3" = "grpc"; # 🇩🇪 Germany 3        94.103.168.145:2053
    "4" = "tcp"; # 🇵🇱 Poland 1         81.15.150.138:443
    "5" = "grpc"; # 🇵🇱 Poland 2         81.15.150.138:2053
    "6" = "grpc"; # 🇵🇱 Poland 3         81.15.150.144:2053
    "7" = "tcp"; # 🇩🇪 Germany bridge 1 158.160.251.55:443 (Yandex Cloud / RU exit)
    "8" = "tcp"; # foreign exit         194.87.208.142:443 (kept, not in subscription)
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
