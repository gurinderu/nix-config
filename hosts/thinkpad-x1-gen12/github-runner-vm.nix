# Guest side of one GitHub Actions runner microVM: a NixOS module for the
# system that runs inside microvm@<name> on the thinkpad. The host side (taps,
# firewall, token refresh, sizing options) is ./github-runner.nix, which
# instantiates this once per runner.
#
# What the guest gets from the host, and nothing else:
#   - /nix/.ro-store  the host store, virtiofs, read-only (virtiofsd --readonly)
#   - /run/host-secrets  a per-VM directory, virtiofs, read-only, holding a
#     short-lived runner REGISTRATION token (not the PAT) and the Docker Hub
#     pull credentials. No sops, no SSH host key, nothing else from /run/secrets.
#   - three block volumes (files under /var/lib/microvms/<name> on the host)
#   - one tap interface whose only way out is the host's sing-box TUN
{
  # Runner record from github-runner.nix: { repo, n, idx }.
  r,
  # Runner name, "<repo>-<n>" (the systemd unit is github-runner-<name>).
  name,
  # { hostIp, guestIp, mac, tap, cid } — see github-runner.nix.
  net,
  # The thinkpad.githubRunnerVms options (vcpu, memMiB, volume sizes).
  sizing,
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Fixed uid/gid. The host writes the Docker Hub files owned by this uid into
  # the secrets share (virtiofs passes ownership through), and a fixed uid
  # keeps rootless podman's storage and subuid range stable on the /var volume.
  runnerUser = "gh-runner";
  runnerUid = 2000;

  # Rootless podman's API socket, served by the runner user's own systemd
  # manager (lingering, so it runs without a login). Jobs reach it through
  # DOCKER_HOST; there is no rootful socket in the guest at all.
  podmanSocket = "/run/user/${toString runnerUid}/podman/podman.sock";

  cacheDir = "/var/cache/github-runner-${name}";
  secretsDir = "/run/host-secrets";

  # Runner job-started hook (ACTIONS_RUNNER_HOOK_JOB_STARTED). One script
  # because the runner accepts a single hook path; the store path must end in
  # .sh or the runner rejects it.
  #
  # 1. Authenticate Docker Hub. All runners share one sing-box exit IP, so
  #    anonymous pulls of the base images (rust/debian/nginx) trip Docker Hub's
  #    per-IP rate limit (`toomanyrequests`) — the failure that killed the warp
  #    #108 container build and left warp-frontend/-bot:main stale. `buildx`
  #    forwards the credentials in $DOCKER_CONFIG/config.json to its buildkit for
  #    the FROM pulls, so seeding docker.io auth here lifts the limit to
  #    per-account with NO workflow change. The workflow's own `docker login
  #    ghcr.io` later merges its entry into the same file. Missing/unreadable
  #    secret -> skip and fall back to anonymous, so a not-yet-provisioned
  #    token never breaks a job.
  #
  # 2. Reap leftover Testcontainers (postgres etc.). The warp suite disables
  #    Ryuk, so a job that was killed (no shutdown hook) leaks its containers;
  #    this sweeps them on the next job's start. One runner per VM and one
  #    podman per runner user, so at job start nothing else can own a live
  #    testcontainer here — the old "more than one Runner.Worker" pool-safety
  #    check from the shared-host days is gone with the shared podman.
  jobStarted = pkgs.writeShellScript "gh-runner-job-started.sh" ''
    set -u

    # 1. Seed docker.io auth into the buildx/docker credential store.
    user_file=${secretsDir}/dockerhub_username
    token_file=${secretsDir}/dockerhub_token
    if [ -n "''${DOCKER_CONFIG:-}" ] && [ -r "$user_file" ] && [ -r "$token_file" ]; then
      ${pkgs.coreutils}/bin/mkdir -p "$DOCKER_CONFIG"
      auth=$(${pkgs.coreutils}/bin/printf '%s:%s' \
               "$(${pkgs.coreutils}/bin/cat "$user_file")" \
               "$(${pkgs.coreutils}/bin/cat "$token_file")" \
             | ${pkgs.coreutils}/bin/base64 -w0)
      ${pkgs.coreutils}/bin/printf \
        '{"auths":{"https://index.docker.io/v1/":{"auth":"%s"}}}\n' "$auth" \
        > "$DOCKER_CONFIG/config.json"
    fi

    # 2. Reap leaked Testcontainers from prior jobs.
    docker() { ${pkgs.docker-client}/bin/docker --host "unix://${podmanSocket}" "$@"; }
    ids=$(docker ps -aq --filter label=org.testcontainers.managed-by=testcontainers 2>/dev/null) || exit 0
    [ -n "$ids" ] && docker rm -f $ids >/dev/null 2>&1
    exit 0
  '';
in
{
  microvm = {
    # cloud-hypervisor over qemu: a much smaller device model (Rust, virtio
    # only, seccomp on by default), and the hypervisor process is exactly what
    # a guest that escapes its kernel attacks next. It has everything this VM
    # needs — KVM, virtiofs, tap, raw volumes, nested VMX. The one qemu-only
    # feature we would use, credentialFiles (fw_cfg), is replaced by the
    # read-only secrets share below.
    hypervisor = "cloud-hypervisor";
    inherit (sizing) vcpu;
    mem = sizing.memMiB;
    # Nested VMX for jobs that build VM images: trading's release builds
    # `.#qcow`, a derivation with requiredSystemFeatures = [ "kvm" ]. Needs
    # kvm_intel's `nested` (default on in current kernels) on the host.
    cloud-hypervisor.extraArgs = [
      "--cpus"
      "nested=on"
    ];
    # systemd readiness of the guest reaches microvm@<name> over vsock
    # (Type=notify), so the unit is "active" only once the guest has booted.
    vsock.cid = net.cid;

    interfaces = [
      {
        type = "tap";
        id = net.tap;
        inherit (net) mac;
      }
    ];

    shares = [
      {
        proto = "virtiofs";
        tag = "ro-store";
        source = "/nix/store";
        mountPoint = "/nix/.ro-store";
        # virtiofsd --readonly: a guest root that remounts the share rw still
        # cannot write the host store. Host-side re-linking (nix-optimise)
        # leaves guests with ESTALE, so configuration.nix keeps it off.
        readOnly = true;
      }
      {
        proto = "virtiofs";
        tag = "host-secrets";
        # Filled and refreshed by ghr-token-<name>.service on the host.
        source = "/run/gh-runner-secrets/${name}";
        mountPoint = secretsDir;
        readOnly = true;
      }
    ];

    # Writable /nix/store: CI runs `nix develop` / `nix build` in nearly every
    # step, so the guest has its own nix-daemon (microvm.nix enables it with an
    # overlay) building into an upper layer on the nix-store volume, with the
    # host store as the read-only lower layer. The guest's Nix database lives
    # on the tmpfs root and only knows the VM's own closure after boot, so a
    # persistent upper layer would hold paths the database has forgotten —
    # microvm.nix's docs say to recreate the overlay before every start, and
    # preStart below does exactly that (as it does for /tmp).
    writableStoreOverlay = "/nix/.rw-store";

    volumes = [
      {
        # Persistent: rustup/cargo/sccache caches under ${cacheDir} (the same
        # path the runners used on the host, which trading's workflows hard-code
        # as CARGO_TARGET_DIR), rootless podman's image store in the runner's
        # home, the runner's state and work dirs, and the guest journal.
        image = "var.img";
        label = "ghr-var";
        mountPoint = "/var";
        size = sizing.varMiB;
      }
      {
        # Scratch, recreated on every VM start. Backs the runner's PrivateTmp,
        # where CARGO_TARGET_DIR points (and where warp's workflows put theirs):
        # disk, not the RAM-backed tmpfs root.
        image = "tmp.img";
        label = "ghr-tmp";
        mountPoint = "/tmp";
        size = sizing.tmpMiB;
      }
      {
        # The writable store layer, recreated on every VM start (see above).
        image = "nix-store.img";
        label = "ghr-nix";
        mountPoint = config.microvm.writableStoreOverlay;
        size = sizing.nixStoreMiB;
      }
    ];

    # Runs on the host as the `microvm` user in /var/lib/microvms/<name>,
    # before microvm.nix creates missing volumes — so these two come back
    # empty, freshly formatted, on every start. var.img is never touched.
    preStart = ''
      rm -f tmp.img nix-store.img
    '';
  };

  # /var must be mounted by the initrd, before stage 2's activation script
  # writes /var/lib/nixos (uid/gid and subuid maps). Mounted later, those
  # maps would land on the tmpfs root, be forgotten every boot, and rootless
  # podman's subuid range — baked into the image store's ownership — could move.
  fileSystems."/var".neededForBoot = true;
  fileSystems.${secretsDir}.options = [
    "ro"
    "nosuid"
    "nodev"
    "noexec"
  ];

  networking.hostName = "ghr-${name}";

  # --- Network: one static /30 to the host, nothing inbound ----------------
  networking.useDHCP = false;
  networking.useNetworkd = true;
  networking.enableIPv6 = false;
  systemd.network.networks."10-uplink" = {
    matchConfig.MACAddress = net.mac;
    address = [ "${net.guestIp}/30" ];
    routes = [ { Gateway = net.hostIp; } ];
    networkConfig.LinkLocalAddressing = "no";
  };
  # Any resolver works: every udp/53 packet that reaches the host's sing-box
  # TUN is hijacked into its DNS module (fakeip for proxied names), exactly as
  # for host processes and the containers the runners used to run on the host.
  networking.nameservers = [ "1.1.1.1" ];
  # Default-deny inbound, no ports opened. (The host drops anything from the
  # VM to itself, the LAN, the tailnet or the other VM — github-runner.nix.)
  networking.firewall.enable = true;

  # Time: no NTP (sing-box rejects most UDP, and nothing else would answer).
  # Sync to the host clock through KVM's PTP device instead — this also
  # catches the guest up after the laptop resumes from suspend, which a
  # paused VM otherwise misses (GitHub's runner auth is time-sensitive).
  boot.kernelModules = [
    "ptp_kvm"
    # /dev/kvm in the guest, for the nested `kvm` builds above.
    "kvm-intel"
  ];
  services.timesyncd.enable = false;
  services.chrony = {
    enable = true;
    servers = [ ];
    extraConfig = ''
      refclock PHC /dev/ptp0 poll 2 dpoll -2 offset 0 stratum 2
      makestep 1.0 -1
    '';
  };

  # The guest journal is on the /var volume, out of the host's reach, so also
  # forward it to the serial console: cloud-hypervisor writes that to its
  # stdout, i.e. into the host's `journalctl -u microvm@<name>`. A text-only
  # channel — the host never parses guest-written files.
  services.journald.console = "/dev/ttyS0";
  services.journald.extraConfig = ''
    MaxLevelConsole=info
    SystemMaxUse=1G
  '';

  # --- Nix ------------------------------------------------------------------
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    # The store is rebuilt per boot, but one boot can still fill the volume
    # (many PRs' dev shells). Collect garbage automatically when it gets low.
    min-free = 4 * 1024 * 1024 * 1024;
    max-free = 16 * 1024 * 1024 * 1024;
  };
  nix.channel.enable = false;
  # Rustup-installed toolchains and other prebuilt binaries expect an FHS
  # loader, as on the host (programs.nix-ld in configuration.nix).
  programs.nix-ld.enable = true;

  # --- Rootless podman --------------------------------------------------------
  virtualisation.podman.enable = true;
  # Mask the rootful API (socket + service). The runner talks only to its own
  # rootless socket; nothing in the guest is meant to reach a root daemon.
  systemd.sockets.podman.enable = false;
  systemd.services.podman.enable = false;
  # Keep per-job networks (`services:` containers, Testcontainers) clear of
  # the 10.89.255.0/24 the VM's own uplink /30 lives in — netavark's default
  # pool is 10.89.0.0/16. Inside the VM nothing else constrains the choice.
  virtualisation.containers.containersConf.settings.network.default_subnet_pools = [
    {
      base = "10.90.0.0/16";
      size = 24;
    }
  ];

  users.groups.${runnerUser}.gid = runnerUid;
  users.users.${runnerUser} = {
    # A normal (non-system) user so it gets a subuid/subgid range for rootless
    # podman; it has no password and nothing listens for logins.
    isNormalUser = true;
    uid = runnerUid;
    group = runnerUser;
    description = "GitHub Actions runner ${name}";
    home = "/var/lib/${runnerUser}";
    createHome = true;
    # Start the user's systemd manager at boot, which socket-activates
    # podman.service on ${podmanSocket}.
    linger = true;
  };

  # --- The runner -------------------------------------------------------------
  services.github-runners.${name} = {
    enable = true;
    url = "https://github.com/gurinderu/${r.repo}";
    # A registration token (valid 1 h), refreshed every 30 min by the host. The
    # classic `repo` PAT that mints it never enters the VM.
    tokenFile = "${secretsDir}/registration-token";
    tokenType = "registration";
    ephemeral = true; # fresh runner per job, auto re-registration
    name = "nixos-thinkpad-${toString r.n}"; # GitHub runner names must be unique per repo
    extraLabels = [
      "nixos"
      "thinkpad"
    ]; # runs-on: [self-hosted, nixos, thinkpad]
    replace = true;

    # A fixed user (not the module's DynamicUser), so the caches under
    # CacheDirectory and the rootless podman store keep one owner.
    user = runnerUser;
    group = runnerUser;

    # Checkouts on the /var volume. The module's default is RuntimeDirectory,
    # i.e. /run: a tmpfs sized from the VM's RAM. Wiped by the module on every
    # (ephemeral) start.
    workDir = "/var/lib/github-runner-work/${name}";

    # Isolated from the system profile. `docker-client` talks to rootless podman.
    extraPackages = with pkgs; [
      docker-client
      git-lfs
      gh
      gnugrep
      gnused
      rustup
      sccache
      mold
    ];

    extraEnvironment = {
      # `docker ...` in jobs -> the runner user's rootless podman.
      DOCKER_HOST = "unix://${podmanSocket}";
      # Testcontainers' Ryuk (JVM/Go/Node clients; testcontainers-rs has none)
      # bind-mounts the socket into its own container: tell it the real path,
      # and run it privileged — which under rootless podman means privileged
      # within the runner user's namespace, not root on anything.
      TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE = podmanSocket;
      TESTCONTAINERS_RYUK_CONTAINER_PRIVILEGED = "true";
      # Per-instance docker/buildx credential store, seeded by the job-started
      # hook; the workflow's `docker login ghcr.io` merges into the same file.
      DOCKER_CONFIG = "${cacheDir}/docker";
      # Caches warmed across jobs, under CacheDirectory on the /var volume.
      RUSTUP_HOME = "${cacheDir}/rustup";
      CARGO_HOME = "${cacheDir}/cargo";
      SCCACHE_DIR = "${cacheDir}/sccache";
      # Build cargo target/ on disk AND on an exec-capable mount: the service's
      # PrivateTmp on the /tmp volume (wiped per service instance).
      CARGO_TARGET_DIR = "/tmp/cargo-target";
      # No per-instance SCCACHE_SERVER_PORT any more: each runner has its own
      # VM and network namespace, so sccache's default port cannot collide.
      ACTIONS_RUNNER_HOOK_JOB_STARTED = "${jobStarted}";
      # nixpkgs builds github-runner with nodeRuntimes = [ "node24" ] only; force any JS
      # action still declaring node20 onto node24 (the GitHub default from 2026-06-16).
      FORCE_JAVASCRIPT_ACTIONS_TO_NODE24 = "true";
    };

    serviceOverrides = {
      # Writable, restart-persistent cache for rustup/cargo/sccache.
      CacheDirectory = "github-runner-${name}";
      # The module sets ProtectHome=true, which also hides /run/user — and with
      # it the rootless podman socket. Nothing else lives under /home here.
      ProtectHome = false;

      # The module sets Restart="on-success" for ephemeral runners, so a failed
      # re-registration (e.g. ExecStartPre overran TimeoutStartSec, or the host
      # has not delivered a registration token yet) leaves the unit dead until a
      # manual restart. Restart on ANY exit so the runner self-heals, and give
      # the slow ExecStartPre (registration + ephemeral _work wipe) more headroom.
      Restart = lib.mkForce "always";
      RestartSec = 30; # space out retries; don't hammer the GitHub API on a flaky network
      TimeoutStartSec = 300;
    };
  };

  systemd.services."github-runner-${name}" = {
    # StartLimitIntervalSec lives in [Unit], not [Service], so it can't go
    # through serviceOverrides. Never let repeated failures wedge the unit.
    startLimitIntervalSec = 0;
    # The rootless podman socket comes from the runner user's manager.
    wants = [ "user@${toString runnerUid}.service" ];
    after = [ "user@${toString runnerUid}.service" ];
  };

  # Self-heal against a silently-wedged listener. The runner reaches the GitHub
  # broker through the host's sing-box fake-ip TUN. When that path flaps, the
  # broker long-poll drops silently: Runner.Listener stays in "Listening for
  # Jobs" with ZERO established connections to GitHub, never exits, so
  # Restart=always never fires and the runner is invisible to GitHub while the
  # queue stalls. Restart the unit when its listener has had no :443
  # connection for a while. A busy runner always holds live connections, so
  # this never interrupts a running job.
  systemd.services."github-runner-${name}-watchdog" = {
    description = "Restart github-runner-${name}.service when its listener loses the GitHub connection";
    serviceConfig.Type = "oneshot";
    path = with pkgs; [
      iproute2
      procps
      systemd
      gnugrep
      coreutils
    ];
    script = ''
      set -u
      unit=github-runner-${name}.service
      systemctl is-active --quiet "$unit" || exit 0
      pid=$(systemctl show -p MainPID --value "$unit")
      [ "''${pid:-0}" -gt 0 ] 2>/dev/null || exit 0
      # give a freshly (re)started listener time to register + connect
      etimes=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
      [ "''${etimes:-0}" -ge 90 ] || exit 0
      conns=$(ss -tnpH state established '( dport = :443 )' 2>/dev/null | grep -c "pid=$pid,")
      if [ "''${conns:-0}" -eq 0 ]; then
        echo "$unit listener (pid $pid, up ''${etimes}s) has no GitHub connection — restarting"
        systemctl restart "$unit"
      fi
    '';
  };
  systemd.timers."github-runner-${name}-watchdog" = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitActiveSec = "2min";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/github-runner-work 0755 root root -"
    "d /var/lib/github-runner-work/${name} 0750 ${runnerUser} ${runnerUser} -"
    # The runner's diagnostic logs (Runner_*.log / Worker_*.log, the module's
    # LogsDirectory) are new files per run and never pruned — an ephemeral
    # runner starts a fresh process per job. Age out anything older than two weeks.
    "e /var/log/github-runner - - - 14d"
  ];

  documentation.enable = false;
  system.stateVersion = "26.05";
}
