{ pkgs, ... }:
{
  imports = [
    ./sing-box.nix
    ./net-observer.nix
    ./dns-fallback.nix
    ./netbird.nix
    ./user-agents.nix
    ./btm-check.nix
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
    # or cache.nixos.org ever gets routed direct-out. NB the figures were
    # measured against vless-out-1; since the 2026-09-05 urltest reorder the
    # empty-history default exit is vless-out-8, whose burst tolerance has not
    # been measured — treat 8 as a floor from a different node, and re-measure
    # there if substitutions start dying mid-transfer again.
    http-connections = 8;

    # Build parallelism cap. nix's default ("use everything") stacked on top
    # of cargo/IDE/VM load repeatedly drove load1 into the hundreds on this
    # fanless 8-core M2 Air (2026-09-02..05: peaks 200-400, nightly
    # rustc/go/nix crash reports, two Jetsam events). Every packet crosses
    # the userspace sing-box process, so host starvation IS a network outage
    # here: at load1 >= 64 over half the tunnel probes fail (measured
    # 2026-07-30), and the control group is just as clear — the one night
    # with no builds (2026-09-05 02:00-09:00) had zero failures.
    #
    # The two knobs are independent: `cores` is per-derivation (NIX_BUILD_CORES;
    # nixpkgs' cargo hook passes it as -j), `max-jobs` is how many derivations
    # build at once — the machine-wide worst case is their PRODUCT. 2 x 2 = at
    # most 4 build threads (and at most ~4 concurrent linkers, under the
    # five-1GB-linker signature that swapped the box out on 2026-07-30), i.e.
    # half the machine even before the QoS demotion below.
    max-jobs = 2;
    cores = 2;
  };

  # The scheduler-priority half of the same fix: run the nix daemon and every
  # build it spawns in the Background QoS band with low-priority IO, so when a
  # build storm and sing-box (ProcessType=Interactive, Nice=-10) race for the
  # cores, the packet path wins. Unlike the count caps above this also covers
  # the case where somebody legitimately raises -j for one build.
  nix.daemonProcessType = "Background";
  nix.daemonIOLowPriority = true;

  # GC + store dedup on a schedule. The disk filled to zero twice around
  # 2026-09-02..04: nix itself crashed mid-build, and dns-fallback's
  # `networksetup -setdnsservers` failed with "No space left on device" —
  # i.e. a full disk breaks the DNS repair path too, turning a disk problem
  # into a network outage. Each time the fix was a manual
  # nix-collect-garbage. 14d keeps enough generations to roll back a bad
  # switch while bounding the store; GC runs daily at 04:00 because the build
  # churn on this machine outpaces a weekly sweep, dedup weekly on Sunday at
  # 05:00 — explicitly an hour AFTER the GC slot, not nix-darwin's 04:15
  # default, so the two never overlap. launchd coalesces missed calendar
  # fires into one run at wake, so a Mac asleep at 04:00 runs them at
  # lid-open — which is also when sing-box re-establishes the TUN; that is
  # why both daemons get the Background/low-IO demotion below (same
  # reasoning as nix.daemonProcessType above) instead of the default
  # unthrottled root job.
  nix.gc = {
    automatic = true;
    interval = {
      Hour = 4;
      Minute = 0;
    };
    options = "--delete-older-than 14d";
  };
  nix.optimise = {
    automatic = true;
    interval = {
      Weekday = 7;
      Hour = 5;
      Minute = 0;
    };
  };
  # nix-darwin's gc/optimise daemons ship with no log sinks and no priority
  # class. Silent-failure is exactly the state this block exists to end (a
  # failing nightly GC reproduces the unnoticed-full-disk incident), so give
  # both the same log-file convention as every other daemon on this host —
  # rotation happens via the sing-box-logrotate stanza (./sing-box.nix).
  launchd.daemons.nix-gc.serviceConfig = {
    ProcessType = "Background";
    LowPriorityIO = true;
    StandardOutPath = "/var/log/nix-gc.log";
    StandardErrorPath = "/var/log/nix-gc.log";
  };
  launchd.daemons.nix-optimise.serviceConfig = {
    ProcessType = "Background";
    LowPriorityIO = true;
    StandardOutPath = "/var/log/nix-optimise.log";
    StandardErrorPath = "/var/log/nix-optimise.log";
  };

  programs.zsh.enable = true;

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
