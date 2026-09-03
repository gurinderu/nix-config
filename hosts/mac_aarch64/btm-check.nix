# Warn, loudly, when macOS Background Task Management (BTM) has disallowed a
# nix-darwin-managed launchd job.
#
# BTM is the macOS 13+ subsystem behind System Settings -> General -> Login
# Items & Extensions. Every LaunchDaemon/LaunchAgent gets a per-item toggle
# there ("Allow in the Background"), and macOS can flip a *new* job's toggle
# off on its own — no user action, no prompt, no log line anywhere nix-darwin
# looks. When that happens, `launchctl bootstrap`/`load -w` against that job
# — exactly what darwin-rebuild's activation does, both for system daemons
# (hardcoded in modules/system/launchd.nix) and for the missing-from-gui/<uid>
# repair in user-agents.nix — returns "5: Input/output error" and loads
# nothing. Activation does not treat that as failure (it can't tell a BTM
# refusal from any other launchctl hiccup), so `darwin-rebuild switch`
# reports success while the job silently never starts, on this switch or on
# any reboot afterward.
#
# This is exactly what happened here on 2026-09-03: org.nixos.sing-box,
# sing-box-reload, net-observer, sing-box-logrotate and activate-system (all
# system LaunchDaemons), plus the user agents org.nixos.ice and
# org.nix-community.home.sops-nix, were marked disallowed by BTM. It took
# ~8 hours of manual diagnosis (nothing in `darwin-rebuild switch` output,
# nothing in the launchd job's own logs, because the job was never loaded at
# all) to find `sfltool dumpbtm` and see `Disposition: [..., disallowed, ...]`
# sitting there the whole time.
#
# Nothing here can be fixed from the Nix side: BTM's allow-list has no
# supported CLI or file for *setting* an item (only Settings.app, or an MDM
# ManagedLoginItems profile neither of which this flake can express or wants
# to require). `sfltool resetbtm` exists, but it does not target one job —
# it wipes BTM's disallow/allow state for every app and daemon on the
# machine and needs a reboot to re-evaluate everything from scratch, which is
# a much bigger and more disruptive hammer than "warn the human" for what is,
# from nix-darwin's point of view, an environmental fact it doesn't control.
# So this module only detects and reports: it reads `sfltool dumpbtm` (which
# needs the root activation already runs as) for every nix-darwin-owned
# label ("org.nixos.*", "org.nix-community.*") that BTM disallowed, and
# prints a warning at the end of postActivation that a human can act on
# before they find out the hard way, again, at the next reboot.
#
# Parsing note: `sfltool dumpbtm`'s per-record fields are not in a fixed
# order (observed: Disposition before Identifier, but nothing guarantees
# that stays true), and records are separated by a blank line. The awk below
# buffers a whole record (paragraph mode, RS="") before deciding anything,
# so field order within a record does not matter.
{ lib, ... }:
{
  system.activationScripts.postActivation.text = lib.mkAfter ''
    echo "checking Background Task Management (BTM) for disallowed nix-darwin jobs..." >&2
    btm_labels=""
    if ! btm_labels=$(
      set -e
      dump="$(sfltool dumpbtm 2>/dev/null)"
      [ -n "$dump" ] || exit 1
      printf '%s\n' "$dump" | awk '
        BEGIN { RS = ""; FS = "\n" }
        {
          id = ""; disp = ""
          for (i = 1; i <= NF; i++) {
            line = $i
            if (match(line, /Identifier:[ \t]*/)) {
              id = substr(line, RSTART + RLENGTH)
              gsub(/^[ \t]+|[ \t]+$/, "", id)
            } else if (line ~ /Disposition:/) {
              disp = line
            }
          }
          if (id != "" && disp != "" &&
              (id ~ /org\.nixos\./ || id ~ /org\.nix-community\./) &&
              disp ~ /disallowed/) {
            sub(/^[0-9]+\./, "", id)
            print id
          }
        }
      '
    ); then
      echo "warning: btm check skipped: sfltool dumpbtm unavailable or unparsable" >&2
      btm_labels=""
    fi

    if [ -n "$btm_labels" ]; then
      echo "" >&2
      printf '\033[1;31mwarning:\033[0m macOS Background Task Management has DISALLOWED nix-darwin launchd job(s):\n' >&2
      while IFS= read -r label; do
        [ -n "$label" ] || continue
        state="(not loaded)"
        if launchctl print "system/''${label}" >/dev/null 2>&1; then
          state="(running now, will NOT survive reboot)"
        fi
        echo "  - ''${label} ''${state}" >&2
      done <<< "$btm_labels"
      echo "" >&2
      echo "These jobs will not load via launchctl until BTM allows them again -- this activation succeeding does not mean they are running, and even a currently-running one above will not come back after a reboot." >&2
      echo "Fix: System Settings -> General -> Login Items & Extensions -> Allow in the Background -> enable the listed item(s)/\"Unknown Developer\"," >&2
      echo "     or: sudo sfltool resetbtm && reboot (this resets BTM state for EVERY app on the machine, not just these jobs -- last resort)." >&2
      echo "" >&2
    fi
  '';
}
