# macOS launchd daemon for sing-box. The Linux counterpart is the systemd unit
# in hosts/thinkpad-x1-gen12/sing-box.nix; this is the nix-darwin equivalent.
#
# Why a *daemon* (system, root) and not a per-user launchd *agent* like
# users/gurinderu/meridian.nix: the TUN inbound needs root to create the utun
# interface and install routes via auto_route. Agents run as the logged-in user
# and cannot do that.
#
# The config is NOT rendered here. home-manager (users/gurinderu/sing-box.nix)
# already substitutes the sops secrets into the user's
# ~/.config/sing-box/config.json at activation time; this daemon just points at
# that file. root reads it regardless of the user-dir permissions, and WatchPaths
# reloads sing-box whenever home-manager rewrites it.
{ pkgs, config, ... }:
let
  configPath = "${config.users.users.gurinderu.home}/.config/sing-box/config.json";

  # State dir for the fakeip cache db (see cacheFilePath in
  # users/gurinderu/sing-box-config-darwin.nix) and the logrotate state file.
  # /var/lib does not exist by default on macOS, so the wrappers create it before
  # use. The log goes to /var/log (which always exists) because launchd opens
  # StandardOutPath BEFORE running the program — it cannot wait for a mkdir.
  stateDir = "/var/lib/sing-box";
  logPath = "/var/log/sing-box.log";

  start = pkgs.writeShellScript "sing-box-start" ''
    mkdir -p ${stateDir}
    chmod 700 ${stateDir}
    # On a config reload / darwin-rebuild, launchd boots out the old instance
    # (SIGTERM) and bootstraps this new one. The old sing-box keeps the bbolt
    # flock on cache.db while it drains TUN/connections, so the new process hits
    # the held lock, waits out bbolt's open timeout and dies with
    # "initialize cache-file: timeout" — crash-looping (KeepAlive) until the old
    # one finally releases. Wait for the previous holder to let go of cache.db
    # first so the new process opens it cleanly. Bounded at ~30s: if something is
    # wedged we fall through and let KeepAlive retry as before. /usr/sbin/lsof
    # and /bin/sleep are on the always-mounted system volume.
    i=0
    while [ $i -lt 30 ] && /usr/sbin/lsof ${stateDir}/cache.db >/dev/null 2>&1; do
      /bin/sleep 1
      i=$((i + 1))
    done
    exec ${pkgs.sing-box}/bin/sing-box run -c ${configPath}
  '';

  # copytruncate is the key: logrotate copies the log then truncates it IN PLACE,
  # so launchd's append-mode fd keeps writing to the same inode (no reopen needed,
  # which launchd can't do anyway). rotate+compress cap total disk; old rotations
  # past the count are deleted automatically.
  # /var/log/net-observer.log is written by the net-observer daemon
  # (./net-observer.nix); it shares this rotation so no second logrotate
  # daemon is needed. Keep the path in sync with net-observer.nix.
  logrotateConf = pkgs.writeText "sing-box-logrotate.conf" ''
    ${logPath} /var/log/net-observer.log {
        su root wheel
        size 20M
        rotate 5
        copytruncate
        compress
        delaycompress
        missingok
        notifempty
        nomail
    }
  '';

  logrotateStart = pkgs.writeShellScript "sing-box-logrotate-start" ''
    mkdir -p ${stateDir}
    exec ${pkgs.logrotate}/bin/logrotate --state ${stateDir}/logrotate.state ${logrotateConf}
  '';
