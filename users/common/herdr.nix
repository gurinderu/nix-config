# herdr (agent-aware terminal multiplexer, from numtide's llm-agents.nix; not
# in our stable nixpkgs) as the remote-login multiplexer. Imported by the
# hosts that run it: cloud-vm (hosts/cloud-vm/home.nix) and the NixOS
# thinkpad (hosts/thinkpad-x1-gen12/herdr.nix).
#
# What lands in herdr, per kind of login:
#   * mosh: users/common/zsh.nix attaches to herdr wherever it is on PATH (and
#     falls back to zellij `main` on hosts without it).
#   * ssh, and osewa sessions: the zsh snippet below, keyed on SSH_CONNECTION.
#     osewa sets SSH_CONNECTION (ending in its port, 7322) for the sessions it
#     spawns, so they attach to herdr exactly like ssh logins.
#   * the Moshi app runs its own `herdr` attach command and never sources
#     .zshrc.
#   * local terminals: nothing changes; no SSH_CONNECTION, no mosh-server
#     parent.
#
# The server runs in a memory-capped user unit (./herdr-server.nix), and
# agent tabs are named after the agent's terminal title
# (./herdr-tab-title.nix). moshi-hook (./moshi-hook.nix), where imported,
# finds herdr on config.home.profileDirectory/bin, where home.packages land on
# both hosts (~/.nix-profile on cloud-vm, /etc/profiles/per-user/$USER on
# NixOS with useUserPackages).
{
  inputs,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    ./herdr-server.nix
    ./herdr-tab-title.nix
  ];

  home.packages = [ inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.herdr ];

  # Interactive ssh logins (and osewa sessions, see the header) land in
  # herdr's default session (`herdr` alone attaches to it or starts it), with
  # the full UI: a dropped connection reattaches to the same panes on the next
  # login, and leaving herdr (detach or exit) closes the shell too. Skipped
  # inside herdr (whose panes inherit SSH_CONNECTION from the login that
  # started its server), for `ssh host cmd` / `osewa exec` (not interactive,
  # so .zshrc never runs) and on dumb terminals. If herdr itself fails, the
  # plain shell stays as a fallback. Order 995: right after the
  # zsh-autosuggestions source (990, ./zsh.nix), before home-manager's
  # starship/direnv hooks (1000), whatever the module order.
  programs.zsh.initContent = lib.mkOrder 995 ''
    if [[ -n $SSH_CONNECTION && -z $HERDR_ENV && $TERM != dumb ]]; then
      herdr && exit
    fi
  '';
}
