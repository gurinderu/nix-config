{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Pool of parallel ephemeral runners. The box (ThinkPad X1 Gen 12, 16C/22T, 31 GiB)
  # comfortably runs 3 heavy jobs at once; within a single PR this lets Build/Clippy/CRAP
  # (heavy) plus fmt/cargo-deny (light) run in parallel instead of serialising on one runner.
  runnerIds = lib.range 1 3;
  runnerName = n: "warp-${toString n}"; # systemd unit: github-runner-warp-${n}

  # Runner job-started hook (ACTIONS_RUNNER_HOOK_JOB_STARTED). Does two things,
  # in one script because the runner accepts a single hook path; the store path
  # must end in .sh or the runner rejects the hook.
  #
  # 1. Authenticate Docker Hub. The three runners share one sing-box exit IP, so
  #    anonymous pulls of the base images (rust/debian/nginx) trip Docker Hub's
  #    per-IP rate limit (`toomanyrequests`) — the failure that killed the warp
  #    #108 container build and left warp-frontend/-bot:main stale. `buildx`
  #    forwards the credentials in $DOCKER_CONFIG/config.json to its buildkit for
  #    the FROM pulls, so seeding docker.io auth here lifts the limit to
  #    per-account with NO workflow change and everything still egressing through
  #    the tunnel. The workflow's own `docker login ghcr.io` later merges its
  #    entry into the same file (docker login preserves other registries' auths),
  #    so the GHCR push keeps working. Missing/unreadable secret -> skip and fall
  #    back to anonymous, so a not-yet-provisioned token never breaks a job.
  #
  # 2. Reap leftover Testcontainers (postgres etc.). Root podman is CI-only. The
  #    warp suite disables Ryuk, so a job that was killed (no shutdown hook) leaks
  #    its containers; this sweeps them on the next job's start.
  #    Pool-safety: the sweep nukes ALL testcontainers-managed containers via the
  #    shared Podman socket, so it must NOT run while a *concurrent* job has live
  #    containers. A job has a `Runner.Worker` process only while it runs, and our
  #    own job is exactly one worker; if we see more than one, another runner is
  #    mid-job, so we skip the sweep and leave its containers alone. This needs
  #    the runner's ProtectProc != "invisible" (set in serviceOverrides below) so
  #    the hook can see other DynamicUsers' workers in /proc.
  jobStarted = pkgs.writeShellScript "gh-runner-job-started.sh" ''
    set -u

    # 1. Seed docker.io auth into the buildx/docker credential store.
    user_file=${config.sops.secrets.dockerhub_username.path}
    token_file=${config.sops.secrets.dockerhub_token.path}
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

    # 2. Reap leaked Testcontainers from prior jobs (pool-safe).
    if [ "$(${pkgs.procps}/bin/pgrep -fc 'Runner\.Worker' 2>/dev/null || echo 0)" -gt 1 ]; then
      exit 0
    fi
    host="unix:///run/podman/podman.sock"
    docker() { ${pkgs.docker-client}/bin/docker --host "$host" "$@"; }
    ids=$(docker ps -aq --filter label=org.testcontainers.managed-by=testcontainers 2>/dev/null) || exit 0
    [ -n "$ids" ] && docker rm -f $ids >/dev/null 2>&1
    exit 0
  '';

  # One ephemeral runner instance.
  mkRunner = n: {
    enable = true;
    url = "https://github.com/gurinderu/warp";
    tokenFile = config.sops.secrets.github_runner_warp_token.path;
    ephemeral = true; # fresh runner per job, auto re-registration
    name = "nixos-thinkpad-${toString n}"; # GitHub runner names must be unique per instance
    extraLabels = [
      "nixos"
      "thinkpad"
    ]; # runs-on: [self-hosted, nixos, thinkpad]
    replace = true;

    # Isolated from the system/home-manager profiles, so duplicating packages the host
    # user also has is intentional. `docker-client` talks to the Podman socket.
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
      # `docker ...` in jobs -> Podman's Docker-compatible API (engine runs as root).
      DOCKER_HOST = "unix:///run/podman/podman.sock";
      # Per-instance docker/buildx credential store. The job-started hook seeds
      # docker.io auth here (so buildx pulls base images authenticated, dodging
      # the shared-IP anonymous rate limit); the workflow's `docker login
      # ghcr.io` merges its entry into the same file. Under CacheDirectory so it
      # is writable and persists across the instance's jobs.
      DOCKER_CONFIG = "/var/cache/github-runner-warp-${toString n}/docker";
      # Per-instance caches: a SHARED CARGO_HOME across concurrent runners races the
      # cargo package-cache lock ("failed to acquire package cache lock"). Each runner
      # keeps its own rustup/cargo/sccache, warmed across its jobs via CacheDirectory.
      RUSTUP_HOME = "/var/cache/github-runner-warp-${toString n}/rustup";
      CARGO_HOME = "/var/cache/github-runner-warp-${toString n}/cargo";
      SCCACHE_DIR = "/var/cache/github-runner-warp-${toString n}/sccache";
      # Build cargo target/ on disk AND on an exec-capable mount. Under DynamicUser
      # systemd mounts CacheDirectory/StateDirectory (/var/cache,/var/lib) noexec,
      # so build scripts / proc-macros in target/ there die with "Permission denied
      # (os error 13)". The service PrivateTmp /tmp is the right spot: disk-backed
      # (ext4 on the 482G /, NOT the small /run tmpfs), exec-allowed, and private +
      # wiped per service instance (no cross-runner collision). Fixes the ENOSPC
      # from 3 parallel builds sharing the 7.8G /run tmpfs for their checkouts.
      CARGO_TARGET_DIR = "/tmp/cargo-target";
      # ...and a DISTINCT sccache server port per instance. All three runners
      # share this one host; without this each sccache server defaults to port
      # 4226, so two concurrent jobs collide and the loser dies with
      # "sccache: failed to spawn ... (exit 254)", failing whichever job was
      # compiling (usually the heavy Workspace-tests job). Per-instance port
      # (warp-1=4226, warp-2=4227, warp-3=4228) lets the parallel servers
      # coexist. Inherited by the job steps, so no per-repo ci.yml change needed.
      SCCACHE_SERVER_PORT = toString (4225 + n);
      # Runner runs this before every job -> seed docker.io auth + sweep leaked
      # Testcontainers from prior jobs (see jobStarted).
      ACTIONS_RUNNER_HOOK_JOB_STARTED = "${jobStarted}";
      # nixpkgs builds github-runner with nodeRuntimes = [ "node24" ] only; force any JS
      # action still declaring node20 onto node24 (the GitHub default from 2026-06-16).
      FORCE_JAVASCRIPT_ACTIONS_TO_NODE24 = "true";
    };

    serviceOverrides = {
      # Access the Podman socket (group `podman`).
      SupplementaryGroups = [ "podman" ];
      # The module sets PrivateUsers=true, which maps the host GID `podman` to nobody
      # inside the user namespace and voids the supplementary group. Disable it so the
      # group actually grants socket access.
      PrivateUsers = false;
      # Writable, restart-persistent cache for rustup/cargo/sccache (per instance).
      CacheDirectory = "github-runner-warp-${toString n}";

      # The module sets Restart="on-success" for ephemeral runners, so a failed
      # re-registration (e.g. ExecStartPre overran TimeoutStartSec) leaves the unit dead
      # until a manual restart. Restart on ANY exit so the runner self-heals, and give
      # the slow ExecStartPre (registration + ephemeral _work wipe) more headroom.
      Restart = lib.mkForce "always";
      RestartSec = 30; # space out retries; don't hammer the GitHub API on a flaky network
      TimeoutStartSec = 300;

      # The module hardens the unit with ProtectProc="invisible" (hidepid for the
      # service), which would hide other runners' Runner.Worker from the reap hook and
      # break the pool-safety check in reapTestcontainers. Relax it so the hook can see
      # them. Acceptable on a single-tenant CI box.
      ProtectProc = lib.mkForce "default";
    };
  };

  # Self-heal against a silently-wedged listener. The ephemeral runner reaches the
  # GitHub broker through sing-box's fake-ip TUN (all egress is tunnelled). When that
  # path flaps the broker long-poll drops silently: Runner.Listener stays in "Listening
  # for Jobs" with ZERO established connections to GitHub, never exits, so Restart=always
  # never fires and the runner is invisible to GitHub while the queue stalls. Restart the
  # unit when its listener has had no :443 connection for a while. A busy runner always
  # holds live connections, so this never interrupts a running job.
  mkWatchdogService =
    n:
    let
      unit = "github-runner-${runnerName n}.service";
    in
    {
      description = "Restart ${unit} when its listener loses the GitHub connection";
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
        unit=${unit}
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
  mkWatchdogTimer = _n: {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitActiveSec = "2min"; # check every 2 minutes
    };
  };

  forEachRunner = f: lib.listToAttrs (map f runnerIds);
