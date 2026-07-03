{ pkgs, ... }:
{
  imports = [
    ./sing-box.nix
    ./net-observer.nix
    ./dns-fallback.nix
  ];

  # Pin system DNS to the sing-box TUN address (see users/gurinderu/
  # sing-box-config.nix, tun inbound 172.19.0.1/30 — keep in sync). Without
  # this, DNS goes to the on-link DHCP resolver and BYPASSES the TUN entirely
  # (the connected /24-ish route always beats the TUN's /1 chunk routes), so
  # none of the sing-box DNS design works: no fakeip domain routing, no ECH
  # blocking, no ts.net rule — and on RU consumer networks the resolver hands
  # out RKN-poisoned answers (observed: instagram.com -> 127.0.0.1 on
  # MegaFon). Pinned to the TUN, every query is hijack-dns'ed by sing-box and
  # the full rule set applies; the `local` DNS server reads the DHCP servers
  # directly (not resolv.conf), so there is no loop, and the captive-portal
  # CNA bypasses in the shared config keep portals working.
  #
  # Trade-off: DNS is fail-closed on sing-box like all other traffic already
  # is (route.final) — same failure domain, healed by KeepAlive plus the
  # net-observer watchdog. NB: resolv.conf becomes near-constant across
  # networks, so the sing-box-netreload WatchPaths trigger fires rarely; the
  # watchdog is the primary recovery path.
  networking.knownNetworkServices = [
    "Wi-Fi"
    "USB 10/100/1000 LAN"
  ];
  networking.dns = [ "172.19.0.1" ];

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
