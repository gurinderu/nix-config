# Make sure every declared launchd job — user agents AND system daemons — is
# actually loaded, on every switch.
#
# nix-darwin's activation is diff-guarded in BOTH launchd domains (see
# modules/system/launchd.nix: one launchdActivation function serves agents and
# daemons alike — `if ! diff <store> <disk>; then unload; cp; load -w; fi`).
# "Plist unchanged" is taken as "job loaded", and those are not the same
# thing: the plist is a file on disk, the job is an entry in the live launchd
# domain, and the latter can vanish while the former stays put — a nix
# reinstall, a manual `launchctl bootout` never followed by a bootstrap, a
# macOS update that resets login items, macOS BTM silently disallowing the
# job (2026-09-03: sing-box, sing-box-reload, net-observer, sing-box-logrotate
# and activate-system all at once, see ./btm-check.nix). From then on every
# rebuild sees an identical plist, skips the block, and the job never comes
# back. That is how org.nixos.ice silently stopped starting at login here,
# and how the whole VPN stack stayed down for half a day on 2026-09-03 —
# no amount of `darwin-rebuild switch` fixed either.
#
# This hook closes the gap by checking the DOMAIN, not the file. For each
# declared agent: `launchctl print gui/<uid>/<label>` (exit 0 = job is known
# to launchd); if it is missing, `launchctl bootstrap gui/<uid> <plist>`. For
# each declared daemon, the same against the system domain and
# /Library/LaunchDaemons (which activation has just synced by this point).
# Already-loaded jobs are left untouched, so a routine rebuild does not
# restart anything — the reload-on-change path stays nix-darwin's own. Agent
# checks enter the user's session the same way nix-darwin does:
# `launchctl asuser <uid> sudo --user=<user> -- launchctl ...`.
#
# This is the activation-time half of the job-gone repair; the runtime half
# (between switches) lives in net-observer.nix and covers only sing-box —
# and net-observer can itself be the missing job (it was BTM-disallowed on
# 2026-09-03), which is exactly why this hook must cover the full set: a
# switch is the one recovery action that does not depend on any org.nixos.*
# job being alive.
#
# A failed bootstrap must not abort activation (activate runs under `set -e`):
# over SSH with nobody logged in there is no gui/<uid> domain at all, a job
# the user has explicitly `launchctl disable`d is refused, and a
# BTM-disallowed one fails with error 5 (btm-check.nix, which runs later in
# postActivation, then names the BTM culprits loudly). All are reported and
# skipped.
{ config, lib, ... }:
let
  user = config.system.primaryUser;
  # Same rule nix-darwin applies: an explicit serviceConfig.Label wins, else
  # "${launchd.labelPrefix}.<name>" (modules/launchd/default.nix). Read the
  # resolved Label rather than recomputing it so the two can never drift.
  labels = lib.mapAttrsToList (_: agent: agent.serviceConfig.Label) config.launchd.user.agents;
  daemonLabels = lib.mapAttrsToList (_: d: d.serviceConfig.Label) config.launchd.daemons;
  bootstrapOne = label: ''
    if ! launchctl asuser "$uid" sudo --user=${lib.escapeShellArg user} -- \
        launchctl print "gui/$uid/${label}" >/dev/null 2>&1; then
      echo "bootstrapping user service ${label} (plist present, job missing from gui/$uid)" >&2
      launchctl asuser "$uid" sudo --user=${lib.escapeShellArg user} -- \
        launchctl bootstrap "gui/$uid" ~${user}/Library/LaunchAgents/${label}.plist \
        || echo "warning: could not bootstrap ${label} into gui/$uid (no gui session, or job disabled)" >&2
    fi
  '';
  bootstrapDaemon = label: ''
    if ! launchctl print "system/${label}" >/dev/null 2>&1; then
      echo "bootstrapping system daemon ${label} (plist present, job missing from the system domain)" >&2
      launchctl bootstrap system "/Library/LaunchDaemons/${label}.plist" \
        || echo "warning: could not bootstrap ${label} into the system domain (BTM disallowed? see the btm-check report below)" >&2
    fi
  '';
in
{
  system.activationScripts.postActivation.text = lib.mkIf (labels != [ ] || daemonLabels != [ ]) (
    lib.mkAfter ''
      echo "ensuring system launchd daemons are loaded..." >&2
      ${lib.concatMapStrings bootstrapDaemon daemonLabels}
      echo "ensuring user launchd agents are loaded..." >&2
      uid=$(id -u -- ${lib.escapeShellArg user})
      ${lib.concatMapStrings bootstrapOne labels}
    ''
  );
}
