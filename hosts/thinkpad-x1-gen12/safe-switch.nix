# safe-switch: a `nixos-rebuild switch` that survives the ssh session dying
# under it, and undoes itself unless confirmed. Over ssh into this laptop the
# path is tailscale riding sing-box's TUN, and a switch that touches either
# can drop the session halfway.
#
#   safe-switch [flake-ref]   build, arm the rollback, activate (detached)
#   safe-switch --confirm     keep the new generation (stops the rollback)
#   safe-switch --status      timer, activation unit, last results, journals
#
# flake-ref defaults to .#thinkpad-x1-gen12; without a #name the name is
# thinkpad-x1-gen12 too.
#
# Why not plain `nixos-rebuild switch`: nixos-rebuild-ng (26.05) already runs
# switch-to-configuration in a transient unit, but with `systemd-run --pipe`,
# so the unit's stdout/stderr are pipes back to nixos-rebuild in the ssh
# session. When that session dies the unit keeps running, but its next
# eprintln! hits EPIPE and switch-to-configuration-ng (Rust) panics on it:
# a half-done switch. Here the unit logs to the journal and nothing in it
# depends on the caller.
#
# Flow:
#   1. `nix build` of the toplevel as the invoking user (no root, no ./result).
#   2. Record /run/current-system (what is running now) as the rollback target.
#   3. Arm safe-switch-rollback.timer (root, transient, fires in 5 minutes):
#      its service sets the system profile back to that path and runs its
#      switch-to-configuration switch.
#   4. Start safe-switch-activate.service (root, transient, --collect):
#      `nix-env -p /nix/var/nix/profiles/system --set <new>` (what
#      nixos-rebuild does), then `<new>/bin/switch-to-configuration switch`.
#   5. Follow its journal until it ends. The ssh session may die at any point
#      from here; log back in and run `safe-switch --status`, then
#      `safe-switch --confirm` within the 5 minutes.
#
# Rollback robustness: both units are transient system units owned by PID 1,
# so neither depends on a login session; transient units survive the
# daemon-reload / daemon-reexec of switch-to-configuration. The rollback first
# waits for a still-running activation, then only acts on what differs (the
# profile, the running system), so running it twice is a no-op. A failed
# activation is rolled back too unless confirmed. State lives in
# /run/safe-switch (root-only writes, world-readable), gone on reboot, as the
# timer is: after a reboot nothing is pending, and the boot menu entry is the
# profile's current generation.
{
  config,
  pkgs,
  ...
}:
let
  profile = "/nix/var/nix/profiles/system";
  stateDir = "/run/safe-switch";
  nixEnv = "${config.nix.package}/bin/nix-env";

  # Root, inside safe-switch-activate.service. $1: the new toplevel.
  activate = pkgs.writeShellApplication {
    name = "safe-switch-activate";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      new=$1
      rc=0
      echo "safe-switch: activating $new"
      echo "running" > ${stateDir}/activate.result
      if ! ${nixEnv} -p ${profile} --set "$new"; then
        echo "safe-switch: could not set ${profile} to $new" >&2
        echo "failed: nix-env --set" > ${stateDir}/activate.result
        exit 1
      fi
      "$new/bin/switch-to-configuration" switch || rc=$?
      if [ "$rc" -eq 0 ]; then
        echo "ok" > ${stateDir}/activate.result
      else
        echo "failed: switch-to-configuration exit $rc" > ${stateDir}/activate.result
      fi
      exit "$rc"
    '';
  };

  # Root, inside safe-switch-rollback.service (started by its timer). $1: the
  # system that ran before the switch. Idempotent: does only what differs.
  rollback = pkgs.writeShellApplication {
    name = "safe-switch-rollback";
    runtimeInputs = [
      pkgs.coreutils
      config.systemd.package
    ];
    text = ''
      prev=$1
      if [ ! -x "$prev/bin/switch-to-configuration" ]; then
        echo "safe-switch: $prev is not a NixOS system; not rolling back" >&2
        echo "failed: no switch-to-configuration in $prev" > ${stateDir}/rollback.result
        exit 1
      fi
      # An activation still in progress finishes first: two
      # switch-to-configuration runs must not overlap.
      i=0
      while systemctl is-active --quiet safe-switch-activate.service; do
        if [ "$i" -eq 0 ]; then
          echo "safe-switch: waiting for safe-switch-activate to finish"
        fi
        i=$((i + 1))
        if [ "$i" -ge 1800 ]; then
          echo "safe-switch: activation still running after 30 min; rolling back anyway" >&2
          systemctl stop safe-switch-activate.service || :
          break
        fi
        sleep 1
      done
      echo "running" > ${stateDir}/rollback.result
      if [ "$(readlink -f ${profile})" != "$prev" ]; then
        echo "safe-switch: setting ${profile} back to $prev"
        ${nixEnv} -p ${profile} --set "$prev"
      fi
      if [ "$(readlink -f /run/current-system)" != "$prev" ]; then
        echo "safe-switch: switching back to $prev"
        rc=0
        "$prev/bin/switch-to-configuration" switch || rc=$?
        echo "done: switch-to-configuration exit $rc" > ${stateDir}/rollback.result
        exit "$rc"
      fi
      echo "safe-switch: $prev is already running; nothing to roll back"
      echo "done: nothing to do" > ${stateDir}/rollback.result
    '';
  };

  safe-switch = pkgs.writeShellApplication {
    name = "safe-switch";
    runtimeInputs = [
      pkgs.coreutils
      config.nix.package
      config.systemd.package
    ];
    # Everything run through sudo by absolute path: no reliance on what PATH
    # sudo hands its child.
    text = ''
      delay=300
      state=${stateDir}
      sudo=/run/wrappers/bin/sudo
      systemctl=${config.systemd.package}/bin/systemctl
      systemd_run=${config.systemd.package}/bin/systemd-run
      coreutils=${pkgs.coreutils}/bin

      usage() {
        cat <<EOF
      usage: safe-switch [flake-ref]   build and switch, rolled back in $((delay / 60)) min unless confirmed
             safe-switch --confirm     keep the new generation
             safe-switch --status      show the rollback timer and the activation
      flake-ref defaults to .#thinkpad-x1-gen12
      EOF
      }

      timer_active() {
        systemctl is-active --quiet safe-switch-rollback.timer
      }

      status() {
        echo "== safe-switch-rollback.timer"
        systemctl list-timers --all --no-pager safe-switch-rollback.timer || :
        systemctl status --no-pager --lines=0 safe-switch-rollback.timer 2>/dev/null || :
        echo "== safe-switch-activate.service"
        systemctl status --no-pager --lines=0 safe-switch-activate.service 2>/dev/null \
          || echo "(not loaded: finished and collected, or never started)"
        for f in prev new armed deadline activate.result rollback.result; do
          if [ -r "$state/$f" ]; then
            printf '%-16s %s\n' "$f:" "$(cat "$state/$f")"
          fi
        done
        printf '%-16s %s\n' "running:" "$(readlink -f /run/current-system)"
        printf '%-16s %s\n' "profile:" "$(readlink -f /nix/var/nix/profiles/system)"
        echo "== journal: safe-switch-activate (last 20)"
        journalctl --no-pager -n 20 -u safe-switch-activate.service || :
        echo "== journal: safe-switch-rollback (last 10)"
        journalctl --no-pager -n 10 -u safe-switch-rollback.service || :
      }

      confirm() {
        if systemctl is-active --quiet safe-switch-rollback.service; then
          echo "safe-switch: too late, the rollback is running ('safe-switch --status')" >&2
          exit 1
        fi
        if ! timer_active; then
          echo "safe-switch: no rollback pending (already confirmed, already rolled back, or never armed)" >&2
          [ -r "$state/rollback.result" ] && echo "last rollback: $(cat "$state/rollback.result")" >&2
          exit 1
        fi
        if systemctl is-active --quiet safe-switch-activate.service; then
          echo "safe-switch: the activation is still running; confirm once it is done" >&2
          exit 1
        fi
        "$sudo" "$systemctl" stop safe-switch-rollback.timer
        echo "safe-switch: confirmed; rollback disarmed"
        [ -r "$state/activate.result" ] && echo "activation: $(cat "$state/activate.result")"
        echo "running: $(readlink -f /run/current-system)"
      }

      switch() {
        local ref=$1 flake name new prev deadline
        flake=''${ref%%#*}
        name=thinkpad-x1-gen12
        if [[ $ref == *#* && -n ''${ref#*#} ]]; then
          name=''${ref#*#}
        fi
        [ -n "$flake" ] || flake=.

        if timer_active || systemctl is-active --quiet safe-switch-rollback.service; then
          echo "safe-switch: a rollback is still pending from the last switch:" >&2
          echo "  run 'safe-switch --confirm' (or wait for it) first" >&2
          exit 1
        fi
        if systemctl is-active --quiet safe-switch-activate.service; then
          echo "safe-switch: safe-switch-activate is still running" >&2
          exit 1
        fi

        echo "safe-switch: building $flake#$name"
        new=$(nix build --no-link --print-out-paths \
          "$flake#nixosConfigurations.\"$name\".config.system.build.toplevel")
        prev=$(readlink -f /run/current-system)
        if [ "$new" = "$prev" ]; then
          echo "safe-switch: $new is already running; nothing to do"
          exit 0
        fi
        echo "safe-switch: running $prev"
        echo "safe-switch: new     $new"

        "$sudo" "$coreutils/install" -d -m 0755 "$state"
        printf '%s\n' "$prev" | "$sudo" "$coreutils/tee" "$state/prev" >/dev/null
        printf '%s\n' "$new" | "$sudo" "$coreutils/tee" "$state/new" >/dev/null
        deadline=$(date -d "+$delay sec" '+%F %T %Z')
        date '+%F %T %Z' | "$sudo" "$coreutils/tee" "$state/armed" >/dev/null
        printf '%s\n' "$deadline" | "$sudo" "$coreutils/tee" "$state/deadline" >/dev/null
        "$sudo" "$coreutils/rm" -f "$state/activate.result" "$state/rollback.result"

        # Rollback first: armed before anything changes. RemainAfterElapse=no
        # unloads the timer once it fires, so "timer active" means "rollback
        # still pending" and the next run can reuse the name.
        "$sudo" "$systemd_run" --quiet --collect \
          --unit=safe-switch-rollback \
          --description="safe-switch: roll back to $prev" \
          --on-active="$delay" \
          --timer-property=AccuracySec=1s \
          --timer-property=RemainAfterElapse=no \
          ${rollback}/bin/safe-switch-rollback "$prev"

        if ! "$sudo" "$systemd_run" --quiet --collect \
          --unit=safe-switch-activate \
          --description="safe-switch: activate $new" \
          --service-type=exec \
          ${activate}/bin/safe-switch-activate "$new"; then
          echo "safe-switch: could not start the activation; disarming the rollback (nothing changed)" >&2
          "$sudo" "$systemctl" stop safe-switch-rollback.timer || :
          exit 1
        fi

        cat <<EOF

      safe-switch: activating in safe-switch-activate.service (detached; this
      terminal only follows its journal, and may drop).

        >>> Run 'safe-switch --confirm' within $((delay / 60)) minutes (before $deadline),
        >>> or the system rolls back to the previous generation.

      Log back in if the session drops; 'safe-switch --status' shows the state.

      EOF
        journalctl --no-pager -f -n 0 -o cat -u safe-switch-activate.service &
        local follow=$!
        trap 'kill "$follow" 2>/dev/null || :' EXIT
        while systemctl is-active --quiet safe-switch-activate.service; do
          sleep 1
        done
        sleep 1
        kill "$follow" 2>/dev/null || :
        trap - EXIT
        echo
        echo "safe-switch: activation: $(cat "$state/activate.result" 2>/dev/null || echo unknown)"
        if timer_active; then
          echo "safe-switch: rollback armed for $deadline; if everything works, run: safe-switch --confirm"
        else
          echo "safe-switch: the rollback timer is gone already: 'safe-switch --status'" >&2
        fi
      }

      case ''${1:-} in
        -h | --help) usage ;;
        --confirm) confirm ;;
        --status) status ;;
        -*)
          usage >&2
          exit 2
          ;;
        *) switch "''${1:-.#thinkpad-x1-gen12}" ;;
      esac
    '';
  };
in
{
  environment.systemPackages = [ safe-switch ];
}
