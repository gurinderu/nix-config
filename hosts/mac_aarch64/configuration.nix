{ pkgs, ... }:
{
  imports = [
    ./sing-box.nix
    ./net-observer.nix
    ./dns-fallback.nix
  ];

  # Pin system DNS to the address sing-box's own DNS listener answers on — an
  # alias this machine owns on its physical interfaces, NOT the TUN address and
  # NOT a public resolver. Both alternatives were tried and both are wrong; the
  # reasoning is worth keeping because neither failure is visible without a
  # packet capture.
  #
  # The requirement: DNS must not go to the on-link DHCP resolver, because the
  # connected /24-ish route always beats the TUN's /1 chunk routes, so such
  # queries bypass the TUN and none of the sing-box DNS design works — no fakeip
  # domain routing, no ECH blocking, no ts.net rule — while on RU consumer
  # networks the resolver hands out RKN-poisoned answers (observed:
  # instagram.com -> 127.0.0.1 on MegaFon).
  #
  # Why not the TUN address (172.19.0.1), which was pinned here until
  # 2026-07-23: macOS derives from this setting BOTH a global resolver and an
  # interface-SCOPED one (`scutil --dns`: `if_index : 11 (en0), flags: Scoped`).
  # A scoped query carries IP_BOUND_IF and therefore IGNORES the route table —
  # it is emitted straight out en0, addressed to a utun-local IP the gateway
  # routes nowhere, and dies unanswered. Every interface-scoped lookup on the
  # machine was silently broken: the captive-portal probe (CNA asks once, gets
  # nothing, gives up, so the login sheet never appears and the network is never
  # authenticated), tailscaled's control-plane lookups, iCloud's probes. Proven
  # in a router-side capture at the coworking (18:01:50, ttl 64, no reply, no
  # retry) and reproduced on an iPhone hotspot. A per-domain /etc/resolver
  # override does NOT reach these: macOS lists no domain resolvers in the scoped
  # section at all.
  #
  # Why not a public resolver (8.8.8.8), the obvious next guess: it fixes the
  # scoped path and destroys everything else. Once scoped queries succeed,
  # mDNSResponder PREFERS that path, so the whole system resolver goes straight
  # to 8.8.8.8 over the wire and sing-box never sees a query. Measured: `dig`
  # (unscoped, into the TUN) returned the fakeip 198.18.0.21 while
  # `dscacheutil` — the path every real application uses — returned the real
  # 140.82.121.4. The scoped queries dying was load-bearing: it was the only
  # thing keeping macOS on the unscoped path.
  #
  # So the pin has to be an address that is BOTH local to the bound interface
  # (so scoped queries are delivered instead of transmitted) and served by
  # sing-box (so the rule set still applies). An alias on the physical NICs is
  # the only thing that is both. Verified: with the alias up, every query on the
  # machine — scoped probes and ordinary lookups alike — appeared on lo0 headed
  # for this address, and nothing leaked to en0.
  #
  # Fail-closed is preserved: no sing-box, no listener, no DNS — the same
  # failure domain as route.final, and the reason dns-fallback.nix still exists.
  networking.knownNetworkServices = [
    "Wi-Fi"
    "USB 10/100/1000 LAN"
  ];
  networking.dns = [ (import ../../users/gurinderu/dns-pin.nix) ];

  # Split DNS for tailnet names: mDNSResponder sends *.ts.net queries straight
  # to the MagicDNS resolver over the OS route table (via the tailscale utun).
  # This cannot go through sing-box: its dials are interface-bound to the
  # physical NIC (auto_detect_interface), so from inside sing-box
  # 100.100.100.100 is unreachable — the ts.net rule in the shared config
  # only covers raw resolv.conf clients. Works with "Use Tailscale DNS" off.
  environment.etc."resolver/ts.net".text = ''
    nameserver 100.100.100.100
  '';

  environment.systemPackages = [ pkgs.vim ];

  nix.package = pkgs.nix;
  nix.settings = {
    experimental-features = "nix-command flakes";
    trusted-users = [
      "root"
      "gurinderu"
    ];

    # cache.nixos.org has no direct-out rule, so it resolves to fakeip and the
    # whole substitution goes out through vless-main like any other foreign
    # traffic. The VLESS outbounds run plain xtls-rprx-vision with no
    # multiplexing, so every parallel fetch nix opens is its own TCP +
    # REALITY handshake against a single node.
    #
    # At nix's default of 25 that burst kills the node: on 2026-07-26 20:30 a
    # `darwin-rebuild switch` opened ~31 concurrent connections and every one
    # of them died mid-transfer ("Failed sending data to the peer",
    # SSL_ERROR_SYSCALL) at a different offset, then resumed with 0 bytes
    # until nix gave up. The sing-box log for that window shows all 124 lines
    # on one outbound (vless-out-1) with no urltest switch, so this is
    # per-node connection load and not selector thrash.
    #
    # 12 parallel fetches sustain ~40 MB/s aggregate through the same node, so
    # 8 leaves comfortable headroom. Raise only if the exit gains multiplexing
    # or cache.nixos.org ever gets routed direct-out.
    http-connections = 8;
  };

  programs.zsh.enable = true;

  system.configurationRevision = null;
  system.stateVersion = 6;
  system.primaryUser = "gurinderu";

  nixpkgs.hostPlatform = "aarch64-darwin";
  nixpkgs.overlays = [
    (_: prev: {
      direnv = prev.direnv.overrideAttrs (_: {
        doCheck = false;
      });
    })
  ];
  nixpkgs.config.allowUnfree = true;

  users.users.gurinderu.home = "/Users/gurinderu";
}
