# macOS-specific sing-box config: fills the platform holes in ./sing-box-config.nix.
# Imported by users/gurinderu/sing-box.nix (home-manager activation writer).
import ./sing-box-config.nix {
  # On macOS the Tailscale daemon is the system network-extension, not the
  # `tailscaled` binary that exists on Linux. `Tailscale` is the GUI app.
  tailscaleProcs = [
    "Tailscale"
    "io.tailscale.ipn.macsys.network-extension"
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
      # Scope is deliberately narrow: the WireGuard peer and relay traffic is
      # addressed by raw IP with no domain to match on, so it falls through to
      # the process rule below and is NOT double-encrypted. Matching here works
      # via SNI sniffing — the DNS rule below returns a real IP for this host,
      # not a fakeip, so there is a genuine TLS ClientHello to sniff.
      process_name = [
        "netbird"
        "netbird-ui"
      ];
      domain = [ "netbird.infrahub.cloudless.dev" ];
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
      # yandex rather than `local`, which is what the Tailscale rule uses: on
      # macOS `local` forwards to the system resolver, which is sing-box itself
      # (networking.dns pins the alias this very config answers on), so it can
      # loop — that is documented on the captive.apple.com rule, where it timed
      # out at the 10s deadline. yandex is plain UDP dialed direct off the
      # physical NIC, so it also keeps working when the proxy is down, which is
      # the condition under which one is most likely to want the mesh up.
      # Control-plane host only — the dashboard must keep getting a fakeip so
      # it goes through the proxy. This real IP exists for the daemon's
      # process_name bypass; see the note where that route rule used to be.
      domain = [ "netbird.infrahub.cloudless.dev" ];
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
