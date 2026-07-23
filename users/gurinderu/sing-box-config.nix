# Shared sing-box config (pure data, no pkgs/config deps) — a FUNCTION of the
# per-platform differences. The thin wrappers ./sing-box-config-darwin.nix and
# ./sing-box-config-linux.nix fill these holes and are what the hosts import.
# Keeping the order-sensitive route.rules + common skeleton here (single source
# of truth) is deliberate: a past split shipped `process_name = ["tailscaled"]`
# to macOS, where the daemon is a system network-extension and the rule silently
# never matched.
#
#   tailscaleProcs    Tailscale daemon process name(s), routed direct-out.
#   extraTunExcludes  extra route_exclude_address entries on the TUN inbound.
#   extraBypassRules  rules spliced right after the Tailscale process bypass
#                     (above the quic/udp rejects and the fakeip->vless rule).
#   tunExtra          fields merged into the TUN inbound (e.g. strict_route,
#                     a Linux/Windows option that is a no-op on macOS).
#   cacheFilePath     when non-null, path to the on-disk cache db. Enables
#                     experimental.cache_file with store_fakeip so the fakeip
#                     table survives restarts (otherwise an in-flight
#                     connection/ICMP to a previously-allocated fakeip has no
#                     domain mapping and is dropped with "missing fakeip
#                     record"). Each platform passes a path it can write to.
#   clashApi          when true, expose the localhost Clash API control port so
#                     the vless-main kill-switch can be flipped at runtime. Only
#                     macOS enables it; the Linux CI runner has no reason to open
#                     a control surface.
#   logLevel          sing-box log level. Default "warn". macOS runs "info" so
#                     the interface-monitor lifecycle ("updated default
#                     interface", pause/wake) and urltest selection changes are
#                     visible in the log — at "warn" a monitor wedge and its
#                     recovery look identical (silence), which made the
#                     2026-07 network-drop incidents hard to diagnose. urltest
#                     probe failures log at debug and stay invisible either way.
#   dnsListen         when non-null, an IP to bind a plain-DNS listener on
#                     (a `direct` inbound on port 53, tcp+udp, routed straight
#                     into the DNS module). macOS needs this: it derives an
#                     INTERFACE-SCOPED resolver from the system DNS setting, and
#                     a scoped query carries IP_BOUND_IF so it ignores the route
#                     table — it can never enter the TUN. Only an address the
#                     bound interface itself owns is delivered locally, so the
#                     Mac pins DNS to an alias on en0 and answers it here. See
#                     users/gurinderu/dns-pin.nix and the long comment in
#                     hosts/mac_aarch64/configuration.nix.
#
# Secret values are left as placeholder tokens that each host substitutes at
# activation time, so nothing sensitive ends up in the world-readable Nix store:
#   - macOS (users/gurinderu/sing-box.nix): sed-substitutes from decrypted sops
#     secrets into ~/.config/sing-box/config.json.
#   - NixOS (hosts/thinkpad-x1-gen12/sing-box.nix): sops.templates +
#     builtins.replaceStrings render the config into a root-only /run/secrets file.
#
# Per-server placeholders carry a 1-based index suffix so no token is a prefix
# of another (safe for sed / replaceStrings in any order). For each server N:
#   SING_BOX_SERVER_N, SING_BOX_SERVER_NAME_N, SING_BOX_UUID_N,
#   SING_BOX_PUBLIC_KEY_N, SING_BOX_SHORT_ID_N, and the port via the token
#   "server_port":"SING_BOX_PORT_N" (the quotes are stripped on substitution so
#   the port stays a JSON number).
{
  tailscaleProcs,
  extraTunExcludes ? [ ],
  extraBypassRules ? [ ],
  extraDnsRules ? [ ],
  tunExtra ? { },
  cacheFilePath ? null,
  clashApi ? false,
  logLevel ? "warn",
  dnsListen ? null,
}:
let
  # Per-server transport map (structural, non-secret). See sing-box-secrets.nix.
  transports = (import ./sing-box-secrets.nix).transports;

  # One VLESS+Reality outbound per backend server. Hosts substitute the
  # SING_BOX_*_N tokens with decrypted sops secrets at activation time. The
  # transport (tcp XTLS-Vision vs gRPC/gun) is selected per index from the
  # shared transports map so both render paths stay in sync.
  mkVless =
    n:
    let
      transport = transports.${toString n} or "tcp";
      isGrpc = transport == "grpc";
    in
    {
      type = "vless";
      tag = "vless-out-${toString n}";
      server = "SING_BOX_SERVER_${toString n}";
      server_port = "SING_BOX_PORT_${toString n}";
      uuid = "SING_BOX_UUID_${toString n}";
      # network is left at its default (tcp+udp) so UDP is carried over VLESS via
      # packet_encoding=xudp below. With network="tcp" the outbound dropped all
      # UDP, so anything UDP routed here failed with urltest "missing supported
      # outbound" (WebRTC/games/STUN never worked). QUIC and udp:443 are still
      # rejected at the route level (to force TLS sniffing over TCP); only other
      # UDP now actually flows through the proxy.
      packet_encoding = "xudp";
      tls = {
        enabled = true;
        server_name = "SING_BOX_SERVER_NAME_${toString n}";
        utls = {
          enabled = true;
          # Anti-DPI: chrome uTLS became a proxy marker (obfuscation tools all
          # standardize on it), so JA3/JA4-based DPI flags it. firefox is a
          # "licit"/whitelisted fingerprint — breaks Signal 2 of the 3-signal
          # (ASN + JA3 + frequency) throttling conjunction.
          fingerprint = "firefox";
        };
        reality = {
          enabled = true;
          public_key = "SING_BOX_PUBLIC_KEY_${toString n}";
          short_id = "SING_BOX_SHORT_ID_${toString n}";
        };
      }
      # ALPN h2/http1.1 is set only for the plain-TCP (XTLS-Vision) outbounds.
      # The gRPC transport negotiates h2 itself, so it must not carry an
      # http/1.1 ALPN in the (fake) outer handshake.
      // (
        if isGrpc then
          { }
        else
          {
            alpn = [
              "h2"
              "http/1.1"
            ];
          }
      );
    }
    // (
      if isGrpc then
        {
          # Reality over gRPC (Xray "gun" mode). No flow: xtls-rprx-vision is
          # only valid on the raw-TCP transport.
          transport = {
            type = "grpc";
            service_name = "grpc";
          };
        }
      else
        {
          flow = "xtls-rprx-vision";
        }
    );
