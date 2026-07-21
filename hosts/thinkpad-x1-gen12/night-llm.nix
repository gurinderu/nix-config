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
    # Never let nixos-rebuild start or restart this oneshot during activation:
    # its ExecStart runs the full multi-hour review batch, so a switch would
    # block until it finishes (this hung a deploy once). It runs only via
    # night-llm.timer or an explicit `systemctl start`.
    restartIfChanged = false;
    stopIfChanged = false;
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
    ];
    serviceConfig = {
      Type = "oneshot";
      # HOME must be set at the service level (not just in ExecStart's inline
      # script) so ExecStartPre/ExecStopPost inherit it too — the `ollama` CLI
      # panics ("$HOME is not defined") at startup otherwise, which failed the
      # whole batch on the `ollama pull`/`ollama stop` steps.
      Environment = [ "HOME=/var/lib/fabro" ];
      # Free RAM: stop the runners and make sure the model is present.
      ExecStartPre = pkgs.writeShellScript "night-llm-pre" ''
        set -eu
        systemctl stop github-runner-warp-1 github-runner-warp-2 github-runner-warp-3 || true
        OLLAMA_HOST=127.0.0.1:11434 ${pkgs.ollama}/bin/ollama pull '${fabroLib.modelTag}'
      '';
      ExecStart = pkgs.writeShellScript "night-llm-run" ''
        set -u
        graph=${./night-code-review.fabro}
        server=http://127.0.0.1:3000
        outdir=/var/lib/night-llm
        token="$(cat ${config.sops.secrets.night_llm_github_token.path})"
        if [ -z "$token" ]; then
          echo "night-llm: github token is empty (${config.sops.secrets.night_llm_github_token.path})" >&2
          exit 1
        fi
        dev_token="$(cat ${config.sops.secrets.fabro_dev_token.path})"
        goal="$(cat "$outdir/task.md")"
        # SECURITY: GH_TOKEN is intentionally NOT exported into this (or the
        # agent's) environment. It is supplied only per-invocation to the
        # individual git/gh commands below that need it.
        # HOME comes from serviceConfig.Environment (shared with pre/post).

        # `fabro run` is a CLIENT that executes the workflow ON the local Fabro
        # server (which owns the run store + artifacts), so the CLI needs an auth
        # session — `run` has no --storage-dir. Log in once with the dev-token
        # (no browser); the session persists in HOME=/var/lib/fabro. Run as the
        # fabro user so it lands in the same HOME the per-repo runs use below.
        runuser -u fabro -- env HOME=/var/lib/fabro \
          ${fabroLib.fabroExe} auth login --server "$server" \
          --dev-token "$dev_token" --no-upgrade-check </dev/null || {
            echo "night-llm: fabro auth login failed" >&2; exit 1; }

        while read -r repo; do
          [ -z "$repo" ] && continue
          log="$outdir/$(printf '%s' "$repo" | tr / _).log"
          work="$(mktemp -d)"
          if ! GH_TOKEN="$token" GIT_TERMINAL_PROMPT=0 git -c credential.helper='!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f' \
                 clone --depth 1 "https://github.com/$repo.git" "$work/repo" </dev/null \
                 >>"$log" 2>&1; then
            echo "clone failed: $repo" >>"$outdir/errors.log"; rm -rf "$work"; continue
          fi
          # NOTE: run.environment has NO provider field (valid keys: id, image,
          # resources, network, lifecycle, labels, volumes, env) — the sandbox
          # backend is selected server-side via [server.sandbox.providers.docker]
          # in fabro's settings.toml, not here. network.mode = block requests a
          # network-blocked sandbox. HOST-VERIFY still open: on the first real run
          # check the Fabro UI (it shows the sandbox type per run) for docker vs
          # local; if local, that is the documented fallback (cannot enforce the
          # network block, but the GH token is absent from the agent env above, so
          # residual risk is repo-content exfil only). No backticks in this
          # heredoc: it is unquoted (<<EOF), so backticks would run as commands.
          cat >"$work/run.toml" <<EOF
        [workflow]
        graph = "$graph"

        [run.environment]
        network.mode = "block"

        [run.clone]
        enabled = false

        # No push: the server now has a GITHUB_TOKEN (fabro.nix) that the worker
        # requires to start, so fabro would otherwise push run/meta branches to
        # the reviewed repo's origin. This review is read-only (report collected
        # as an artifact), so disable both branch pushes.
        [run.run_branch]
        enabled = false

        [run.meta_branch]
        enabled = false

        [run.artifacts]
        include = ["REVIEW-FINDINGS.md"]
        EOF
          chown -R fabro:fabro "$work"
          (
            cd "$work/repo"
            runuser -u fabro -- env HOME=/var/lib/fabro \
              ${fabroLib.fabroExe} run "$work/run.toml" \
              --goal "$goal" --server "$server" --no-upgrade-check </dev/null \
              >>"$log" 2>&1
          ) || { echo "run failed: $repo" >>"$outdir/errors.log"; rm -rf "$work"; continue; }

          # The report (REVIEW-FINDINGS.md) is collected by Fabro as a run
          # artifact (see [run.artifacts] above) and is viewable/downloadable in
          # the Fabro web UI over Tailscale. No GitHub push/PR, no /tmp copy —
          # the token above is used only to clone (read-only).
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
