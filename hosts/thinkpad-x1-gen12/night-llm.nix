{
  config,
  self,
  pkgs,
  ...
}:
{
  # Local LLM serving for Fabro. CPU inference (Intel Arc iGPU is unsupported by
  # ollama accel); MoE 3B-active keeps it fast despite the 35B weight footprint.
  services.ollama = {
    enable = true;
    host = "127.0.0.1";
    port = 11434;
    environmentVariables = {
      OLLAMA_KEEP_ALIVE = "10m"; # unload the model 10 min after last use → frees ~21 GB
      OLLAMA_MAX_LOADED_MODELS = "1";
    };
  };

  # OOM guard: the ~21 GB model actually lives in ollama's cgroup, not night-llm's.
  systemd.services.ollama.serviceConfig.MemoryMax = "26G";

  # Editable steering prompt; changing it needs no rebuild.
  systemd.tmpfiles.rules = [
    "d /var/lib/night-llm 0750 fabro fabro -"
    "f /var/lib/night-llm/task.md 0640 fabro fabro - Review this repository for logic gaps, missed edge cases, and holes in reasoning. Do not modify code; produce a findings report grouped by severity with file:line references."
  ];

  systemd.timers.night-llm = {
    description = "Nightly local-model code review";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 02:00:00";
      Persistent = true;
    };
  };

  systemd.services.night-llm = {
    description = "Nightly Fabro code-review batch on the local model";
    after = [
      "fabro.service"
      "ollama.service"
    ];
    wants = [
      "fabro.service"
      "ollama.service"
    ];
    path = with pkgs; [
      coreutils
      git
      util-linux
      systemd
      bash
      gnugrep
      findutils
    ];
    serviceConfig = {
      Type = "oneshot";
      # Free RAM: stop the runners and make sure the model is present.
      ExecStartPre = pkgs.writeShellScript "night-llm-pre" ''
        set -eu
        systemctl stop github-runner-warp-1 github-runner-warp-2 github-runner-warp-3 || true
        OLLAMA_HOST=127.0.0.1:11434 ${pkgs.ollama}/bin/ollama pull 'hf.co/HauhauCS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive:Q4_K_M'
      '';
      ExecStart = pkgs.writeShellScript "night-llm-run" ''
        set -u
        graph=${./night-code-review.fabro}
        storage=/var/lib/fabro/storage
        outdir=/var/lib/night-llm
        token="$(cat ${config.sops.secrets.night_llm_github_token.path})"
        if [ -z "$token" ]; then
          echo "night-llm: github token is empty (${config.sops.secrets.night_llm_github_token.path})" >&2
          exit 1
        fi
        goal="$(cat "$outdir/task.md")"
        export HOME=/var/lib/fabro GH_TOKEN="$token"

        # Configure Fabro's GitHub token once (for PR creation / private clones).
        runuser -u fabro -- env HOME=/var/lib/fabro \
          ${self.packages.x86_64-linux.fabro}/bin/fabro install github \
          --strategy token --non-interactive --storage-dir "$storage" <<<"$token" \
          >>"$outdir/setup.log" 2>&1 || true

        while read -r repo; do
          [ -z "$repo" ] && continue
          work="$(mktemp -d)"
          if ! GIT_TERMINAL_PROMPT=0 git -c credential.helper='!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f' \
                 clone --depth 1 "https://github.com/$repo.git" "$work/repo" </dev/null \
                 >>"$outdir/$(echo "$repo" | tr / _).log" 2>&1; then
            echo "clone failed: $repo" >>"$outdir/errors.log"; rm -rf "$work"; continue
          fi
          cat >"$work/run.toml" <<EOF
        [workflow]
        graph = "$graph"

        [run]
        goal = """$goal"""
        EOF
          chown -R fabro:fabro "$work"
          (
            cd "$work/repo"
            runuser -u fabro -- env HOME=/var/lib/fabro \
              ${self.packages.x86_64-linux.fabro}/bin/fabro run "$work/run.toml" \
              --auto-approve --storage-dir "$storage" </dev/null \
              >>"$outdir/$(echo "$repo" | tr / _).log" 2>&1 \
              && runuser -u fabro -- env HOME=/var/lib/fabro \
                   ${self.packages.x86_64-linux.fabro}/bin/fabro pr create \
                   --storage-dir "$storage" </dev/null \
                   >>"$outdir/$(echo "$repo" | tr / _).log" 2>&1
          ) || echo "run failed: $repo" >>"$outdir/errors.log"
          rm -rf "$work"
        done < ${config.sops.secrets.night_llm_repos.path}
      '';
      ExecStopPost = pkgs.writeShellScript "night-llm-post" ''
        OLLAMA_HOST=127.0.0.1:11434 ${pkgs.ollama}/bin/ollama stop 'hf.co/HauhauCS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive:Q4_K_M' || true
        systemctl start github-runner-warp-1 github-runner-warp-2 github-runner-warp-3 || true
      '';
      Nice = 10;
      TimeoutStartSec = "4h";
    };
  };
}
