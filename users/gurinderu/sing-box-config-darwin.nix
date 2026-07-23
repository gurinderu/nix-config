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
  ];

  extraDnsRules = [
    {
      process_name = [ "Captive Network Assistant" ];
      server = "local";
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
