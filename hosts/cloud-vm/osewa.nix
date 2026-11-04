# osewa server on cloud-vm (persistent terminals over QUIC / TLS WebSocket,
# port 7322 TCP+UDP), next to mosh rather than instead of it. Package:
# pkgs/osewa; the Mac's client is users/gurinderu/osewa.nix, same version.
#
# Upstream's way in is `osewa login --service me@host` from the client, which
# over ssh copies a binary to ~/.local/bin/osewa, writes
# ~/.config/systemd/user/osewa.service and enables it. Here nix owns both, so
# the Mac enrolls with `osewa login --no-install` (README "osewa"), which runs
# only `osewa enroll && osewa server --daemon` on the VM:
#
#   * `enroll` reads the device's public key on stdin, adds it to
#     ~/.config/osewa/devices and answers with the server key and port.
#   * `server --daemon` finds the unit's server holding the lock in
#     $XDG_RUNTIME_DIR/osewa/server.pid and exits 0 ("already running").
#
# Both go through the PATH of a non-interactive `ssh host cmd`, i.e. zsh -c
# with only .zshenv: /etc/environment plus ~/.local/bin (home.sessionPath),
# but NOT ~/.nix-profile/bin. Hence the ~/.local/bin/osewa symlink below. Do
# not use `login` without --no-install, `login --service` or `osewa update
# fluence`: they write a real binary over that symlink, or the unit file over
# home-manager's (the switch then stops on the collision).
#
# The unit mirrors upstream's (`service install`: KillMode=process, so a
# restart ends only the server and every session's holder lives on;
# Restart=on-failure, RestartSec=2, default.target), with the store path in
# ExecStart and OSEWA_AUTO_UPDATE=off. That env var beats settings.json, and
# with it the server never runs its hourly check that would replace its own
# binary. `osewa set auto-update off` at activation covers CLI use on the VM
# (a daily check after interactive commands otherwise).
#
# A user service only runs without a login session with lingering on
# (`sudo loginctl enable-linger ubuntu`, README). The firewall (README) keeps
# 7322 to tailscale0 and wt0.
#
# State: keys and enrolled devices in ~/.config/osewa (server.key, devices,
# settings.json), holder sockets and the server lock in
# $XDG_RUNTIME_DIR/osewa, the update cache in ~/.local/state/osewa. Sessions
# run the passwd login shell (zsh -l) with a clean environment; they carry no
# SSH_CONNECTION, so the zellij auto-attach in home.nix stays out of them.
{
  lib,
  pkgs,
  ...
}:
let
  osewa = pkgs.callPackage ../../pkgs/osewa { };
in
{
  home.packages = [ osewa ];

  # What `osewa enroll` over plain ssh finds (see the header). Points at the
  # store path, kept alive by this generation like any home.file.
  home.file.".local/bin/osewa".source = "${osewa}/bin/osewa";

  systemd.user.services.osewa = {
    Unit.Description = "osewa server (persistent terminals)";
    Service = {
      ExecStart = "${osewa}/bin/osewa server";
      Environment = [ "OSEWA_AUTO_UPDATE=off" ];
      KillMode = "process";
      Restart = "on-failure";
      RestartSec = 2;
    };
    Install.WantedBy = [ "default.target" ];
  };

  # Rewrites one key of settings.json and keeps the rest; a failure must not
  # abort the switch.
  home.activation.osewaAutoUpdate = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if ! run ${osewa}/bin/osewa set auto-update off </dev/null >/dev/null; then
      echo "osewa: could not set auto-update off (continuing)" >&2
    fi
  '';
}