in
{
  log = {
    level = logLevel;
    timestamp = true;
  };
  dns = {
    servers = [
      {
        tag = "google";
        # DoH over HTTP/2: handles dropped idle connections gracefully via
        # multiplexing, eliminating the "broken pipe" errors that DoT (tls)
        # produces when the bare TLS connection is closed during inactivity.
        type = "https";
        server = "8.8.8.8";
        # Without a detour the server is dialed DIRECTLY over the default
        # interface — and RKN-side networks block direct TCP to 8.8.8.8 on both
        # 443 and 53 (observed 2026-07-15..17: every exchange died with
        # "dial tcp 8.8.8.8:443: i/o timeout" while UDP/53 and the proxy were
        # fine). Route the DoH dial through the proxy, where 8.8.8.8 is always
        # reachable. Bootstrap is safe: the vless servers are raw IPs, so
        # bringing the proxy up never needs this resolver.
        detour = "vless-main";
      }
      {
        # Russian public resolver (Yandex.DNS), plain UDP dialed direct over the
        # default interface. Serves the geosite-category-ru rule below: RU
        # domains must keep resolving even when the proxy is down, and UDP/53 to
        # 77.88.8.8 is reachable on RKN-side networks that kill TCP to 8.8.8.8.
        # As a RU-located anycast it also returns geo-correct CDN answers.
        tag = "yandex";
        type = "udp";
        server = "77.88.8.8";
      }
      {
        tag = "local";
        type = "local";
      }
      {
        # Tailscale MagicDNS resolver, for tailnet names only (see the ts.net
        # rule below). 100.100.100.100 sits inside the CGNAT range excluded
        # from the TUN, so queries reach it directly over the tailscale
        # interface. This replaces relying on MagicDNS owning resolv.conf —
        # with "Use Tailscale DNS" enabled in the app, ALL system DNS bypasses
        # the TUN (100.100.100.100 is route-excluded) and the fakeip/ECH/RU
        # rules above never see any query.
        tag = "tailscale";
        type = "udp";
        server = "100.100.100.100";
      }
      {
        tag = "fakeip";
        type = "fakeip";
        inet4_range = "198.18.0.0/15";
        inet6_range = "fc00::/18";
      }
    ];
    rules = [
      {
        # Block HTTPS/SVCB DNS records to prevent ECH which breaks
        # SNI sniffing through VLESS+Reality proxy (Cloudflare ECH
        # replaces outer SNI with cloudflare-ech.com)
        query_type = [
          "HTTPS"
          65
        ];
        action = "reject";
      }
      {
        domain_suffix = [
          "cluster.local"
          "fluence.nb"
        ];
        server = "local";
      }
      {
        # Captive-portal probe must resolve via the DHCP resolver so it gets the
        # portal's hijacked IP, not a fakeip routed into an unreachable
        # vless-auto.
        #
        # This rule was doubly broken on macOS until 2026-07-23, and both halves
        # had to be fixed for it to do anything at all:
        #
        #   1. The real CNA probe is issued interface-scoped, and a scoped query
        #      ignores the route table, so it never entered the TUN and never
        #      reached sing-box — it left en0 addressed to the TUN IP and died.
        #      Fixed by dnsListen + the en0 alias (see dns-pin.nix).
        #   2. Even when reached, `server = "local"` LOOPED: on macOS `local`
        #      forwards to the system resolver, which is sing-box itself, so the
        #      probe timed out at the 10s deadline.
        #
        # Neither half is any use without the other, which is why the portal
        # never came up despite this rule existing all along.
        #
        # Why yandex and not `type: dhcp`, the obvious answer to (2): dhcp was
        # tried and removed the same day. It works on some networks (an iPhone
        # hotspot answered in 389ms) and silently does not on others — at the
        # coworking its DHCP probe hit the deadline while plain unicast to the
        # very same gateway resolved fine, leaving captive.apple.com hanging 4s,
        # 8s, 16s per attempt. That is actively harmful here: macOS reassociates
        # Wi-Fi when DNS fails (inducer@DNSFailureRecovery), so a guaranteed slow
        # failure manufactures the exact link drops this repo is trying to stop.
        # A public resolver over plain UDP, dialed direct off the physical NIC,
        # always answers and still satisfies the requirement above — a real
        # routable IP, never a fakeip. Behind a portal it yields the portal's
        # address anyway, since hotspots DNAT udp/53 to themselves.
        domain = [ "captive.apple.com" ];
        server = "yandex";
      }
      {
        # Russian sites must resolve to REAL IPs (not fakeip) so the route rule
        # can send them out direct-out, bypassing the proxy. They cannot use the
        # `local` resolver here: on macOS the system DNS was the sing-box TUN
        # itself (172.19.0.1), so `type: local` looped back into sing-box and
        # every RU lookup died with "i/o timeout" / "no servers could be
        # reached" — which broke all RU domains while fakeip traffic kept
        # working. (That premise changed: the pin is now a public resolver, and
        # whether `local` still loops depends on whether it dials over the route
        # table or interface-bound. UNVERIFIED — recheck before relying on it;
        # yandex below works either way, so nothing here needs to change yet.) They cannot use the google DoH server either: its dial used
        # to go DIRECT and RKN-side networks block TCP to 8.8.8.8, which broke
        # every RU lookup again (2026-07-15..17); now that google detours via
        # the proxy, pinning RU DNS to it would make RU resolution die whenever
        # the proxy is down. Yandex over plain UDP is dialed direct, works on
        # these networks, and returns real routable IPs — the
        # geosite-category-ru route rule still forces the actual connection out
        # direct.
        rule_set = [ "geosite-category-ru" ];
        server = "yandex";
      }
      {
        # Tailscale control plane / DERP must resolve to REAL IPs (not fakeip)
        # so tailscaled can reach them directly via the bypass route rule below;
        # otherwise `tailscale up` gets a fakeip routed into the proxy and times out.
        domain_suffix = [
          "tailscale.com"
          "tailscale.io"
        ];
        server = "local";
      }
      {
        # Tailnet hosts resolve via MagicDNS directly (ssh macbook.<tailnet>.ts.net
        # keeps working with "Use Tailscale DNS" turned OFF in the app).
        domain_suffix = [ "ts.net" ];
        server = "tailscale";
      }
    ]
    ++ extraDnsRules
    ++ [
      {
        # PTR (reverse DNS) and DNS-SD queries: reject outright. macOS sprays
        # `*.in-addr.arpa IN PTR` and `_dns-sd._udp` Bonjour service-discovery
        # lookups constantly, and sing-box's `local` server CANNOT answer
        # non-A/AAAA queries on macOS when it sits behind the TUN with the
        # underlying DHCP resolver unavailable (the normal state on an iPhone
        # hotspot / right after a network switch). Forwarding them to `local`
        # then failed every one with "only A and AAAA queries are supported on
        # Apple platforms when using TUN and DHCP unavailable" at ERROR level —
        # a steady flood that bloated /var/log/sing-box.log to ~790 MB. Reverse
        # DNS and Bonjour discovery are cosmetic over a full tunnel, so answer
        # them with an empty reject instead of a resolver that errors.
        query_type = [ "PTR" ];
        action = "reject";
      }
      {
        # Everything else goes through the VPN; use fakeip so routing
        # happens by domain and DNS does not leak to the local ISP.
        query_type = [
          "A"
          "AAAA"
        ];
        server = "fakeip";
      }
    ];
  };
  inbounds = [
    (
      {
        type = "tun";
        address = [ "172.19.0.1/30" ];
        auto_route = true;
        # Exclude peer networks so their WireGuard routes win over the TUN.
        # Podman's bridge (10.88.0.0/16) is Linux-only and added via
        # extraTunExcludes — without it the TUN swallows the CI runner's
        # container traffic (its DNAT'd Testcontainers Postgres) and tests fail.
        route_exclude_address = [
          "100.90.0.0/16" # NetBird
          "100.64.0.0/10" # Tailscale CGNAT (IPv4)
          "fd7a:115c:a1e0::/48" # Tailscale (IPv6)
        ]
        ++ extraTunExcludes;
        # Sniffing (and destination override) is handled by the route rule
        # `{ action = "sniff"; }` below — the legacy inbound `sniff` /
        # `sniff_override_destination` fields were removed in sing-box 1.13.
      }
      # strict_route (Linux/Windows only; no-op on macOS) arrives via tunExtra.
      // tunExtra
    )
  ]
  ++ (
    if dnsListen == null then
      [ ]
    else
      [
        {
          # Plain-DNS listener for queries that can never reach the TUN — see the
          # dnsListen doc at the top. `network` is deliberately unset so both udp
          # and tcp/53 are served: a truncated answer makes the client retry over
          # TCP, and a udp-only listener would strand that retry. Both verified
          # answering 2026-07-23.
          type = "direct";
          tag = "dns-in";
          listen = dnsListen;
          listen_port = 53;
        }
      ]
  );
  outbounds = [
    {
      type = "direct";
      tag = "direct-out";
    }
    {
      # Sink for the manual kill-switch selector (vless-main) below. type=block
      # drops every connection routed to it; selecting it on vless-main via the
      # Clash API cuts all proxied traffic at once (fail-closed on demand).
      type = "block";
      tag = "block-out";
    }
    # Foreign exits from the niao subscription. 1/4 are XTLS-Vision (raw TCP),
    # 2/3/5/6 are Reality-over-gRPC — the transport is chosen per index from the
    # transports map in sing-box-secrets.nix.
    (mkVless 1) # 🇩🇪 Germany 1 (tcp)
    (mkVless 2) # 🇩🇪 Germany 2 (grpc)
    (mkVless 3) # 🇩🇪 Germany 3 (grpc)
    (mkVless 4) # 🇵🇱 Poland 1 (tcp)
    (mkVless 5) # 🇵🇱 Poland 2 (grpc)
    (mkVless 6) # 🇵🇱 Poland 3 (grpc)
    # vless-out-7 is a Russia-located exit (Yandex Cloud, 158.160.x). It IS a
    # member of the urltest group below, but only as a last-resort fallback:
    # urltest probes every member against https://www.gstatic.com/generate_204
    # (a Google host), which is throttled/slow through a Russian egress, so node
    # 7 measures the highest latency and never wins while any foreign exit is up.
    # It is picked only when all foreign exits are down — keeping connectivity up
    # without routing RKN-blocked sites through a Russian egress in normal use.
    (mkVless 7) # 🇩🇪 Germany bridge 1 (tcp, RU exit)
    # vless-out-8 is a foreign exit not present in the niao subscription, kept as
    # an extra urltest candidate so the auto group has more foreign backends to
    # fail over between.
    (mkVless 8) # foreign exit 194.87.208.142 (tcp)
    {
      # Route through whichever backend is fastest right now: urltest probes each
      # member on `interval`, picks the lowest-latency one, and fails over
      # automatically when it slows down or drops. Foreign exits (1,2,3,4,5,6,8)
      # win in normal use; the RU exit (7) is a latency-penalised last-resort
      # fallback (see its comment above).
      type = "urltest";
      tag = "vless-auto";
      outbounds = [
        "vless-out-1"
        "vless-out-2"
        "vless-out-3"
        "vless-out-4"
        "vless-out-5"
        "vless-out-6"
        "vless-out-7"
        "vless-out-8"
      ];
      url = "https://www.gstatic.com/generate_204";
      interval = "1m";
      tolerance = 50;
      idle_timeout = "30m";
      interrupt_exist_connections = true;
    }
    {
      # Manual kill-switch. Normally forwards to vless-auto (the auto-failover
      # group); flip it to block-out via the Clash API to drop ALL proxied
      # traffic on demand:
      #   curl -X PUT http://127.0.0.1:9090/proxies/vless-main -d '{"name":"block-out"}'
      # and back with '{"name":"vless-auto"}'. interrupt_exist_connections makes
      # the switch take effect on in-flight connections immediately. The routing
      # rules and `final` target THIS outbound, so the switch covers everything
      # that goes through the proxy.
      type = "selector";
      tag = "vless-main";
      outbounds = [
        "vless-auto"
        "block-out"
      ];
      default = "vless-auto";
      interrupt_exist_connections = true;
    }
  ];
  route = {
    rules =
      (
        if dnsListen == null then
          [ ]
        else
          [
            {
              # Everything arriving on the DNS listener IS a query — hand it to
              # the DNS module by inbound tag rather than leaning on the sniffer
              # below. Deterministic, and it must stay FIRST: hijack-dns is a
              # final action, so no later rule can steal this traffic.
              inbound = "dns-in";
              action = "hijack-dns";
            }
          ]
      )
      ++ [
      { action = "sniff"; }
      {
        protocol = "dns";
        action = "hijack-dns";
      }
      {
        # Tailscale manages its own encrypted transport — send everything the
        # daemon emits (control plane, DERP, STUN) straight out, never through
        # vless-out. Must sit above the quic/udp rejects and the fakeip->vless
        # rule so none of its traffic gets rejected or proxied. The process name
        # differs per platform (tailscaled on Linux, the macsys network-extension
        # on macOS), so it is passed in via tailscaleProcs.
        process_name = tailscaleProcs;
        outbound = "direct-out";
      }
    ]
    # Platform-specific Tailscale bypasses spliced in here so they keep their
    # position above the rejects (e.g. a domain_suffix fallback on macOS, where
    # process matching of the network-extension is unreliable).
    ++ extraBypassRules
    ++ [
      {
        # Captive-portal probe goes direct: behind a portal the VPN is not up
        # yet, so the probe must reach the portal (or the real Apple host)
        # rather than be routed into an unreachable vless-auto.
        domain = [ "captive.apple.com" ];
        outbound = "direct-out";
      }
      {
        protocol = "quic";
        action = "reject";
      }
      {
        port = 443;
        network = "udp";
        action = "reject";
      }
      {
        # Russian sites bypassing the VPN.
        rule_set = [
          "geosite-category-ru"
          "geoip-ru"
        ];
        outbound = "direct-out";
      }
      {
        # Fakeip range -> everything else through the VPN.
        ip_cidr = [
          "198.18.0.0/15"
          "fc00::/18"
        ];
        outbound = "vless-main";
      }
      {
        # LAN / gateway / captive-portal page goes direct. MUST stay below the
        # fakeip rule above: the fakeip IPv6 range fc00::/18 is a subset of the
        # ULA fc00::/7 that ip_is_private matches, so placing this higher would
        # divert every IPv6 fakeip connection (proxied AAAA domains) to
        # direct-out and break IPv6 proxying. Real private LAN addresses are not
        # in the fakeip range, so they fall through to here.
        ip_is_private = true;
        outbound = "direct-out";
      }
    ];
    rule_set = [
      {
        type = "remote";
        tag = "geosite-category-ru";
        format = "binary";
        url = "https://github.com/MetaCubeX/meta-rules-dat/raw/sing/geo/geosite/category-ru.srs";
        download_detour = "vless-auto";
        update_interval = "24h";
      }
      {
        type = "remote";
        tag = "geoip-ru";
        format = "binary";
        url = "https://github.com/MetaCubeX/meta-rules-dat/raw/sing/geo/geoip/ru.srs";
        download_detour = "vless-auto";
        update_interval = "24h";
      }
    ];
    auto_detect_interface = true;
    default_domain_resolver = "google";
    # Default everything through the VPN; direct rules above are the
    # exceptions. Blocked-in-Russia resources thus also go via the VPN.
    # vless-main is the kill-switch selector wrapping vless-auto (fastest
    # backend, with the RU node as last-resort fallback).
    final = "vless-main";
  };
  # Localhost-only Clash API control port (macOS only — see clashApi). Used to
  # flip the vless-main kill-switch at runtime (see its outbound comment) and to
  # inspect/select outbounds from a Clash dashboard. Bound to 127.0.0.1 so it is
  # not exposed.
  experimental =
    (if clashApi then { clash_api.external_controller = "127.0.0.1:9090"; } else { })
    // (
      # Persist the fakeip mapping (and other cached state) across restarts.
      # Without it, after a sing-box restart an in-flight connection/ICMP to a
      # fakeip handed out in the previous run has no domain to route to and is
      # dropped with "missing fakeip record, try enable experimental.cache_file".
      # Only emitted on platforms that pass a writable path.
      if cacheFilePath == null then
        { }
      else
        {
          cache_file = {
            enabled = true;
            path = cacheFilePath;
            store_fakeip = true;
          };
        }
    );
}
