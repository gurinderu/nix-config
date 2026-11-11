# osewa server for 0xff on the thinkpad, the same one cloud-vm runs: the
# home-manager side (user unit with the store path, KillMode=process,
# Restart=always, OSEWA_AUTO_UPDATE=off, `osewa set auto-update off` at
# activation, ~/.local/bin/osewa) is users/common/osewa-server.nix, whose
# header explains each choice. The Mac enrolls this laptop once with
# `osewa login 0xff@100.77.143.123 --no-install --name nixos`
# (users/gurinderu/osewa.nix); --no-install is required, see that header.
#
# Here only what NixOS owns: lingering, so the user unit starts at boot and
# survives logout, and 7322 TCP (TLS WebSocket) + UDP (QUIC) open on the
# tailnet only, like mosh in configuration.nix. tailscale0 is not a trusted
# interface on this host (only sing-box's tun0 is), so the ports are listed.
#
# The server runs as 0xff, so local-agents.nix's agent-out / agent-reply
# chains (owner-matched on the `agent` user, plus replies to its
# conn-marked connections) never see its traffic. They do keep the agent
# user away from it: its tailnet and UDP traffic to local addresses is
# dropped, and 0xff's answers to its local TCP connects are too.
{
  users.users."0xff".linger = true;

  networking.firewall.interfaces.tailscale0 = {
    allowedTCPPorts = [ 7322 ];
    allowedUDPPorts = [ 7322 ];
  };

  home-manager.users."0xff".imports = [ ../../users/common/osewa-server.nix ];
}
