{
  config,
  self,
  pkgs,
  lib,
  ...
}:
let
  fabroLib = import ./fabro-lib.nix { inherit self lib; };
in
{
  # Local LLM serving for Fabro. CPU inference (Intel Arc iGPU is unsupported by
  # ollama accel); MoE 3B-active keeps it fast despite the 35B weight footprint.
  #
  # daytime RAM note (interaction with github-runner.nix): the always-on
  # fabro.service UI can trigger a run that loads this ~21 GB model while the
  # 3 CI runners are busy → possible OOM (only the nightly path below stops
  # the runners first). ollama is capped at MemoryMax=26G; recommended
  # operational mitigation: don't trigger manual UI runs during heavy CI, or
  # reduce runner concurrency. A real fix (shrinking the resident set or
  # gating the UI) is a separate design decision.
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

  # Editable steering prompt; changing it needs no rebuild. task.md is
  # root-owned (0644 root root) so the fabro user can't rewrite the goal that
  # gets passed into the sandboxed agent; the directory stays fabro-writable
  # so fabro can still write logs.
  systemd.tmpfiles.rules = [
    "d /var/lib/night-llm 0750 fabro fabro -"
    "f /var/lib/night-llm/task.md 0644 root root - Review this repository for logic gaps, missed edge cases, and holes in reasoning. Do not modify code; produce a findings report grouped by severity with file:line references."
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
      gh
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
        OLLAMA_HOST=127.0.0.1:11434 ${pkgs.ollama}/bin/ollama pull '${fabroLib.modelTag}'
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
        # SECURITY: GH_TOKEN is intentionally NOT exported into this (or the
        # agent's) environment. It is supplied only per-invocation to the
        # individual git/gh commands below that need it.
        export HOME=/var/lib/fabro

        while read -r repo; do
          [ -z "$repo" ] && continue
          log="$outdir/$(printf '%s' "$repo" | tr / _).log"
          work="$(mktemp -d)"
          if ! GH_TOKEN="$token" GIT_TERMINAL_PROMPT=0 git -c credential.helper='!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f' \
                 clone --depth 1 "https://github.com/$repo.git" "$work/repo" </dev/null \
                 >>"$log" 2>&1; then
            echo "clone failed: $repo" >>"$outdir/errors.log"; rm -rf "$work"; continue
          fi
          # HOST-VERIFY: with a network-blocked docker sandbox the repo must be
          # provisioned WITHOUT network; confirm on the thinkpad how fabro
          # mounts the pre-cloned $work/repo into the docker sandbox (`fabro
          # sandbox cp` / bind mount). If provisioning can't be made to work,
          # fall back to provider = "local" here (documented tradeoff: local
          # cannot enforce a network block, but the GH token is already absent
          # from the agent env above, so the residual risk is repo-content
          # exfil only).
          cat >"$work/run.toml" <<EOF
        [workflow]
        graph = "$graph"

        [run.environment]
        provider = "docker"
        network.mode = "block"

        [run.clone]
        enabled = false
        EOF
          chown -R fabro:fabro "$work"
          (
            cd "$work/repo"
            runuser -u fabro -- env HOME=/var/lib/fabro \
              ${fabroLib.fabroExe} run "$work/run.toml" \
              --goal "$goal" --storage-dir "$storage" </dev/null \
              >>"$log" 2>&1
          ) || { echo "run failed: $repo" >>"$outdir/errors.log"; rm -rf "$work"; continue; }

          # Deliver only the report to the PR (host-controlled): agent
          # code-edits never reach it, only REVIEW-FINDINGS.md.
          ( cd "$work/repo"
            if [ -f REVIEW-FINDINGS.md ]; then
              git checkout -- . 2>/dev/null || true          # discard any agent edits to tracked files
              branch="night-review-$(date +%Y%m%d)"
              git checkout -b "$branch"
              git add REVIEW-FINDINGS.md                       # ONLY the report, nothing else
              git -c user.name='night-llm' -c user.email='night-llm@localhost' commit -m 'nightly review findings' </dev/null
              GH_TOKEN="$token" GIT_TERMINAL_PROMPT=0 git -c credential.helper='!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f' push -u origin "$branch" </dev/null
              GH_TOKEN="$token" ${pkgs.gh}/bin/gh pr create --repo "$repo" --head "$branch" --title "nightly review: logic gaps" --body-file REVIEW-FINDINGS.md </dev/null
            fi ) >>"$log" 2>&1 || echo "deliver failed: $repo" >>"$outdir/errors.log"
          rm -rf "$work"
        done < ${config.sops.secrets.night_llm_repos.path}
      '';
      ExecStopPost = pkgs.writeShellScript "night-llm-post" ''
        OLLAMA_HOST=127.0.0.1:11434 ${pkgs.ollama}/bin/ollama stop '${fabroLib.modelTag}' || true
        systemctl start github-runner-warp-1 github-runner-warp-2 github-runner-warp-3 || true
      '';
      Nice = 10;
      TimeoutStartSec = "4h";
    };
  };
}
