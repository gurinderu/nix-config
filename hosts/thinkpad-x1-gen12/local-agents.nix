# Local coding agents: hydro-project's infinity (pkgs/infinity) for 0xff,
# backed by RedSage-Qwen3-8B (a Qwen3-8B cybersecurity fine-tune) served by
# llama.cpp on this machine — no cloud model involved.
#
#   llama-cpp.service (system)     llama-server, 127.0.0.1:18101, alias
#                                  "redsage", Vulkan on the Arc iGPU
#   infinity-daemon.service (user) `infinity daemon`: ~/.infinity/daemon.sock,
#                                  WebSocket on 127.0.0.1:18102
#     └─ spawns, per ~/.infinity/providers.json, the "redsage" provider
#        (infinity-provider-openai-compat → llama-server's /v1 Chat API)
#     └─ spawns, per ~/.infinity/rap.json, sandbox-local (file/git/shell
#        tools, writes confined with bubblewrap)
#
# Use: `infinity` (TUI) or `infinity -H "task"` from a project directory.
# The CLI talks to the running daemon over the socket (it would start one
# itself if none were running). sandbox-local's tools work only after the
# agent calls `clone_repo` on the project (it then edits a git worktree);
# an 8B model may need that spelled out in the task. Logs: ~/.infinity/daemon.log and
# ./.infinity/cli.log in the working directory; `journalctl -u llama-cpp`.
#
# The two JSON files are store symlinks, so `infinity rap install --user` /
# `infinity provider install` cannot edit them; add entries here instead.
# The rest of ~/.infinity (sessions, logs, socket) stays writable.
#
# The model comes from the store (fetchurl, ~5 GB, pinned to an HF commit).
# RedSage is released "for research and educational purposes only"
# (github.com/RISys-Lab/RedSage, Responsible Use); there is no separate
# license file. Keep it to that.
{ pkgs, ... }:
let
  llamaPort = 18101;
  wsPort = 18102;

  infinity = pkgs.callPackage ../../pkgs/infinity { };

  model = pkgs.fetchurl {
    url = "https://huggingface.co/mradermacher/RedSage-Qwen3-8B-DPO-GGUF/resolve/c1e754a8b6892c787b114d986799dd8099238e4c/RedSage-Qwen3-8B-DPO.Q4_K_M.gguf";
    # Equals the file's LFS sha256 on HF.
    hash = "sha256-KnxRifWCxD2M3//c6caKJhSkJHsELHgUteoNvZc83OQ=";
  };

  contextSize = 16384;

  # The provider is configured by env; `env` keeps it a plain argv in
  # providers.json, so a daemon the CLI starts by itself gets it too.
  providers = {
    redsage.command = [
      "${pkgs.coreutils}/bin/env"
      "OPENAI_COMPAT_BASE_URL=http://127.0.0.1:${toString llamaPort}/v1"
      "OPENAI_COMPAT_MODEL=redsage"
      "OPENAI_COMPAT_CONTEXT=${toString contextSize}"
      "OPENAI_COMPAT_DISPLAY=RedSage Qwen3-8B (local)"
      "${infinity}/bin/infinity-provider-openai-compat"
    ];
  };
  rap.tool_sets = [
    {
      type = "toolset_command";
      command = "${infinity}/bin/sandbox-local";
    }
  ];
in
{
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
      "redsage"
      # Qwen3's chat template, which carries tool calling.
      "--jinja"
      "--ctx-size"
      (toString contextSize)
      "--n-gpu-layers"
      "99"
      # One agent at a time; parallel slots would split the context.
      "--parallel"
      "1"
      # The P-cores; with every layer offloaded the CPU mostly waits anyway.
      "--threads"
      "6"
    ];
  };

  home-manager.users."0xff" = {
    home.packages = [ infinity ];

    home.file.".infinity/providers.json".text = builtins.toJSON providers;
    home.file.".infinity/rap.json".text = builtins.toJSON rap;

    systemd.user.services.infinity-daemon = {
      Unit.Description = "Infinity coding-agent daemon (local RedSage model)";
      Service = {
        ExecStart = "${infinity}/bin/infinity daemon";
        # The CLI creates ./.infinity in its working directory.
        WorkingDirectory = "%h";
        Environment = [
          "INFINITY_WS_PORT=${toString wsPort}"
          "INFINITY_WS_BIND=127.0.0.1"
          "RUST_LOG=info"
          # sandbox-local runs the agents' shell commands and git: give them
          # the user's tools, plus bwrap (also on sandbox-local's own wrapper).
          "PATH=${pkgs.git}/bin:${pkgs.bubblewrap}/bin:/etc/profiles/per-user/0xff/bin:/run/current-system/sw/bin"
        ];
        Restart = "on-failure";
        RestartSec = 5;
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
