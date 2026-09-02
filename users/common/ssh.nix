# GitHub over SSH, on every host.
#
# All egress is tunnelled: github.com resolves to a sing-box fakeip and leaves
# through the VLESS exit, so GitHub sees the exit's address rather than ours.
# GitHub closes port 22 from it — the TCP connection is established, the client
# sends its version string, and the far end hangs up before sending its own
# (`kex_exchange_identification: Connection closed by remote host`). Every
# `git pull` over an ssh remote dies there.
#
# It is GitHub specifically, and not the tunnel, the exit or the key. Measured
# from the thinkpad through the same exit on the same port: gitlab.com,
# bitbucket.org and codeberg.org all complete the SSH handshake and answer
# "Permission denied (publickey)", which is the handshake succeeding and only
# the key being unknown there. GitHub itself answers that very exit over HTTPS,
# and authenticates it over SSH on 443. So this is address reputation applied to
# port 22 alone, and nothing on our side can change it.
#
# ssh.github.com:443 is GitHub's own documented endpoint for exactly this, and
# taking it here keeps every `git@github.com:...` remote working untouched — no
# rewriting remotes to HTTPS, no per-repository exceptions.
#
# If the exit address ever changes and port 22 comes back, this block is inert
# rather than wrong: 443 stays supported. Remove it only after checking that
# plain `ssh -T git@github.com` completes a handshake from the machine in
# question.
{ lib, ... }:
{
  programs.ssh = {
    # mkDefault so a host that configures programs.ssh itself (the mac, in
    # users/gurinderu/ssh.nix) keeps its own value.
    enable = lib.mkDefault true;
    settings."github.com" = {
      HostName = "ssh.github.com";
      Port = 443;
      User = "git";
    };
  };
}