in
{
  # Classic PAT (scope `repo`) used to register the runners; shared by all instances.
  # tokenFile is read by root in ExecStartPre, so the sops secret's root:0400 is enough.
  sops.secrets.github_runner_warp_token = { };

  # Docker Hub credentials (username + a read-only access token) the job-started
  # hook bakes into each runner's $DOCKER_CONFIG so buildx pulls base images
  # authenticated — Docker Hub's per-account limit instead of the anonymous
  # per-IP one the shared sing-box exit trips. Group-readable by `podman` because
  # the hook runs as the DynamicUser runner (supplementary group `podman`), not
  # root. Add `dockerhub_username` and `dockerhub_token` to secrets.yaml before
  # rebuilding, or sops-install-secrets fails activation.
  sops.secrets.dockerhub_username = {
    group = "podman";
    mode = "0440";
  };
  sops.secrets.dockerhub_token = {
    group = "podman";
    mode = "0440";
  };

  services.github-runners = forEachRunner (n: lib.nameValuePair (runnerName n) (mkRunner n));

  systemd.services = lib.mkMerge [
    (forEachRunner (
      n: lib.nameValuePair "github-runner-${runnerName n}-watchdog" (mkWatchdogService n)
    ))
    # StartLimitIntervalSec lives in [Unit], not [Service], so it can't go through
    # serviceOverrides. Disable the start-rate limiter so repeated start failures can
    # never wedge a unit into `failed` (start-limit-hit).
    (forEachRunner (
      n: lib.nameValuePair "github-runner-${runnerName n}" { startLimitIntervalSec = 0; }
    ))
  ];

  systemd.timers = forEachRunner (
    n: lib.nameValuePair "github-runner-${runnerName n}-watchdog" (mkWatchdogTimer n)
  );
}
