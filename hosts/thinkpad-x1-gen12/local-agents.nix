# Local coding agents: hydro-project's infinity (pkgs/infinity), backed by
# huihui-ai's abliterated (refusal-removed) Qwen3.6-35B-A3B, a 35B MoE with
# ~3B active parameters per token, served by llama.cpp on this machine — no
# cloud model involved.
#
#   llama-cpp.service              llama-server, 127.0.0.1:18101, alias
#                                  "local", Vulkan on the Arc iGPU
#   infinity-daemon.service        `infinity daemon` as the `agent` user:
#                                  /var/lib/agent/.infinity/daemon.sock,
#                                  WebSocket on 127.0.0.1:18102
#     └─ spawns, per ~/.infinity/providers.json, the "local" provider
#        (infinity-provider-openai-compat → llama-server's /v1 Chat API)
#     └─ spawns, per ~/.infinity/rap.json, sandbox-local (file/git/shell
#        tools, writes confined with bubblewrap)
#
# Isolation. The model writes and runs code, so it gets nothing of 0xff's:
# a system user with its own home (/var/lib/agent), a hardened system unit
# (no /home, no devices, no control sockets, no new privileges), and
# iptables owner rules that keep it off the laptop's own ports (llama-server
# excepted), the tailnet, the runner VMs and host podman/libvirt networks;
# the LAN is an option (thinkpad.localAgents.allowLan). sandbox-local's own
# bwrap (`--ro-bind / /`) only adds write confinement on top of that.
#
# Use, as 0xff (README, "Local agents (thinkpad)"):
#   agent-import ~/src/foo        copy the repo in (git bundle; no hooks,
#                                 config or hardlinks shared)
#   agents foo                    infinity TUI in /var/lib/agent/work/foo
#   agents foo -H "task"          headless
#   agent-fetch foo               (inside ~/src/foo) fetch the agent's
#                                 branches as agent-foo/*, then review
# sandbox-local's tools work only after the agent calls `clone_repo` on the
# project (it then edits a git worktree); a small local model may need that
# spelled out in the task. Logs: /var/lib/agent/.infinity/daemon.log,
# `journalctl -u infinity-daemon -u llama-cpp`.
#
# The two JSON files are store symlinks, so `infinity rap install --user` /
# `infinity provider install` cannot edit them; add entries here instead.
#
# The model comes from the store (fetchurl, ~17 GB, pinned to an HF commit):
# mradermacher's imatrix Q3_K_M of huihui-ai/Huihui-Qwen3.6-35B-A3B-abliterated
# (Apache-2.0, like the Qwen base). Abliteration strips the refusals, not just
# the safety prose; huihui-ai warns its output is unfiltered — it is for this
# machine's own security work.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.thinkpad.localAgents;

  llamaPort = 18101;
  wsPort = 18102;

  infinity = pkgs.callPackage ../../pkgs/infinity { };

  model = pkgs.fetchurl {
    url = "https://huggingface.co/mradermacher/Huihui-Qwen3.6-35B-A3B-abliterated-i1-GGUF/resolve/860d616938187b0a7fb2dfcb24d07911b6364904/Huihui-Qwen3.6-35B-A3B-abliterated.i1-Q3_K_M.gguf";
    # Equals the file's LFS sha256 on HF.
    hash = "sha256-pz0Nbji+bHJ0XzpgwxHIv8TkrqhKYXZR+ytNJ+f/w6g=";
  };

  # Per agent: what infinity is told, so compaction keeps each agent within
  # it. llama-server gets one slot per concurrent agent (parent plus
  # spawn_thread children) and room for all of them at full size. Only 10 of
  # the model's 40 layers keep a KV cache (the other 30 are Gated DeltaNet
  # linear attention with a fixed ~2 MB state per layer and agent), so a
  # token costs ~10.6 KB at q8_0: 2 x 32k is ~0.7 GB.
  contextSize = 32768;
  slots = 2;

  # The provider is configured by env; `env` keeps it a plain argv in
  # providers.json, independent of the daemon's environment.
  providers = {
    local.command = [
      "${pkgs.coreutils}/bin/env"
      "OPENAI_COMPAT_BASE_URL=http://127.0.0.1:${toString llamaPort}/v1"
      "OPENAI_COMPAT_MODEL=local"
      "OPENAI_COMPAT_CONTEXT=${toString contextSize}"
      # Qwen3.6 thinks before every answer, and the thinking counts against
      # this; the provider's 4096 default cuts long turns off mid-thought.
      "OPENAI_COMPAT_MAX_OUTPUT=8192"
      "OPENAI_COMPAT_DISPLAY=Qwen3.6-35B-A3B abliterated (local)"
      "${infinity}/bin/infinity-provider-openai-compat"
    ];
  };
  rap.tool_sets = [
    {
      type = "toolset_command";
      command = "${infinity}/bin/sandbox-local";
    }
  ];

  user = "agent";
  agentHome = "/var/lib/agent";
  work = "${agentHome}/work";
  systemctl = "${config.systemd.package}/bin/systemctl";

  # What the agents' shell commands get on PATH (plus the system profile).
  # Extend here; the agent user has no profile of its own.
  agentPackages = with pkgs; [
    infinity
    git
    bubblewrap
    bash
    coreutils
    findutils
    diffutils
    gnugrep
    gnused
    gawk
    gnutar
    gzip
    xz
    patch
    which
    file
    less
    procps
    curl
    jq
    ripgrep
    fd
    gnumake
    gcc
    python3
  ];
  agentPath = "${lib.makeBinPath agentPackages}:/run/current-system/sw/bin";

  gitconfig = pkgs.writeText "agent-gitconfig" ''
    [user]
      name = local agent
      email = agent@localhost
    [init]
      defaultBranch = main
  '';

  # Workspace names become directories under ${work}.
  checkName = ''
    case "$name" in
      "" | .* | *[!A-Za-z0-9._-]*)
        echo "bad workspace name '$name' (letters, digits, . _ -; no leading dot)" >&2
        exit 2
        ;;
    esac
  '';

  # The three commands 0xff may run as the agent user (sudo rules below).
  # Each sets its own HOME and PATH: sudo resets the environment.
  #
  # The TUI. It refuses when the service is down: the CLI would otherwise
  # start a daemon itself, outside the unit's sandbox (still uid agent, so
  # the firewall rules hold, but none of the rest).
  tuiAsAgent = pkgs.writeShellScript "agent-tui" ''
    set -euo pipefail
    export HOME=${agentHome} PATH=${agentPath}
    name=''${1:-}
    ${checkName}
    shift
    case "''${1:-}" in
      daemon | restart | stop | update | acp)
        echo "agents: '$1' is not available here; the daemon is infinity-daemon.service" >&2
        exit 2
        ;;
    esac
    if ! ${systemctl} is-active --quiet infinity-daemon.service; then
      echo "agents: infinity-daemon.service is not running" >&2
      exit 1
    fi
    cd ${work}/"$name"
    exec ${infinity}/bin/infinity "$@"
  '';
  # A fresh repo from a bundle on stdin: branches and tags only, so nothing
  # of the source's config, hooks or object store comes along.
  importAsAgent = pkgs.writeShellScript "agent-import-inner" ''
    set -euo pipefail
    export HOME=${agentHome} PATH=${agentPath}
    umask 077
    name=''${1:-}
    branch=''${2:-}
    ${checkName}
    git check-ref-format --branch "$branch" >/dev/null
    dest=${work}/"$name"
    if [ -e "$dest" ]; then
      echo "agent-import: $dest exists" >&2
      exit 1
    fi
    tmp=$(mktemp -d -p ${agentHome})
    trap 'rm -rf "$tmp"' EXIT
    cat >"$tmp/in.bundle"
    git init -q -b "$branch" "$dest"
    git -C "$dest" fetch -q --update-head-ok "$tmp/in.bundle" \
      '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*'
    git -C "$dest" reset -q --hard
  '';
  # The workspace's branches and tags as a bundle on stdout.
  exportAsAgent = pkgs.writeShellScript "agent-export-inner" ''
    set -euo pipefail
    export HOME=${agentHome} PATH=${agentPath}
    name=''${1:-}
    ${checkName}
    cd ${work}/"$name"
    exec git bundle create -q - --branches --tags
  '';

  # 0xff's side. Results come back as a bundle too, so 0xff's git never
  # opens the agent's repository (its config, hooks and attributes are the
  # agent's to write) and no safe.directory exception is needed.
  agentCommands = [
    (pkgs.writeShellScriptBin "agents" ''
      if [ $# -lt 1 ]; then
        echo "usage: agents <workspace> [infinity args...]   (workspaces: agent-import)" >&2
        exit 2
      fi
      exec /run/wrappers/bin/sudo -u ${user} ${tuiAsAgent} "$@"
    '')
    (pkgs.writeShellScriptBin "agent-import" ''
      set -euo pipefail
      if [ $# -lt 1 ] || [ $# -gt 2 ]; then
        echo "usage: agent-import <repo-path> [workspace-name]" >&2
        exit 2
      fi
      top=$(${pkgs.git}/bin/git -C "$1" rev-parse --show-toplevel)
      name=''${2:-$(basename "$top")}
      if ! branch=$(${pkgs.git}/bin/git -C "$top" symbolic-ref --short -q HEAD); then
        echo "agent-import: $top has a detached HEAD; check out a branch first" >&2
        exit 1
      fi
      ${pkgs.git}/bin/git -C "$top" bundle create -q - --branches --tags \
        | /run/wrappers/bin/sudo -u ${user} ${importAsAgent} "$name" "$branch"
      echo "imported $top ($branch, committed state only) as ${work}/$name"
      echo "next: agents $name"
    '')
    (pkgs.writeShellScriptBin "agent-fetch" ''
      set -euo pipefail
      if [ $# -ne 1 ]; then
        echo "usage: agent-fetch <workspace>   (run inside your own repo)" >&2
        exit 2
      fi
      name=$1
      ${pkgs.git}/bin/git rev-parse --git-dir >/dev/null
      tmp=$(mktemp -d)
      trap 'rm -rf "$tmp"' EXIT
      /run/wrappers/bin/sudo -u ${user} ${exportAsAgent} "$name" >"$tmp/agent.bundle"
      ${pkgs.git}/bin/git -c fetch.fsckObjects=true fetch --no-tags --prune \
        "$tmp/agent.bundle" "+refs/heads/*:refs/remotes/agent-$name/*"
      ${pkgs.git}/bin/git branch -r --list "agent-$name/*"
      echo "review: git log -p HEAD..agent-$name/<branch>   (read it before building or running it)"
    '')
  ];

  # Firewall. Everything the agent user sends passes agent-out (OUTPUT,
  # owner match: before routing into sing-box's TUN, on the original
  # destination). Talking to the laptop itself is the subtle part: the
  # daemon reaches its own tool servers and callbacks over 127.0.0.1 on
  # random ports, so loopback cannot simply be closed. Instead TCP to any
  # local address is allowed but conn-marked, and agent-reply drops the
  # answer to a marked connection unless an agent socket sends it: the
  # agent completes handshakes only with its own listeners. A connect to
  # another user's port (sshd, a dev server, the infinity WebSocket of some
  # other daemon) hangs until it times out. UDP and the rest to local
  # addresses is dropped outright. llama-server is the one exception.
  mark = "0x1000000"; # bit 24: clear of tailscale (0xff0000), podman, sing-box marks
  ipt = "iptables -w";
  ip6t = "ip6tables -w";
  fakeipRange = (import ../../users/gurinderu/fakeip-range.nix).range;
  localTcp = [
    "-p tcp -m addrtype --dst-type LOCAL -j CONNMARK --set-xmark ${mark}/${mark}"
    "-p tcp -m addrtype --dst-type LOCAL -j RETURN"
    "-m addrtype --dst-type LOCAL -j DROP"
  ];
  agentOut4 = [
    # The agent answering a connection someone else opened.
    "-m conntrack --ctdir REPLY -j RETURN"
    "-d 127.0.0.1 -p tcp --dport ${toString llamaPort} -j RETURN"
    # Tailscale's MagicDNS resolver (resolv.conf points at it), DNS only.
    "-d 100.100.100.100 -p udp --dport 53 -j RETURN"
    "-d 100.100.100.100 -p tcp --dport 53 -j RETURN"
    # Tailnet (NetBird's peer range is inside it too).
    "-d 100.64.0.0/10 -j DROP"
    # Host podman networks and the runner VMs' 10.89.255.0/24
    # (configuration.nix, github-runner.nix); libvirt's default NAT network.
    "-d 10.88.0.0/15 -j DROP"
    "-d 192.168.122.0/24 -j DROP"
  ]
  ++ localTcp
  ++ lib.optionals (!cfg.allowLan) [
    # Every proxied hostname resolves into the fakeip pool (172.24.0.0/14).
    "-d ${fakeipRange} -j RETURN"
    # DNS to the LAN resolver; sing-box hijacks it anyway.
    "-p udp --dport 53 -j RETURN"
    "-p tcp --dport 53 -j RETURN"
    "-d 0.0.0.0/8 -j DROP"
    "-d 10.0.0.0/8 -j DROP"
    "-d 169.254.0.0/16 -j DROP"
    "-d 172.16.0.0/12 -j DROP"
    "-d 192.168.0.0/16 -j DROP"
    "-d 224.0.0.0/3 -j DROP"
  ];
  agentOut6 = [
    "-m conntrack --ctdir REPLY -j RETURN"
    "-d fd7a:115c:a1e0::/48 -j DROP"
  ]
  ++ localTcp
  ++ lib.optionals (!cfg.allowLan) [
    "-p udp --dport 53 -j RETURN"
    "-p tcp --dport 53 -j RETURN"
    "-d fc00::/7 -j DROP"
    "-d fe80::/10 -j DROP"
    "-d ff00::/8 -j DROP"
  ];
  agentReply = [
    "-m owner --uid-owner ${user} -j RETURN"
    # The kernel's RST for a closed port: refuse fast instead of hanging.
    "-p tcp --tcp-flags RST RST -j RETURN"
    "-j DROP"
  ];
  jumps = [
    "-m owner --uid-owner ${user} -j agent-out"
    "-m connmark --mark ${mark}/${mark} -m conntrack --ctdir REPLY -j agent-reply"
  ];
  # While the firewall is down (see github-runner.nix on fail-closed), the
  # agent user sends nothing at all; infinity-daemon stops with the firewall
  # anyway (requires=), this covers stray processes.
  stopGuard = "-m owner --uid-owner ${user} -m comment --comment agent-stopped -j DROP";
  chainsFor =
    cmd: out:
    ''
      ${cmd} -N agent-out 2>/dev/null || ${cmd} -F agent-out
      ${cmd} -N agent-reply 2>/dev/null || ${cmd} -F agent-reply
    ''
    + lib.concatMapStrings (r: "${cmd} -A agent-out ${r}\n") out
    + lib.concatMapStrings (r: "${cmd} -A agent-reply ${r}\n") agentReply
    + lib.concatMapStrings (j: "${cmd} -C OUTPUT ${j} 2>/dev/null || ${cmd} -I OUTPUT 1 ${j}\n") jumps
    + "while ${cmd} -D OUTPUT ${stopGuard} 2>/dev/null; do :; done\n";
  teardownFor =
    cmd:
    ''
      ${cmd} -C OUTPUT ${stopGuard} 2>/dev/null || ${cmd} -I OUTPUT 1 ${stopGuard}
    ''
    + lib.concatMapStrings (j: "${cmd} -D OUTPUT ${j} 2>/dev/null || true\n") jumps
    + ''
      ${cmd} -F agent-out 2>/dev/null || true
      ${cmd} -X agent-out 2>/dev/null || true
      ${cmd} -F agent-reply 2>/dev/null || true
      ${cmd} -X agent-reply 2>/dev/null || true
    '';
in
{
  options.thinkpad.localAgents.allowLan = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Let the agent user reach the LAN (RFC 1918, link-local, ULA, multicast).
      Off, it gets the internet (through sing-box) and DNS only. The tailnet,
      the runner VMs, host podman/libvirt networks and the laptop's own ports
      stay closed either way.
    '';
  };

  config = {
    services.llama-cpp = {
      enable = true;
      # Vulkan reaches the Arc iGPU through Mesa's ANV driver, provided by
      # hardware.graphics (configuration.nix). The module already sets
      # PrivateDevices = false for GPU access, and /dev/dri/renderD128 is
      # world-accessible, so the DynamicUser needs no extra group.
      package = pkgs.llama-cpp.override { vulkanSupport = true; };
      host = "127.0.0.1";
      port = llamaPort;
      inherit model;
      extraFlags = [
        "--alias"
        "local"
        # The GGUF's Qwen3.6 chat template, which carries tool calling (its
        # <function=...> XML calls are parsed back into OpenAI tool_calls).
        "--jinja"
        "--ctx-size"
        (toString (slots * contextSize))
        "--n-gpu-layers"
        "99"
        # Concurrent agents share one KV pool, so a busy slot can use idle
        # slots' space instead of each getting a fixed half.
        "--parallel"
        (toString slots)
        "--kv-unified"
        # q8_0 KV needs flash attention; it halves the already small cache
        # (f16 would be ~1.3 GB at 64k), which counts on a 31 GB machine that
        # also holds ~17 GB of weights and the runner VMs.
        "--flash-attn"
        "on"
        "--cache-type-k"
        "q8_0"
        "--cache-type-v"
        "q8_0"
        # Qwen's recommended sampling for thinking mode on precise coding
        # tasks (the Qwen3.6-35B-A3B model card); requests that set their own
        # values override these.
        "--temp"
        "0.6"
        "--top-p"
        "0.95"
        "--top-k"
        "20"
        "--min-p"
        "0"
        # The P-cores; with every layer offloaded the CPU mostly waits anyway.
        "--threads"
        "6"
      ];
    };

    users.users.${user} = {
      isSystemUser = true;
      group = user;
      home = agentHome;
      createHome = true;
      homeMode = "700";
    };
    users.groups.${user} = { };

    # The CLI finds the daemon at $HOME/.infinity/daemon.sock (no option), so
    # the TUI runs as the agent user too, via sudo. use_pty (sudo's default
    # since 1.9.14, pinned here) gives it a fresh pty: the agent's processes
    # never hold 0xff's terminal, so TIOCSTI cannot type into 0xff's shell.
    security.sudo.extraRules = [
      {
        users = [ "0xff" ];
        runAs = user;
        commands =
          map
            (c: {
              command = "${c}";
              options = [ "NOPASSWD" ];
            })
            [
              tuiAsAgent
              importAsAgent
              exportAsAgent
            ];
      }
    ];
    security.sudo.extraConfig = ''
      Defaults>${user} use_pty
    '';
    # And no TIOCSTI on any tty that is not the caller's controlling one.
    boot.kernel.sysctl."dev.tty.legacy_tiocsti" = 0;

    systemd.tmpfiles.settings."10-agent" = {
      ${work}.d = {
        inherit user;
        group = user;
        mode = "0700";
      };
      "${agentHome}/.infinity".d = {
        inherit user;
        group = user;
        mode = "0700";
      };
      "${agentHome}/.infinity/providers.json"."L+".argument = "${pkgs.writeText "providers.json" (
        builtins.toJSON providers
      )}";
      "${agentHome}/.infinity/rap.json"."L+".argument = "${pkgs.writeText "rap.json" (
        builtins.toJSON rap
      )}";
      "${agentHome}/.gitconfig"."L+".argument = "${gitconfig}";
    };

    systemd.services.infinity-daemon = {
      description = "Infinity coding-agent daemon (local Qwen3.6 model)";
      wantedBy = [ "multi-user.target" ];
      # The owner rules are its network policy: no firewall, no daemon.
      requires = [ "firewall.service" ];
      wants = [ "network-online.target" ];
      after = [
        "firewall.service"
        "network-online.target"
        "llama-cpp.service"
      ];
      path = agentPackages ++ [ "/run/current-system/sw" ];
      environment = {
        HOME = agentHome;
        SHELL = "${pkgs.bash}/bin/bash";
        INFINITY_WS_PORT = toString wsPort;
        INFINITY_WS_BIND = "127.0.0.1";
        RUST_LOG = "info";
      };
      serviceConfig = {
        ExecStart = "${infinity}/bin/infinity daemon";
        User = user;
        Group = user;
        # The CLI's own ./.infinity lands in the workspace it runs in.
        WorkingDirectory = agentHome;
        StateDirectory = "agent";
        StateDirectoryMode = "0700";
        UMask = "0077";
        Restart = "always";
        RestartSec = 5;

        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        # Other users' processes (and their command lines) are invisible.
        ProtectProc = "invisible";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        LockPersonality = true;
        RemoveIPC = true;
        SystemCallArchitectures = "native";
        # sandbox-local's bwrap is unprivileged (no setuid on NixOS): it
        # unshares a user and a mount namespace and nothing else, and
        # bind-mounts /proc rather than mounting a new one, so the Protect*
        # mounts above do not trip it. No SystemCallFilter: bwrap needs mount,
        # pivot_root and unshare, which @system-service leaves out.
        RestrictNamespaces = [
          "user"
          "mnt"
        ];
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
        ];
        # World-reachable control sockets and state. Most are root- or
        # group-only already; hidden regardless. "-": absent paths are fine.
        # The nix daemon is here because builds run as nixbld, outside the
        # agent user's firewall rules (fixed-output fetches reach the LAN).
        InaccessiblePaths = map (p: "-${p}") [
          "/run/tailscale"
          "/var/lib/tailscale"
          "/run/podman"
          "/run/docker.sock"
          "/run/libvirt"
          "/var/lib/libvirt"
          "/run/dbus/system_bus_socket"
          "/run/secrets"
          "/run/secrets.d"
          "/run/gh-runner-secrets"
          "/var/lib/microvms"
          "/var/lib/sing-box"
          "/etc/ssh"
          "/nix/var/nix/daemon-socket"
        ];
      };
    };

    networking.firewall.extraCommands = chainsFor ipt agentOut4 + chainsFor ip6t agentOut6;
    networking.firewall.extraStopCommands = teardownFor ipt + teardownFor ip6t;

    home-manager.users."0xff".home.packages = agentCommands;
  };
}