in
{
  launchd.daemons.sing-box.serviceConfig = {
    # The program lives in /nix/store, which is a SEPARATE APFS volume mounted at
    # boot by org.nixos.darwin-store. launchd has no ordering between daemons, so a
    # RunAtLoad daemon can fire before /nix is mounted: posix_spawn then fails with
    # ENOENT and launchd reports `last exit code = 78 (EX_CONFIG)` — a spawn-time
    # config error, NOT a sing-box exit (sing-box exits 1 on config errors). Because
    # WatchPaths only watches the config on the data volume, launchd never retries
    # and the daemon stays dead until boot. Symptom: after a restart sing-box is not
    # running and nothing is written to its log (the binary never executed).
    #
    # Fix is the same pattern nix-darwin uses for nix-daemon: exec via /bin/sh and
    # block on /bin/wait4path until /nix/store appears. /bin/sh and /bin/wait4path
    # are on the always-mounted system volume, so the spawn itself never fails.
    ProgramArguments = [
      "/bin/sh"
      "-c"
      "/bin/wait4path /nix/store && exec ${start}"
    ];
    RunAtLoad = true;
    KeepAlive = true;
    # Don't hammer launchd if it crash-loops (e.g. config not yet rendered on the
    # very first switch — home-manager activation runs after system activation).
    ThrottleInterval = 5;
    # NB: config reloads are handled by the sing-box-reload daemon below, NOT by
    # a WatchPaths here. launchd's WatchPaths only *starts a stopped* job when a
    # watched path changes; it never restarts an already-running one. A WatchPaths
    # on this always-running (KeepAlive) daemon would therefore silently do
    # nothing on a config-only change — sing-box would keep serving the stale
    # config until a manual kickstart (observed exactly that).
    StandardOutPath = logPath;
    StandardErrorPath = logPath;
  };

  # Restart sing-box whenever home-manager re-renders config.json. This is a
  # one-shot daemon: launchd keeps it stopped and (re)starts it on every change
  # to a WatchPaths entry — precisely the behaviour the main daemon's own
  # WatchPaths could NOT provide (launchd won't restart a running job). On each
  # fire it kickstarts (-k = kill + relaunch) the main daemon so it reads the new
  # config. Robust against activation ordering: it reacts to the final state of
  # config.json after home-manager has written it, not to rebuild timing. The
  # main daemon's lsof guard on cache.db absorbs the brief old/new overlap.
  # /bin/launchctl is on the always-mounted system volume, so no wait4path/nix
  # dependency is needed.
  launchd.daemons.sing-box-reload.serviceConfig = {
    ProgramArguments = [
      "/bin/launchctl"
      "kickstart"
      "-k"
      "system/org.nixos.sing-box"
    ];
    WatchPaths = [ configPath ];
    # No RunAtLoad: the main daemon starts itself at boot; this one should fire
    # only on subsequent config changes.
    RunAtLoad = false;
  };

  # Restart sing-box whenever the network changes (Wi-Fi roam, sleep/wake, link
  # up/down). This is the SAME kickstart trick as sing-box-reload above, but keyed
  # to a network transition instead of a config write.
  #
  # Why it's needed: on a transition macOS briefly has no default route. sing-box
  # logs "network: missing default interface", and with auto_detect_interface it
  # is meant to re-bind outbound sockets to the new interface once the network is
  # back — but on macOS it does not reliably do so. It stays bound to the gone
  # interface, so every dial to the VLESS servers fails (network unreachable /
  # i/o timeout). Because route.final sends ALL traffic through the proxy, the Mac
  # then loses all connectivity and never recovers on its own — only a manual
  # toggle fixes it. A fresh process re-detects the interface correctly, and
  # kickstart -k (kill + relaunch) is exactly that fresh start.
  #
  # Trigger: /etc/resolv.conf (symlink -> /var/run/resolv.conf) is rewritten by
  # configd whenever the primary network service changes, i.e. once the NEW
  # network is up — precisely when we want to re-detect. WatchPaths only *starts a
  # stopped* job, so like sing-box-reload this is a one-shot daemon (RunAtLoad
  # false) that fires and exits. ThrottleInterval debounces the burst of rewrites
  # a single transition emits (launchd won't relaunch this job more than once per
  # interval); the main daemon's lsof-on-cache.db guard absorbs the old/new
  # overlap of back-to-back kickstarts.
  launchd.daemons.sing-box-netreload.serviceConfig = {
    ProgramArguments = [
      "/bin/launchctl"
      "kickstart"
      "-k"
      "system/org.nixos.sing-box"
    ];
    WatchPaths = [ "/etc/resolv.conf" ];
    RunAtLoad = false;
    ThrottleInterval = 10;
  };

  # Size-cap the sing-box log: rotate every 15 min, compress, keep 5, delete the
  # rest. With debug-level logging the file can grow fast, so the interval is
  # short enough to bound it between runs.
  launchd.daemons.sing-box-logrotate.serviceConfig = {
    # Same /nix-not-yet-mounted spawn race as the sing-box daemon above; wait for
    # the store volume before exec'ing logrotate (which also lives in /nix/store).
    ProgramArguments = [
      "/bin/sh"
      "-c"
      "/bin/wait4path /nix/store && exec ${logrotateStart}"
    ];
    RunAtLoad = true;
    StartInterval = 900;
  };
}
