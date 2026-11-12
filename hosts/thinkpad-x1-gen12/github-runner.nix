        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
# Self-hosted GitHub Actions runners for gurinderu/warp and gurinderu/trading,
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
# one cloud-hypervisor microVM per runner (microvm.nix).
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
#
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
# Why VMs: the runners used to be host services with access to the host's
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
# rootful podman socket. Any job could `docker run --privileged -v /:/host`
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
# and own the laptop — read /etc/ssh/ssh_host_ed25519_key (this host's sops
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
# age identity, see sing-box.nix), everything under /run/secrets, the runner
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
# PAT. Now a job runs in a guest kernel, with rootless podman inside it as a
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
# second layer, and the guest holds only what it needs: a short-lived runner
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
# registration token and the Docker Hub pull credentials.
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
#
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
# This file is the HOST side: sizing options, the per-VM tap + firewall, the
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
# registration-token refresher and the microvm.vms declarations. The guest
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
# system is ./github-runner-vm.nix.
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
#
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
# Deploy with `nixos-rebuild test` first (a reboot undoes it); per-VM state is
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
# /var/lib/microvms/<name>/var.img (stop the VM, mount it ro for _diag logs).
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
{
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  config,
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  lib,
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  pkgs,
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  ...
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
}:
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
let
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  cfg = config.thinkpad.githubRunnerVms;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.

        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # One entry per repository this box serves; `count` is the number of
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # parallel ephemeral runners (= microVMs) for that repo.
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  repos = [
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    {
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      repo = "warp";
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      count = 1;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    }
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    {
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      repo = "trading";
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      count = 1;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    }
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  ];
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # Flattened instance list: { repo, n, idx } where idx is global and 1-based
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # (warp-1 = 1, trading-1 = 2). It used to pick a per-runner sccache port;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # now it picks each VM's addresses, MAC and vsock CID, which must be unique
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # across ALL runners on the host.
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  runners = lib.concatLists (
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    lib.imap0 (
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ri: r:
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      map (n: {
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        inherit (r) repo;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        inherit n;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        idx = (lib.foldl (acc: x: acc + x.count) 0 (lib.take ri repos)) + n;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      }) (lib.range 1 r.count)
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    ) repos
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  );
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  runnerName = r: "${r.repo}-${toString r.n}"; # VM microvm@<name>; guest unit github-runner-<name>
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.

        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # Each VM gets a point-to-point /30 out of 10.89.255.0/24 on its own tap:
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # host .4*idx+1, guest .4*idx+2. No bridge, so the VMs cannot reach each
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # other except through the host's FORWARD chain, which drops it.
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  #
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # The /24 is NOT arbitrary: it sits inside the 10.88.0.0/15 that sing-box's
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # TUN route-excludes (users/gurinderu/sing-box-config-linux.nix, there for
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # host podman's bridges). Forwarded VM traffic is captured by the TUN's
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # policy routing exactly like podman container traffic is; the replies have
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # to come back to the VM through the main table, which only an excluded
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # destination does — outside that range they would loop back into the TUN.
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # Host podman's netavark carves its per-network /24s from 10.89.0.0/16
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # bottom-up and skips subnets in use on a live interface, so 10.89.255.0/24
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # is the far end of its pool.
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  vmSubnet = "10.89.255.0/24";
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  netFor = r: {
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    hostIp = "10.89.255.${toString (4 * r.idx + 1)}";
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    guestIp = "10.89.255.${toString (4 * r.idx + 2)}";
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    mac = "02:00:00:89:ff:${lib.fixedWidthString 2 "0" (lib.toLower (lib.toHexString r.idx))}";
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    tap = "ghr-${runnerName r}"; # IFNAMSIZ: at most 15 characters (asserted below)
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    cid = 10 + r.idx; # vsock CID, unique per VM (0-2 are reserved)
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  };
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.

        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # The fakeip pool sing-box answers proxied names from: VM traffic to it is
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # legitimate (it is how every proxied hostname resolves), the rest of
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # 172.16.0.0/12 is private and blocked below.
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  fakeipRange = (import ../../users/gurinderu/fakeip-range.nix).range;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.

        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # Destinations a runner VM never gets to, even through the TUN: the host
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # itself (any of its addresses), the LAN, the tailnet/NetBird CGNAT space,
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # the other VMs, link-local, multicast/reserved. GitHub, registries and
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # caches are all public, so CI loses nothing. Dropped in raw PREROUTING,
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # before routing and before any FORWARD rules tailscale/netavark/libvirt add.
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  blockedDsts = [
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    "0.0.0.0/8"
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    "10.0.0.0/8"
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    "100.64.0.0/10"
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    "127.0.0.0/8"
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    "169.254.0.0/16"
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    "172.16.0.0/12"
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    "192.168.0.0/16"
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    "224.0.0.0/3"
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  ];
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.

        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  ipt = "iptables -w";
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  ip6t = "ip6tables -w";
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.

        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # raw PREROUTING rules that hold while the firewall is stopped (see the
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # firewall section below). The comment makes each one exact to -C/-D.
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  stopGuard = [
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    {
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      cmd = ipt;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      match = "-i ghr-+ -m comment --comment ghr-stopped -j DROP";
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    }
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    {
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      cmd = ipt;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      match = "-d ${vmSubnet} -m comment --comment ghr-stopped -j DROP";
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    }
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    {
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      cmd = ip6t;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      match = "-i ghr-+ -m comment --comment ghr-stopped -j DROP";
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    }
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  ];
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.

        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  secretsRoot = "/run/gh-runner-secrets";
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.

        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # Mint a runner registration token for the VM's repo with the PAT and drop
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # it, with the Docker Hub credentials, into the VM's read-only share. A
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # registration token is good for one hour and only registers runners on
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # that one repo; the classic `repo` PAT behind it stays on the host. The
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # Docker Hub files are owned by the guest's runner uid (2000, see
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # github-runner-vm.nix), which reads them in its job-started hook; the
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  # 0700 parent directory keeps host users out.
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  mkTokenService =
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    r:
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    let
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      name = runnerName r;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      dir = "${secretsRoot}/${name}";
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    in
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    {
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      description = "Refresh the GitHub runner registration token for microVM ${name}";
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      wantedBy = [ "multi-user.target" ];
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      wants = [ "network-online.target" ];
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      after = [
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        "network-online.target"
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        "sing-box.service"
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ];
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      path = with pkgs; [
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        coreutils
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        curl
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        jq
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ];
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      serviceConfig = {
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        Type = "oneshot";
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        PrivateTmp = true;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        UMask = "0077";
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        # GitHub or the tunnel can be down at boot; the guest's runner retries
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        # on its own until a token shows up, so keep trying in the background
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        # rather than holding anything up.
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        Restart = "on-failure";
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        RestartSec = 30;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      };
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      unitConfig.StartLimitIntervalSec = 0;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      script = ''
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        set -euo pipefail
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        install -d -m 0700 -o root -g root ${secretsRoot}
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        install -d -m 0755 -o root -g root ${dir}
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.

        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        # The PAT goes to curl in a header file, never on a command line.
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        hdr=$(mktemp)
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        printf 'Authorization: Bearer %s\n' "$(cat ${config.sops.secrets.github_runner_token.path})" > "$hdr"
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        resp=$(curl -fsS --retry 5 --retry-delay 3 --retry-all-errors --max-time 60 -X POST \
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
          -H @"$hdr" \
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
          -H 'Accept: application/vnd.github+json' \
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
          -H 'X-GitHub-Api-Version: 2022-11-28' \
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
          https://api.github.com/repos/gurinderu/${r.repo}/actions/runners/registration-token)
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        rm -f "$hdr"
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        token=$(jq -er '.token' <<<"$resp")
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        expires=$(jq -r '.expires_at' <<<"$resp")
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.

        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        # Atomic replace: the guest may be reading the old one right now.
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        printf '%s' "$token" > ${dir}/.registration-token.new
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        mv -f ${dir}/.registration-token.new ${dir}/registration-token
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        echo "registration token for ${r.repo} refreshed (expires $expires)"
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.

        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        install -m 0400 -o 2000 -g 2000 ${config.sops.secrets.dockerhub_username.path} ${dir}/dockerhub_username
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        install -m 0400 -o 2000 -g 2000 ${config.sops.secrets.dockerhub_token.path} ${dir}/dockerhub_token
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      '';
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    };
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  mkTokenTimer = _r: {
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    wantedBy = [ "timers.target" ];
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    timerConfig = {
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      OnBootSec = "1min";
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      # Half the token's lifetime: the file in the share always has 30+ min left.
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      OnUnitActiveSec = "30min";
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    };
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  };
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.

        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  forEachRunner = f: lib.listToAttrs (map f runners);
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
in
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
{
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  options.thinkpad.githubRunnerVms = {
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # Conservative per-VM defaults for a laptop that is also a desktop. The X1
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # Carbon Gen 12 has a 12- to 16-core Core Ultra 7 and (judging by the 7.8G
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # /run tmpfs, 25% of RAM) 32 GB: two VMs at 4 vCPU / 6 GiB leave the host
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # ~19 GB, most of it for the local agents' ~17 GB model (local-agents.nix),
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # and most of its cores. Raise per box if jobs OOM.
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    vcpu = lib.mkOption {
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      type = lib.types.ints.positive;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      default = 4;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      description = "vCPUs per GitHub runner microVM.";
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    };
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    memMiB = lib.mkOption {
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      type = lib.types.ints.positive;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      default = 6144;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      description = ''
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        RAM per GitHub runner microVM, in MiB. With virtiofs the guest memory
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        is shared, so the host cannot reclaim it while the VM runs; the guest's
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        page cache will grow to fill it.
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      '';
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    };
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # Volumes are sparse files under /var/lib/microvms/<name>; these are caps,
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # not allocations. On the 482 G root, two VMs at the defaults can reach
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # 2 x 208 G only if every volume fills, and tmp/nix-store restart empty.
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    varMiB = lib.mkOption {
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      type = lib.types.ints.positive;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      default = 96 * 1024;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      description = "Persistent /var volume per VM (caches, podman images, runner state), in MiB.";
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    };
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    tmpMiB = lib.mkOption {
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      type = lib.types.ints.positive;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      default = 48 * 1024;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      description = "Scratch /tmp volume per VM (cargo targets), in MiB. Recreated on every VM start.";
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    };
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    nixStoreMiB = lib.mkOption {
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      type = lib.types.ints.positive;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      default = 64 * 1024;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      description = "Writable /nix/store layer per VM, in MiB. Recreated on every VM start.";
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    };
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  };
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.

        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  config = {
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    assertions = map (r: {
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      assertion = builtins.stringLength (netFor r).tap <= 15 && r.idx <= 60;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      message = "github runner ${runnerName r}: tap name over 15 chars, or too many runners for ${vmSubnet}";
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    }) runners;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.

        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # Classic PAT (scope `repo`); shared by all repos (a classic `repo`-scoped
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # PAT can manage runners on any repo the account owns). Used ONLY on the
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # host, by ghr-token-<name>.service, to mint per-repo registration tokens.
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    sops.secrets.github_runner_token = { };
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.

        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # Docker Hub credentials (username + a read-only access token) that each
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # VM's job-started hook bakes into its $DOCKER_CONFIG, so buildx pulls base
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # images authenticated — Docker Hub's per-account limit instead of the
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # anonymous per-IP one the shared sing-box exit trips. Root-only on the
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # host; the token service copies them into the VMs' shares. They must
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # exist in secrets/thinkpad.yaml, or sops-install-secrets fails activation.
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    sops.secrets.dockerhub_username = { };
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    sops.secrets.dockerhub_token = { };
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.

        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    microvm.vms = forEachRunner (
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      r:
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      lib.nameValuePair (runnerName r) {
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        config = import ./github-runner-vm.nix {
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
          inherit r;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
          name = runnerName r;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
          net = netFor r;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
          sizing = cfg;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        };
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        # Default for declarative VMs, spelled out: a rebuild that changes a
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        # VM restarts it, killing a job in flight — as restarting the runner
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        # services on the host did before.
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        restartIfChanged = true;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      }
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    );
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.

        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    systemd.services = lib.mkMerge [
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      (forEachRunner (r: lib.nameValuePair "ghr-token-${runnerName r}" (mkTokenService r)))
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      # Give each tap its host address once microvm.nix has created it, and no
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      # IPv6 at all (no link-local path from the guest to the host's sshd).
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      (forEachRunner (
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        r:
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        let
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
          n = netFor r;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        in
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        lib.nameValuePair "microvm-tap-interfaces@${runnerName r}" {
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
          serviceConfig.ExecStartPost = [
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
            "${pkgs.procps}/bin/sysctl -w net.ipv6.conf.${n.tap}.disable_ipv6=1"
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
            "${pkgs.iproute2}/bin/ip addr replace ${n.hostIp}/30 dev ${n.tap}"
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
          ];
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        }
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ))
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      # Belt to the stop-time guard's braces: a firewall that failed to start
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      # at boot never runs its stop script, so the guard is not there either.
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      # Don't boot a VM without it; stopping the firewall stops the VMs too.
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      (forEachRunner (
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        r:
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        lib.nameValuePair "microvm@${runnerName r}" {
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
          requires = [ "firewall.service" ];
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
          after = [ "firewall.service" ];
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        }
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ))
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    ];
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # Let 0xff restart a stuck runner VM without a password, for maintenance
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # from the cloud VM over SSH: exactly `sudo systemctl restart
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # microvm@<name>.service`, one rule per VM declared above, no wildcards
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # (see the sudo block in configuration.nix for why, and why the store
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # path matches a plain `sudo systemctl`).
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    security.sudo.extraRules = [
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      {
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        users = [ "0xff" ];
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        commands = map (r: {
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
          command = "${config.systemd.package}/bin/systemctl restart microvm@${runnerName r}.service";
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
          options = [ "NOPASSWD" ];
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        }) runners;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      }
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    ];
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.

        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    systemd.timers = forEachRunner (r: lib.nameValuePair "ghr-token-${runnerName r}" (mkTokenTimer r));
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.

        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # Root-only parent of the per-VM secret shares. Named to sort before
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # microvm.nix's own 10-microvm entry for the share directories, which
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # would otherwise create them 0775 microvm:kvm.
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    systemd.tmpfiles.settings."05-gh-runner-secrets" = {
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ${secretsRoot}.d = {
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        user = "root";
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        group = "root";
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        mode = "0700";
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      };
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    }
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    // forEachRunner (
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      r:
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      lib.nameValuePair "${secretsRoot}/${runnerName r}" {
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        d = {
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
          user = "root";
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
          group = "root";
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
          mode = "0755";
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        };
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      }
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    );
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.

        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # NetworkManager must leave the taps alone (they are configured above).
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    networking.networkmanager.unmanaged = [ "interface-name:ghr-*" ];
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.

        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # Route for the VMs. Host podman already flips this on at runtime whenever
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # it sets up a network; this makes it unconditional.
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.

        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # KSM (microvm.nix turns it on by default) buys nothing here — virtiofs
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # needs shared guest memory, which KSM cannot merge — and only adds a
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # cross-VM memory side channel and a scanning thread on a laptop.
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    hardware.ksm.enable = false;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.

        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # VM traffic: out through the sing-box TUN or nowhere.
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    #
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # - raw PREROUTING (ghr-pre): per-VM source anti-spoofing, then drop every
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    #   private/host/tailnet destination except the fakeip pool.
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # - FORWARD (ghr-fwd): from a VM only to tun0, i.e. fail-closed when
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    #   sing-box is down; into a VM only replies.
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # - nat POSTROUTING (ghr-nat): masquerade to tun0's address — the same
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    #   shape podman's netavark gives container traffic, which is the path
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    #   proven to work through this TUN.
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # - INPUT: nothing from a VM reaches a host socket (sshd listens everywhere).
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    #
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # The firewall flushes nixos-fw itself on reload; the ghr-* chains are
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # (re)built idempotently here and torn down in extraStopCommands.
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    #
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # Fail closed. Without the firewall (`systemctl stop firewall`, or a
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # reload that fails: the module then runs firewall-stop) nixos-fw and all
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # of the above are gone, ip_forward stays 1 and FORWARD's policy is ACCEPT
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # — a VM would reach the LAN, the tailnet and sshd. So extraStopCommands
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # leaves a guard in raw PREROUTING: drop everything from a tap, and
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # anything routed towards the VM subnet. Raw PREROUTING runs before
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # routing, so one rule covers INPUT and FORWARD, ahead of whatever
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # tailscale/netavark insert into the filter table. extraCommands removes
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # the guard last, once the ghr-* chains are back. A reload runs
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # extraStopCommands before the start script, so the guard is also up
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # while the rules are rebuilt. (networking.firewall.filterForward is no
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    # alternative: it is nftables-only.)
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    networking.firewall.extraCommands = ''
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ${ipt} -t raw -N ghr-pre 2>/dev/null || ${ipt} -t raw -F ghr-pre
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ${ipt} -t raw -C PREROUTING -i ghr-+ -j ghr-pre 2>/dev/null \
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        || ${ipt} -t raw -I PREROUTING 1 -i ghr-+ -j ghr-pre
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ${lib.concatMapStrings (
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        r:
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        let
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
          n = netFor r;
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        in
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        ''
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
          ${ipt} -t raw -A ghr-pre -i ${n.tap} ! -s ${n.guestIp} -j DROP
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        ''
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ) runners}
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ${ipt} -t raw -A ghr-pre -d ${fakeipRange} -j RETURN
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ${lib.concatMapStrings (d: ''
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        ${ipt} -t raw -A ghr-pre -d ${d} -j DROP
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      '') blockedDsts}
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.

        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ${ipt} -N ghr-fwd 2>/dev/null || ${ipt} -F ghr-fwd
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ${ipt} -C FORWARD -j ghr-fwd 2>/dev/null || ${ipt} -I FORWARD 1 -j ghr-fwd
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ${ipt} -A ghr-fwd -i ghr-+ -o tun0 -j ACCEPT
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ${ipt} -A ghr-fwd -i ghr-+ -j DROP
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ${ipt} -A ghr-fwd -o ghr-+ -i tun0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ${ipt} -A ghr-fwd -o ghr-+ -j DROP
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.

        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ${ipt} -t nat -N ghr-nat 2>/dev/null || ${ipt} -t nat -F ghr-nat
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ${ipt} -t nat -C POSTROUTING -j ghr-nat 2>/dev/null || ${ipt} -t nat -I POSTROUTING 1 -j ghr-nat
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ${ipt} -t nat -A ghr-nat -s ${vmSubnet} -o tun0 -j MASQUERADE
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.

        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ${ipt} -I nixos-fw 1 -i ghr-+ -j DROP
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ${ip6t} -I nixos-fw 1 -i ghr-+ -j DROP
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.

        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      # Everything is in place: lift the stop-time guard (all copies).
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ${lib.concatMapStrings (g: ''
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        while ${g.cmd} -t raw -D PREROUTING ${g.match} 2>/dev/null; do :; done
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      '') stopGuard}
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    '';
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    networking.firewall.extraStopCommands = ''
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ${lib.concatMapStrings (g: ''
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
        ${g.cmd} -t raw -C PREROUTING ${g.match} 2>/dev/null \
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
          || ${g.cmd} -t raw -I PREROUTING 1 ${g.match}
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      '') stopGuard}
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ${ipt} -t raw -D PREROUTING -i ghr-+ -j ghr-pre 2>/dev/null || true
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ${ipt} -t raw -F ghr-pre 2>/dev/null || true
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ${ipt} -t raw -X ghr-pre 2>/dev/null || true
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ${ipt} -D FORWARD -j ghr-fwd 2>/dev/null || true
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ${ipt} -F ghr-fwd 2>/dev/null || true
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ${ipt} -X ghr-fwd 2>/dev/null || true
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ${ipt} -t nat -D POSTROUTING -j ghr-nat 2>/dev/null || true
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ${ipt} -t nat -F ghr-nat 2>/dev/null || true
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
      ${ipt} -t nat -X ghr-nat 2>/dev/null || true
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
    '';
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
  };
        # --retry-all-errors: plain --retry skips a reset connection (curl 56),
        # which is what a switch gets while it restarts sing-box under us; one
        # failed start here makes the whole switch exit 4.
}
