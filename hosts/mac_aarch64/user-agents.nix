# Make sure every declared user LaunchAgent is actually loaded, on every switch.
#
# nix-darwin treats the two launchd domains differently. System daemons in
# /Library/LaunchDaemons are re-loaded unconditionally on each activation
# (`launchctl unload || true; launchctl load -w`). User agents from
# `launchd.user.agents.*` are not: the generated activate script only touches
# ~/Library/LaunchAgents/<label>.plist when the copy on disk DIFFERS from the
# store version (`if ! diff <store> <disk>; then cp; launchctl load -w; fi`,
# see modules/system/launchd.nix, userLaunchdActivation). "Plist unchanged" is
# taken as "job loaded", and those are not the same thing: the plist is a file
# on the data volume, the job is an entry in the live gui/<uid> domain, and the
# latter can vanish while the former stays put — a nix reinstall, a manual
# `launchctl bootout`, a macOS update that resets login items, a gui session
# that came up before the plist existed. From then on every rebuild sees an
# identical plist, skips the block, and the job never comes back. That is how
# org.nixos.ice (the Ice menu-bar manager, declared in default.nix) silently
# stopped starting at login here, and no amount of `darwin-rebuild switch`
# fixed it.
#
# This hook closes the gap by checking the DOMAIN, not the file. For each
# declared agent: `launchctl print gui/<uid>/<label>` (exit 0 = job is known to
# launchd); if it is missing, `launchctl bootstrap gui/<uid> <plist>`. Already-
# loaded jobs are left untouched, so a routine rebuild does not restart Ice —
# the reload-on-change path stays nix-darwin's own. It runs in postActivation,
# after userLaunchd has placed the plists, and it runs as root like the rest of
# activate, so it enters the user's session the same way nix-darwin does:
# `launchctl asuser <uid> sudo --user=<user> -- launchctl ...`.
#
# A failed bootstrap must not abort activation (activate runs under `set -e`):
# over SSH with nobody logged in there is no gui/<uid> domain at all, and a job
# the user has explicitly `launchctl disable`d is refused too. Both are
# reported and skipped; the job will be picked up on the next switch that
# runs inside a real session.
{ config, lib, ... }:
let
  user = config.system.primaryUser;
  # Same rule nix-darwin applies: an explicit serviceConfig.Label wins, else
  # "${launchd.labelPrefix}.<name>" (modules/launchd/default.nix). Read the
  # resolved Label rather than recomputing it so the two can never drift.
  labels = lib.mapAttrsToList (_: agent: agent.serviceConfig.Label) config.launchd.user.agents;
  bootstrapOne = label: ''
    if ! launchctl asuser "$uid" sudo --user=${lib.escapeShellArg user} -- \
        launchctl print "gui/$uid/${label}" >/dev/null 2>&1; then
      echo "bootstrapping user service ${label} (plist present, job missing from gui/$uid)" >&2
      launchctl asuser "$uid" sudo --user=${lib.escapeShellArg user} -- \
        launchctl bootstrap "gui/$uid" ~${user}/Library/LaunchAgents/${label}.plist \
        || echo "warning: could not bootstrap ${label} into gui/$uid (no gui session, or job disabled)" >&2
    fi
  '';
in
{
  system.activationScripts.postActivation.text = lib.mkIf (labels != [ ]) (lib.mkAfter ''
    echo "ensuring user launchd agents are loaded..." >&2
    uid=$(id -u -- ${lib.escapeShellArg user})
    ${lib.concatMapStrings bootstrapOne labels}
  '');
}
