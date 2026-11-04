# Self-hosted GitHub Actions runners for gurinderu/warp and gurinderu/trading,
# one cloud-hypervisor microVM per runner (microvm.nix).
#
# Why VMs: the runners used to be host services with access to the host's
# rootful podman socket. Any job could `docker run --privileged -v /:/host`
# and own the laptop — read /etc/ssh/ssh_host_ed25519_key (this host's sops
# age identity, see sing-box.nix), everything under /run/secrets, the runner
# PAT. Now a job runs in a guest kernel, with rootless podman inside it as a
# second layer, and the guest holds only what it needs: a short-lived runner
# registration token and the Docker Hub pull credentials.
#
# This file is the HOST side: sizing options, the per-VM tap + firewall, the
# registration-token refresher and the microvm.vms declarations. The guest
# system is ./github-runner-vm.nix.
#
# Operating it (deploy, logs, rollback): README.md, "GitHub runner microVMs
# (thinkpad)".
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.thinkpad.githubRunnerVms;

  # One entry per repository this box serves; `count` is the number of
  # parallel ephemeral runners (= microVMs) for that repo.
  repos = [
    {
      repo = "warp";
      count = 1;
    }
    {
      repo = "trading";
      count = 1;
    }
  ];
  # Flattened instance list: { repo, n, idx } where idx is global and 1-based
  # (warp-1 = 1, trading-1 = 2). It used to pick a per-runner sccache port;
  # now it picks each VM's addresses, MAC and vsock CID, which must be unique
  # across ALL runners on the host.
  runners = lib.concatLists (
    lib.imap0 (
      ri: r:
      map (n: {
        inherit (r) repo;
        inherit n;
        idx = (lib.foldl (acc: x: acc + x.count) 0 (lib.take ri repos)) + n;
      }) (lib.range 1 r.count)
    ) repos
  );
  runnerName = r: "${r.repo}-${toString r.n}"; # VM microvm@<name>; guest unit github-runner-<name>

  # Each VM gets a point-to-point /30 out of 10.89.255.0/24 on its own tap:
  # host .4*idx+1, guest .4*idx+2. No bridge, so the VMs cannot reach each
  # other except through the host's FORWARD chain, which drops it.
  #
  # The /24 is NOT arbitrary: it sits inside the 10.88.0.0/15 that sing-box's
  # TUN route-excludes (users/gurinderu/sing-box-config-linux.nix, there for
  # host podman's bridges). Forwarded VM traffic is captured by the TUN's
  # policy routing exactly like podman container traffic is; the replies have
  # to come back to the VM through the main table, which only an excluded
  # destination does — outside that range they would loop back into the TUN.
  # Host podman's netavark carves its per-network /24s from 10.89.0.0/16
  # bottom-up and skips subnets in use on a live interface, so 10.89.255.0/24
  # is the far end of its pool.
  vmSubnet = "10.89.255.0/24";
  netFor = r: {
    hostIp = "10.89.255.${toString (4 * r.idx + 1)}";
    guestIp = "10.89.255.${toString (4 * r.idx + 2)}";
    mac = "02:00:00:89:ff:${lib.fixedWidthString 2 "0" (lib.toLower (lib.toHexString r.idx))}";
    tap = "ghr-${runnerName r}"; # IFNAMSIZ: at most 15 characters (asserted below)
    cid = 10 + r.idx; # vsock CID, unique per VM (0-2 are reserved)
  };

  # The fakeip pool sing-box answers proxied names from: VM traffic to it is
  # legitimate (it is how every proxied hostname resolves), the rest of
  # 172.16.0.0/12 is private and blocked below.
  fakeipRange = (import ../../users/gurinderu/fakeip-range.nix).range;

  # Destinations a runner VM never gets to, even through the TUN: the host
  # itself (any of its addresses), the LAN, the tailnet/NetBird CGNAT space,
  # the other VMs, link-local, multicast/reserved. GitHub, registries and
  # caches are all public, so CI loses nothing. Dropped in raw PREROUTING,
  # before routing and before any FORWARD rules tailscale/netavark/libvirt add.
  blockedDsts = [
    "0.0.0.0/8"
    "10.0.0.0/8"
    "100.64.0.0/10"
    "127.0.0.0/8"
    "169.254.0.0/16"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "224.0.0.0/3"
  ];

  ipt = "iptables -w";
  ip6t = "ip6tables -w";

  secretsRoot = "/run/gh-runner-secrets";

  # Mint a runner registration token for the VM's repo with the PAT and drop
  # it, with the Docker Hub credentials, into the VM's read-only share. A
  # registration token is good for one hour and only registers runners on
  # that one repo; the classic `repo` PAT behind it stays on the host. The
  # Docker Hub files are owned by the guest's runner uid (2000, see
  # github-runner-vm.nix), which reads them in its job-started hook; the
  # 0700 parent directory keeps host users out.
  mkTokenService =
    r:
    let
      name = runnerName r;
      dir = "${secretsRoot}/${name}";
    in
    {
      description = "Refresh the GitHub runner registration token for microVM ${name}";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "sing-box.service"
      ];
      path = with pkgs; [
        coreutils
        curl
        jq
      ];
      serviceConfig = {
        Type = "oneshot";
        PrivateTmp = true;
        UMask = "0077";
        # GitHub or the tunnel can be down at boot; the guest's runner retries
        # on its own until a token shows up, so keep trying in the background
        # rather than holding anything up.
        Restart = "on-failure";
        RestartSec = 30;
      };
      unitConfig.StartLimitIntervalSec = 0;
      script = ''
        set -euo pipefail
        install -d -m 0700 -o root -g root ${secretsRoot}
        install -d -m 0755 -o root -g root ${dir}

        # The PAT goes to curl in a header file, never on a command line.
        hdr=$(mktemp)
        printf 'Authorization: Bearer %s\n' "$(cat ${config.sops.secrets.github_runner_token.path})" > "$hdr"
        resp=$(curl -fsS --retry 3 --max-time 60 -X POST \
          -H @"$hdr" \
          -H 'Accept: application/vnd.github+json' \
          -H 'X-GitHub-Api-Version: 2022-11-28' \
          https://api.github.com/repos/gurinderu/${r.repo}/actions/runners/registration-token)
        rm -f "$hdr"
        token=$(jq -er '.token' <<<"$resp")
        expires=$(jq -r '.expires_at' <<<"$resp")

        # Atomic replace: the guest may be reading the old one right now.
        printf '%s' "$token" > ${dir}/.registration-token.new
        mv -f ${dir}/.registration-token.new ${dir}/registration-token
        echo "registration token for ${r.repo} refreshed (expires $expires)"

        install -m 0400 -o 2000 -g 2000 ${config.sops.secrets.dockerhub_username.path} ${dir}/dockerhub_username
        install -m 0400 -o 2000 -g 2000 ${config.sops.secrets.dockerhub_token.path} ${dir}/dockerhub_token
      '';
    };
  mkTokenTimer = _r: {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      # Half the token's lifetime: the file in the share always has 30+ min left.
      OnUnitActiveSec = "30min";
    };
  };

  forEachRunner = f: lib.listToAttrs (map f runners);
