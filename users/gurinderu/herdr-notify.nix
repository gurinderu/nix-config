# herdr-notify, Mac half: a launchd agent that holds one ssh session to
# cloud-vm (dedicated key, forced command; VM half in
# hosts/cloud-vm/herdr-notify.nix) and turns each validated "agent finished /
# needs you" record into a Warp desktop notification.
#
# Delivery is Warp's own OSC 777 (`ESC ] 777 ; notify ; title ; body BEL`),
# written to the tty of the Warp tab whose mosh-client is connected to the VM
# -- mosh itself does not forward OSC 777, hence the side channel. Warp then
# applies its notification settings (sound, banners only while Warp is not in
# front) and a click brings up that tab. No Warp tab with a mosh-client to the
# VM -> the notification is dropped and logged: there would be no tab for the
# click to land on. No terminal-notifier, no Homebrew.
#
# Click-to-pane (focusOnClick): Warp has no click callback, so it is "latest
# wins" as in ProjectAJ14's herdr-warp: after a notification posted while Warp
# was in the background, the next time Warp becomes frontmost within 10 min --
# clicking the banner, but also Cmd-Tab -- the agent asks the VM once to focus
# that herdr pane (`focus <pane> <terminal_id>` over the same key).
#
# Bootstrap (once): see README "herdr-notify". Until
# ~/.ssh/herdr_notify_ed25519 exists the agent only logs and idles.
# Log: ~/Library/Logs/herdr-notify.log.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  herdr-notify = pkgs.callPackage ../../pkgs/herdr-notify { };
  home = config.home.homeDirectory;
  focusOnClick = true;
  # cloud-vm by tailnet IP, not name: names hit sing-box fakeip (see ssh.nix).
  vmIp = "100.72.145.54";
  # Pinned host key of cloud-vm (/etc/ssh/ssh_host_ed25519_key.pub).
  knownHosts = pkgs.writeText "herdr-notify-known_hosts" ''
    fluence ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH8uk4XfMEw3FPbCueDQA3ObWkRvthPW6dOKdJ3P/QCl
  '';
in
lib.mkIf pkgs.stdenv.isDarwin {
  launchd.agents.herdr-notify = {
    enable = true;
    config = {
      ProgramArguments = [
        "${herdr-notify}/bin/herdr-notify-agent"
        "--host"
        vmIp
        "--user"
        "ubuntu"
        "--key"
        "${home}/.ssh/herdr_notify_ed25519"
        "--known-hosts"
        "${knownHosts}"
        "--host-key-alias"
        "fluence"
        "--state-dir"
        "${home}/Library/Application Support/herdr-notify"
        # Spellings a `mosh-client` to the VM may carry in its argv: mosh
        # passes the original host argument and the resolved IP.
        "--vm-addr"
        vmIp
        "--vm-addr"
        "fluence"
        "--vm-addr"
        "fluence.tail411887.ts.net"
        "--max-age"
        "900"
        "--jump-window"
        "600"
      ]
      ++ lib.optional (!focusOnClick) "--no-focus-on-click";
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 10;
      # Not "Background": that class coalesces timers, and the agent's
      # latency and its 0.3 s frontmost-app poll after a notification matter.
      WorkingDirectory = home;
      EnvironmentVariables = {
        HOME = home;
        PATH = "/usr/bin:/bin:/usr/sbin:/sbin";
      };
      StandardOutPath = "${home}/Library/Logs/herdr-notify.log";
      StandardErrorPath = "${home}/Library/Logs/herdr-notify.log";
    };
  };
}
