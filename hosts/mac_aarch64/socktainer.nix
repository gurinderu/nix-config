# socktainer as a nix package + launchd user agent. Serves the Docker Engine
# API the nix-provided docker / docker-compose clients (users/gurinderu/
# home.nix) talk to through the `socktainer` docker context, without Colima's
# always-on VM reserving 4 CPU / 8 GB — each container gets a lightweight
# Linux VM that lives only while the container runs. Colima stays installed
# (users/gurinderu/darwin.nix) as the fallback for what the socktainer preview
# can't do: no pause/commit/top, network connect is a no-op, no static IPs.
#
# Moved here from brew (formula + `brew services`) on 2026-09-25, for two
# reasons found the hard way:
#
#   * brew's service plist runs socktainer with
#     HOME=/opt/homebrew/var/run/socktainer, so the API socket silently lands
#     under THAT path while the docker context points at
#     ~/.socktainer/container.sock — "Cannot connect to the Docker daemon"
#     with the daemon perfectly healthy.
#   * the brew `container` formula (socktainer's declared dependency) kept
#     re-appearing linked as 1.3.1 after brew reinstalls, shadowing the pinned
#     1.2.0. socktainer 1.2.1 is compiled against container 1.2.0's XPC
#     exactly; with 1.3.1 the docker API "works" but socktainer never learns
#     container IPs, so compose inter-service DNS returns NXDOMAIN (observed
#     2026-09-08).
#
# The data plane is Apple's signed installer pkg for `container` 1.2.0 in
# /usr/local/bin (outside brew AND nix on purpose: it is an XPC service tree
# with its own launchd registration, installed by Apple's pkg; `container
# system start` brings up container-apiserver). Re-evaluate the whole pin when
# socktainer pins container >= 1.3 (its master pinned 1.2.2 on 2026-09-08).
#
# Known non-nix trap that motivated the activation snippet below: `colima
# start` flips docker's currentContext to "colima" and nothing flips it back
# when colima stops — after a fallback session, `docker context use
# socktainer` by hand. currentContext itself stays user-owned (managing it
# declaratively would fight exactly that sanctioned fallback), but the
# socktainer context's ENDPOINT is healed on every switch.
{ pkgs, ... }:
let
  socktainer = pkgs.callPackage ../../pkgs/socktainer { };
in
{
  launchd.user.agents.socktainer = {
    serviceConfig = {
      ProgramArguments = [ "${socktainer}/bin/socktainer" ];
      RunAtLoad = true;
      # Plain `true`, unlike the Ice agent (default.nix): this is an API
      # server nothing quits deliberately — if it exits at all (e.g. started
      # before container-apiserver on a fresh boot), launchd should keep
      # retrying until it sticks.
      KeepAlive = true;
      EnvironmentVariables = {
        # launchd agents start with no HOME in their environment, and
        # socktainer derives the socket path from it. This is the exact knob
        # brew got wrong; pin it so the socket lands where the docker context
        # looks: ~/.socktainer/container.sock.
        HOME = "/Users/gurinderu";
        # /usr/local/bin first: Apple's pinned container 1.2.0 pkg.
        PATH = "/usr/local/bin:/usr/bin:/bin";
      };
      StandardOutPath = "/Users/gurinderu/Library/Logs/socktainer.log";
      StandardErrorPath = "/Users/gurinderu/Library/Logs/socktainer-error.log";
    };
  };

  home-manager.users.gurinderu =
    { config, ... }:
    {
      home.activation.socktainerConverge = config.lib.dag.entryAfter [ "writeBoundary" ] ''
        # One-shot convergence away from the brew-era service: its agent (fake
        # HOME, see header) serves the socket in the wrong place and holds DNS
        # port 2054, which the nix agent also binds — two instances fight, so
        # boot the brew one out if it is still around.
        if [ -e "$HOME/Library/LaunchAgents/homebrew.mxcl.socktainer.plist" ]; then
          /bin/launchctl bootout "gui/$(id -u)/homebrew.mxcl.socktainer" 2>/dev/null || true
          rm -f "$HOME/Library/LaunchAgents/homebrew.mxcl.socktainer.plist"
        fi
        # Pin the socktainer docker context's endpoint to the socket the agent
        # above serves. Written straight into docker's context store (contexts
        # are addressed by sha256 of their name; no docker CLI or running
        # daemon needed), so a drifted endpoint — like the brew-path detour of
        # 2026-09-25 — is healed by the next switch.
        ctx="$HOME/.docker/contexts/meta/a45d1c9c5463be6d8233242ee34823546d5d479015d9fd49068df083eef2c52e"
        mkdir -p "$ctx"
        printf '%s' '{"Name":"socktainer","Metadata":{"Description":"Socktainer — Docker API over Apple Container"},"Endpoints":{"docker":{"Host":"unix:///Users/gurinderu/.socktainer/container.sock","SkipTLSVerify":false}}}' > "$ctx/meta.json"
        # Buildx builder "apple" (the BUILDX_BUILDER default set in
        # users/gurinderu/darwin.nix): remote driver on a buildkitd socket
        # published from a moby/buildkit container that runs INSIDE Apple
        # container — Apple's own builder VM does not expose its buildkit
        # daemon (apple/container-builder-shim#74), so a stock buildkit image
        # with `--publish-socket <sock>:/run/buildkit/buildkitd.sock` stands
        # in. Only the buildx instance FILE is healed here; the buildkitd
        # container itself is runtime state (`container run -d --name
        # buildkitd --cpus 2 --memory 4g … docker.io/moby/buildkit:buildx-stable-1`,
        # recreate — not restart — it when builds start failing with
        # "operation not permitted"; a `container run -d` does not survive
        # reboot, so after one: `container start buildkitd`).
        #
        # CPU/memory discipline (sing-box lives on this host; measured
        # starvation history — load 64+ → probe failures): every Apple
        # container is its own VM and DEFAULTS to 4 CPUs / 1 GiB, and
        # socktainer 1.2.1 hardcodes that default for docker-created
        # containers with no limits (the `container system property set
        # container.cpus` route only lands in socktainer > 1.2.1). What DOES
        # work today: explicit limits — socktainer 1.2.1 maps docker's
        # NanoCpus/Memory onto the VM, so `docker run --cpus 2 -m 1g` and
        # compose `cpus:`/`mem_limit:` are honored. Keep buildkitd at
        # --cpus 2, and give trading-style compose services explicit cpus:
        # limits rather than letting each service VM claim the 4-CPU default.
        # (sing-box itself is shielded launchd-side: ProcessType=Interactive,
        # Nice=-10 in ./sing-box.nix.)
        #
        # Known wart: the socket sits under /opt/homebrew/var/run — that is
        # ONLY a directory choice made when the builder was first stood up,
        # no brew software is involved (post-2026-09-25 brew's whole role on
        # this host is casks). Migrating to a brew-free path means recreating
        # the container with `--publish-socket ~/.local/run/buildkitd.sock:…`
        # AND flipping the endpoint below in the same breath — don't do it
        # while a session is iterating on the buildkitd container.
        bx="$HOME/.docker/buildx/instances"
        mkdir -p "$bx"
        printf '%s' '{"Name":"apple","Driver":"remote","Nodes":[{"Name":"apple0","Endpoint":"unix:///opt/homebrew/var/run/buildkitd.sock","Platforms":null,"DriverOpts":null,"Flags":null,"Files":null}],"Dynamic":false}' > "$bx/apple"
      '';
    };
}
