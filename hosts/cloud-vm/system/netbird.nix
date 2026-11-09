# NetBird client daemon on cloud-vm — the same self-hosted mesh as the Mac
# (hosts/mac_aarch64/netbird.nix; control plane SING_BOX_NETBIRD_MGMT_DOMAIN, SSO via
# SING_BOX_IDP_DOMAIN), from the same pkgs/netbird at the same version as
# the CLI that ../netbird.nix puts on the user's PATH. Linux side is CLI +
# daemon only. The Mac's sing-box routing workarounds (NB_DISABLE_CUSTOM_ROUTING,
# the TUN wait) are RU-network specific and do not apply here. Only in the
# cloud-vm-netbird system config.
#
# The daemon runs as root (it creates wt0 and installs routes/firewall rules).
# First login on a new VM, after the system-manager switch:
#
#   netbird status    # Daemon status: NeedsLogin
#   sudo ~/.nix-profile/bin/netbird up --management-url <managementUrl> --no-browser
#
# sudo's secure_path lacks the nix profile, hence the full path (plain `sudo
# netbird` fails with "No such file or directory"); non-root `netbird status`
# works as is. The first `up` needs --management-url (see managementUrl
# below); it saves the URL to /var/lib/netbird/default.json, so later `up`
# calls can leave it out. `--no-browser` prints a device-code login link (valid
# 10 min); `up --setup-key <key>` is the alternative. State is in
# /var/lib/netbird, the log in /var/log/netbird/client.log (plus `journalctl
# -u netbird`).
#
# Not `netbird service install`: kardianos writes its own unit with the
# resolved /nix/store path baked in, in a file nix does not own, which then
# goes stale (and eventually GC'd) on the next bump.
#
# Coexistence with tailscale (apt-installed, tailscale0, also 100.64.0.0/10):
# tailscale's ts-input chain drops 100.64.0.0/10 sources arriving on any
# interface but tailscale0, but netbird inserts its own `-i wt0 -j ACCEPT` as
# the first INPUT rule, ahead of the ts-input jump, so wt0 traffic gets
# through. A tailscaled restart re-inserts the ts-input jump at the top, which
# leaves the wt0 accept below it until netbird restarts. Separately, the
# host's own DNS queries to netbird's resolver arrive on lo (not wt0) with a
# 100.64.0.0/10 source, so ./lo-accept.nix keeps `-i lo -j ACCEPT` first and
# re-asserts it after every tailscaled/netbird (re)start; check with `sudo
# iptables -S INPUT`. Don't use `tailscale set --netfilter-mode=nodivert`: it
# also drops the ts-postrouting masquerade the exit-node offer needs. Routes
# don't clash: tailscale only installs /32s for its own peers (table 52), so
# netbird's subnet route via wt0 loses only on an address both meshes hand out.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  netbird = pkgs.callPackage ../../../pkgs/netbird { };

  # Passed to `service run` as on the Mac, but on 0.75.1 that does NOT seed a
  # fresh profile: the first /var/lib/netbird/default.json is written with
  # api.netbird.io (measured 2026-11-03). The first login must therefore be
  # `sudo ~/.nix-profile/bin/netbird up --management-url <this>`, which
  # persists it.
  managementUrl = "https://SING_BOX_NETBIRD_MGMT_DOMAIN:443";
in
{
  systemd.services.netbird = {
    description = "NetBird mesh client (SING_BOX_NETBIRD_MGMT_DOMAIN)";
    documentation = [ "https://docs.netbird.io" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    environment.PATH = lib.mkForce config.cloudVm.servicePath;
    # StateDirectory/LogsDirectory make systemd create /var/lib/netbird (0700,
    # the profile with the peer's WireGuard private key) and /var/log/netbird.
    # netbird rotates and gzips client.log itself. Stdout/stderr (panics,
    # pre-logger startup errors) still land in `journalctl -u netbird`.
    serviceConfig = {
      ExecStart = "${netbird}/bin/netbird service run --log-level info --daemon-addr unix:///var/run/netbird.sock --log-file /var/log/netbird/client.log --management-url ${managementUrl}";
      StateDirectory = "netbird";
      StateDirectoryMode = "0700";
      LogsDirectory = "netbird";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
