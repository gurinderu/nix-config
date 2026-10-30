# macOS-specific sing-box config: fills the platform holes in ./sing-box-config.nix.
# Imported by users/gurinderu/sing-box.nix (home-manager activation writer).
#
# `uplinkInterface` is a MACHINE fact (this Mac's Wi-Fi is en0), so it is not
# hardcoded here — it is threaded in from the host (hosts/mac_aarch64/default.nix
# via home-manager.extraSpecialArgs) and passed to the shared config as
# `defaultInterface`. See the defaultInterface doc in ./sing-box-config.nix.
{ uplinkInterface }:
import ./sing-box-config.nix {
  # On macOS the Tailscale daemon is a system network-extension whose name
  # depends on the build: `macsys` for the standalone download, `macos` for the
  # App Store build. `tailscaled` covers the open-source build, which runs the
  # same daemon binary as Linux. `Tailscale` is the GUI app.
  tailscaleProcs = [
    "Tailscale"
    "io.tailscale.ipn.macsys.network-extension"
    "io.tailscale.ipn.macos.network-extension"
    "tailscaled"
  ];

  # Belt-and-suspenders: even if process matching misses the network-extension,
  # keep Tailscale's control plane / DERP off the proxy by domain. These resolve
  # to real IPs via the `local` DNS rule, so SNI sniffing catches the TLS ones.
  extraBypassRules = [
    {
      domain_suffix = [
        "tailscale.com"
        "tailscale.io"
      ];
      outbound = "direct-out";
    }
    {
      # CNA login sheet loads the portal on an arbitrary PUBLIC domain, which
      # would otherwise hit fakeip -> vless-auto. Send all it emits direct.
      process_name = [ "Captive Network Assistant" ];
      outbound = "direct-out";
    }
    {
      # EXCEPTION to the netbird direct-out bypass below, and it must stay ABOVE
      # it — first matching rule wins. The daemon's gRPC session to the
      # self-hosted control plane goes through the proxy; everything else it
      # emits stays direct.
      #
      # Why: the direct path to this host is broken. TLS completes in ~0.2s and
      # then nothing comes back — measured 2026-08-19 on an iPhone hotspot,
      # `curl --interface en0` to /api/users timed out at 15s with 0 bytes,
      # while the same request through the proxy returned in 0.9s. This is the
      # same degradation the note further down records for the dashboard
      # (responses over ~16 KB dropped with ERR_CONNECTION_CLOSED); it has since
      # grown from truncation into a full stall. The effect on the daemon is
      # that management dial hits its 30s deadline and retries forever, so the
      # peer never registers and `netbird up` appears to hang.
      #
      # The IdP host (authentik.cloudless.dev) is included for the same reason:
      # the daemon itself does the SSO token exchange and OIDC discovery, and on
      # 2026-10-30 its PKCE token POST timed out on the direct path (TLS
      # handshake timeout / unexpected EOF, never reaching authentik), leaving
      # `netbird up` stuck in LoginFailed while the browser, via `final`, worked.
      #
      # Scope is deliberately narrow: the WireGuard peer and relay traffic is
      # addressed by raw IP with no domain to match on, so it falls through to
      # the process rule below and is NOT double-encrypted. Matching here works
      # via SNI sniffing — the DNS rules below return a real IP for these hosts,
      # not a fakeip, so there is a genuine TLS ClientHello to sniff.
      process_name = [
        "netbird"
        "netbird-ui"
      ];
      domain = [
        "netbird.cloudless.dev"
        "netbird.infrahub.cloudless.dev"
        "authentik.cloudless.dev"
      ];
      outbound = "vless-main";
    }
    {
      # NetBird (hosts/mac_aarch64/netbird.nix) is the same shape of problem as
      # Tailscale above: it carries its own WireGuard encryption, so nothing it
      # emits should be wrapped in VLESS. Its peer-to-peer and relay traffic is
      # addressed by raw IP with no domain to match on, so the process rule is
      # what actually covers it. `netbird` is the daemon, `netbird-ui` the
      # menu-bar app (which talks to the control plane on its own).
      #
      # Unlike Tailscale this is a plain root daemon rather than a system
      # network-extension, so process matching here is reliable — but the
      # domain rule below still backs it up.
      process_name = [
        "netbird"
        "netbird-ui"
      ];
      outbound = "direct-out";
    }
    # NOTE: there is deliberately NO domain rule for the control-plane host
    # here. The daemon is already covered by the process_name rule above, which
    # is the half that actually matters (its peer/relay traffic is raw IP with
    # no domain to match on anyway). A domain rule would additionally drag the
    # BROWSER's calls to the same host — the dashboard's own API — onto the
    # direct path, and that path drops any response over ~16 KB with
    # ERR_CONNECTION_CLOSED (measured 2026-08-19: a 41 KB asset stalled at
    # ~18 KB here and completed in 0.4s from another network). That left the
    # dashboard spinning forever on /api/users. The paired DNS rule below still
    # returns a REAL IP so the daemon's direct route has somewhere to go;
    # browser traffic to that same IP simply falls through to `final`.
  ];

  extraDnsRules = [
    {
      # `local` measured non-looping through the pin on 2026-09-09 (see the
      # tailscale DNS rule in ./sing-box-config.nix) — the shared premise this
      # rule leans on. The CNA-specific path itself is only exercisable at a
      # real captive portal, so it stays measured-by-proxy.
      process_name = [ "Captive Network Assistant" ];
      server = "local";
    }
    {
      # NetBird's self-hosted control plane must resolve to a REAL routable IP,
      # never a fakeip, or the paired direct-out route rule above has nothing
      # routable to send and the peer never registers. (Measured 2026-07-29
      # before this rule existed: netbird.infrahub.cloudless.dev -> 198.18.2.192,
      # a fakeip — and the same answer came back even for an explicit
      # `dig @77.88.8.8`, since the DNS listener hijacks those too.)
      #
      # yandex rather than `local` (which the Tailscale rule uses). The
      # original reason was a loop: in the TUN-pin era `local` forwarded to
      # the system resolver — sing-box itself — and captive.apple.com timed
      # out on exactly that. That premise is HISTORICAL now: measured
      # 2026-09-09 through the 192.0.2.53 pin, `local` resolves via the
      # native scoped resolvers and does not loop (see the tailscale rule in
      # ./sing-box-config.nix). yandex stays for the reason that survives
      # the measurement: plain UDP dialed direct off the physical NIC keeps
      # answering with a REAL routable IP even while the proxy is down —
      # the condition under which one most wants the mesh up.
      # Control-plane host only — the dashboard must keep getting a fakeip so
      # it goes through the proxy. This real IP exists for the daemon's
      # process_name bypass; see the note where that route rule used to be.
      domain = [
        "netbird.cloudless.dev"
        "netbird.infrahub.cloudless.dev"
      ];
      server = "yandex";
    }
    {
      # The NetBird dashboard (a public page) fetches the IdP discovery document
      # from authentik.cloudless.dev. A fakeip answer lands in 172.24.0.0/16 —
      # private space — and Chrome's Local Network Access then blocks that
      # public-to-local fetch ("Permission was denied for this request to access
      # the `local` address space"), so the dashboard fails with
      # "Unauthenticated" (observed 2026-10-16/17). A real IP keeps the fetch
      # public; the browser's traffic to it still falls through to `final`, the
      # same as for the NetBird control-plane host above. The daemon's own IdP
      # calls are routed to vless-main by the netbird exception route rule.
      domain = [ "authentik.cloudless.dev" ];
      server = "yandex";
    }
  ];

  # No podman bridge and no strict_route on macOS (the latter is a Linux/Windows
  # no-op), so extraTunExcludes and tunExtra stay at their empty defaults.

  # Answer plain DNS on the pinned address. macOS cannot be made to send its
  # interface-scoped queries into the TUN, so sing-box comes out to meet them:
  # the address is an alias on the physical interfaces (installed by the start
  # script in hosts/mac_aarch64/sing-box.nix), which makes a scoped query resolve
  # locally instead of being flung at the gateway. Single source of truth for the
  # address, shared with networking.dns — a mismatch kills DNS outright.
  dnsListen = import ./dns-pin.nix;

  # Pin sing-box's egress to the machine's uplink (threaded from the host).
  # Auto-detect latches onto the second `default` route tailscale installs
  # through its own utun, so every proxied dial dies with "no route to
  # internet" (measured 2026-09-17; survived restart and reboot because
  # tailscale reinstalls the route). See the defaultInterface doc in
  # ./sing-box-config.nix, including the USB-dongle caveat.
  defaultInterface = uplinkInterface;

  # Persist the fakeip table across restarts. The launchd daemon
  # (hosts/mac_aarch64/sing-box.nix) runs as root and creates this dir before
  # exec'ing sing-box.
  cacheFilePath = "/var/lib/sing-box/cache.db";

  # Expose the localhost Clash API so the vless-main kill-switch can be toggled
  # at runtime (curl/dashboard against 127.0.0.1:9090). macOS is the interactive
  # machine; the Linux runner leaves this off.
  clashApi = true;

  # info (not the default warn) so interface-monitor recovery and urltest
  # selection changes are visible — see the logLevel doc in ./sing-box-config.nix.
  # Volume is bounded by the logrotate daemon in hosts/mac_aarch64/sing-box.nix.
  logLevel = "info";
}