in
{
  options.thinkpad.githubRunnerVms = {
    # Conservative per-VM defaults for a laptop that is also a desktop. The X1
    # Carbon Gen 12 has a 12- to 16-core Core Ultra 7 and (judging by the 7.8G
    # /run tmpfs, 25% of RAM) 32 GB: two VMs at 4 vCPU / 8 GiB leave the host
    # half its RAM and most of its cores. Raise per box if jobs OOM.
    vcpu = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
      description = "vCPUs per GitHub runner microVM.";
    };
    memMiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8192;
      description = ''
        RAM per GitHub runner microVM, in MiB. With virtiofs the guest memory
        is shared, so the host cannot reclaim it while the VM runs; the guest's
        page cache will grow to fill it.
      '';
    };
    # Volumes are sparse files under /var/lib/microvms/<name>; these are caps,
    # not allocations. On the 482 G root, two VMs at the defaults can reach
    # 2 x 208 G only if every volume fills, and tmp/nix-store restart empty.
    varMiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 96 * 1024;
      description = "Persistent /var volume per VM (caches, podman images, runner state), in MiB.";
    };
    tmpMiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 48 * 1024;
      description = "Scratch /tmp volume per VM (cargo targets), in MiB. Recreated on every VM start.";
    };
    nixStoreMiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 64 * 1024;
      description = "Writable /nix/store layer per VM, in MiB. Recreated on every VM start.";
    };
  };

  config = {
    assertions = map (r: {
      assertion = builtins.stringLength (netFor r).tap <= 15 && r.idx <= 60;
      message = "github runner ${runnerName r}: tap name over 15 chars, or too many runners for ${vmSubnet}";
    }) runners;

    # Classic PAT (scope `repo`); shared by all repos (a classic `repo`-scoped
    # PAT can manage runners on any repo the account owns). Used ONLY on the
    # host, by ghr-token-<name>.service, to mint per-repo registration tokens.
    sops.secrets.github_runner_token = { };

    # Docker Hub credentials (username + a read-only access token) that each
    # VM's job-started hook bakes into its $DOCKER_CONFIG, so buildx pulls base
    # images authenticated — Docker Hub's per-account limit instead of the
    # anonymous per-IP one the shared sing-box exit trips. Root-only on the
    # host; the token service copies them into the VMs' shares. They must
    # exist in the secrets file, or sops-install-secrets fails activation.
    sops.secrets.dockerhub_username = { };
    sops.secrets.dockerhub_token = { };

    microvm.vms = forEachRunner (
      r:
      lib.nameValuePair (runnerName r) {
        config = import ./github-runner-vm.nix {
          inherit r;
          name = runnerName r;
          net = netFor r;
          sizing = cfg;
        };
        # Default for declarative VMs, spelled out: a rebuild that changes a
        # VM restarts it, killing a job in flight — as restarting the runner
        # services on the host did before.
        restartIfChanged = true;
      }
    );

    systemd.services = lib.mkMerge [
      (forEachRunner (r: lib.nameValuePair "ghr-token-${runnerName r}" (mkTokenService r)))
      # Give each tap its host address once microvm.nix has created it, and no
      # IPv6 at all (no link-local path from the guest to the host's sshd).
      (forEachRunner (
        r:
        let
          n = netFor r;
        in
        lib.nameValuePair "microvm-tap-interfaces@${runnerName r}" {
          serviceConfig.ExecStartPost = [
            "${pkgs.procps}/bin/sysctl -w net.ipv6.conf.${n.tap}.disable_ipv6=1"
            "${pkgs.iproute2}/bin/ip addr replace ${n.hostIp}/30 dev ${n.tap}"
          ];
        }
      ))
    ];
    systemd.timers = forEachRunner (r: lib.nameValuePair "ghr-token-${runnerName r}" (mkTokenTimer r));

    # Root-only parent of the per-VM secret shares. Named to sort before
    # microvm.nix's own 10-microvm entry for the share directories, which
    # would otherwise create them 0775 microvm:kvm.
    systemd.tmpfiles.settings."05-gh-runner-secrets" = {
      ${secretsRoot}.d = {
        user = "root";
        group = "root";
        mode = "0700";
      };
    }
    // forEachRunner (
      r:
      lib.nameValuePair "${secretsRoot}/${runnerName r}" {
        d = {
          user = "root";
          group = "root";
          mode = "0755";
        };
      }
    );

    # NetworkManager must leave the taps alone (they are configured above).
    networking.networkmanager.unmanaged = [ "interface-name:ghr-*" ];

    # Route for the VMs. Host podman already flips this on at runtime whenever
    # it sets up a network; this makes it unconditional.
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

    # KSM (microvm.nix turns it on by default) buys nothing here — virtiofs
    # needs shared guest memory, which KSM cannot merge — and only adds a
    # cross-VM memory side channel and a scanning thread on a laptop.
    hardware.ksm.enable = false;

    # VM traffic: out through the sing-box TUN or nowhere.
    #
    # - raw PREROUTING (ghr-pre): per-VM source anti-spoofing, then drop every
    #   private/host/tailnet destination except the fakeip pool.
    # - FORWARD (ghr-fwd): from a VM only to tun0, i.e. fail-closed when
    #   sing-box is down; into a VM only replies.
    # - nat POSTROUTING (ghr-nat): masquerade to tun0's address — the same
    #   shape podman's netavark gives container traffic, which is the path
    #   proven to work through this TUN.
    # - INPUT: nothing from a VM reaches a host socket (sshd listens everywhere).
    #
    # The firewall flushes nixos-fw itself on reload; the ghr-* chains are
    # (re)built idempotently here and torn down in extraStopCommands.
    networking.firewall.extraCommands = ''
      ${ipt} -t raw -N ghr-pre 2>/dev/null || ${ipt} -t raw -F ghr-pre
      ${ipt} -t raw -C PREROUTING -i ghr-+ -j ghr-pre 2>/dev/null \
        || ${ipt} -t raw -I PREROUTING 1 -i ghr-+ -j ghr-pre
      ${lib.concatMapStrings (
        r:
        let
          n = netFor r;
        in
        ''
          ${ipt} -t raw -A ghr-pre -i ${n.tap} ! -s ${n.guestIp} -j DROP
        ''
      ) runners}
      ${ipt} -t raw -A ghr-pre -d ${fakeipRange} -j RETURN
      ${lib.concatMapStrings (d: ''
        ${ipt} -t raw -A ghr-pre -d ${d} -j DROP
      '') blockedDsts}

      ${ipt} -N ghr-fwd 2>/dev/null || ${ipt} -F ghr-fwd
      ${ipt} -C FORWARD -j ghr-fwd 2>/dev/null || ${ipt} -I FORWARD 1 -j ghr-fwd
      ${ipt} -A ghr-fwd -i ghr-+ -o tun0 -j ACCEPT
      ${ipt} -A ghr-fwd -i ghr-+ -j DROP
      ${ipt} -A ghr-fwd -o ghr-+ -i tun0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
      ${ipt} -A ghr-fwd -o ghr-+ -j DROP

      ${ipt} -t nat -N ghr-nat 2>/dev/null || ${ipt} -t nat -F ghr-nat
      ${ipt} -t nat -C POSTROUTING -j ghr-nat 2>/dev/null || ${ipt} -t nat -I POSTROUTING 1 -j ghr-nat
      ${ipt} -t nat -A ghr-nat -s ${vmSubnet} -o tun0 -j MASQUERADE

      ${ipt} -I nixos-fw 1 -i ghr-+ -j DROP
      ${ip6t} -I nixos-fw 1 -i ghr-+ -j DROP
    '';
    networking.firewall.extraStopCommands = ''
      ${ipt} -t raw -D PREROUTING -i ghr-+ -j ghr-pre 2>/dev/null || true
      ${ipt} -t raw -F ghr-pre 2>/dev/null || true
      ${ipt} -t raw -X ghr-pre 2>/dev/null || true
      ${ipt} -D FORWARD -j ghr-fwd 2>/dev/null || true
      ${ipt} -F ghr-fwd 2>/dev/null || true
      ${ipt} -X ghr-fwd 2>/dev/null || true
      ${ipt} -t nat -D POSTROUTING -j ghr-nat 2>/dev/null || true
      ${ipt} -t nat -F ghr-nat 2>/dev/null || true
      ${ipt} -t nat -X ghr-nat 2>/dev/null || true
    '';
  };
}
