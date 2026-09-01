# SwiftBar menu-bar readout for the net-observer daemon
# (../../hosts/mac_aarch64/net-observer.nix).
#
# Why a widget at all: the daemon's whole point is that the coworking gateway
# fails by RAMPING — the ping RTT climbs in a straight line for ~40s before it
# stops answering. That is visible in the log only to someone already reading
# it, i.e. after the network is gone. In the menu bar it is an early warning,
# and the "freeze the pcap ring NOW" button turns a noticed ramp into evidence
# instead of a memory (2026-07-15: the one useful capture of a silent router
# drop was frozen by hand, and only because someone happened to be looking).
#
# The plugin is unprivileged by construction: it READS /var/log/net-observer.log
# (mode 644) and asks for actions by touching names in the daemon's drop-box
# /var/lib/net-observer/requests (mode 1777). No sudo, no setuid, no helper.
#
# The cask, the login agent and the plugin directory are declared system-side in
# ../../hosts/mac_aarch64/default.nix, next to the Ice agent they mirror.
{ ... }:
{
  # SwiftBar reads the refresh interval out of the FILE NAME: <name>.<int>.<ext>.
  # 15s matches the daemon's tick — polling faster only re-reads the same line.
  home.file.".config/swiftbar/plugins/net-observer.15s.sh" = {
    source = ./swiftbar-net-observer.sh;
    executable = true;
  };
}
