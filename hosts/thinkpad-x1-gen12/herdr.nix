# herdr for 0xff on the thinkpad, set up like cloud-vm: users/common/herdr.nix
# brings the package, the ssh/osewa auto-attach in zsh, the memory-capped
# herdr-server user unit and the tab-title plugin; users/common/zsh.nix
# already sends mosh logins to herdr once it is on PATH (instead of zellij
# `main`, as before).
#
# zellij stays installed and configured (users/common/home.nix): nothing
# starts it on its own any more, since the only auto-attach that used it (the
# mosh one) now prefers herdr, and local terminals never auto-attached to
# anything. Running `zellij` by hand in a local terminal works as before.
#
# What differs from cloud-vm (users/common/herdr-server.nix has the
# reasons for the unit itself):
#   * autostart: this host never had a client-spawned server to cut over
#     from, so the unit is enabled right away. linger for 0xff (./osewa.nix)
#     starts it at boot and keeps it, and every pane, across logouts.
#   * caps: 32 GB shared with two 6 GiB runner VMs (./github-runner.nix), the
#     local agents' model (./local-agents.nix) and the desktop, so the
#     cgroup is throttled at 8G and OOM-killed inside at 10G.
#   * environment: NixOS paths. PATH is a NixOS login's (wrappers, then the
#     per-user profile where home-manager's useUserPackages puts herdr and
#     the dev tools, then the system profile). No HERDR_CONFIG_PATH: the
#     desktop.toml layout is cloud-vm's (hosts/cloud-vm/home.nix), here
#     herdr reads its own ~/.config/herdr/config.toml.
{
  home-manager.users."0xff" = {
    imports = [ ../../users/common/herdr.nix ];

    herdrServer = {
      autostart = true;
      memoryHigh = "8G";
      memoryMax = "10G";
      environment = [
        "PATH=/run/wrappers/bin:%h/.nix-profile/bin:%h/.local/bin:/etc/profiles/per-user/%u/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin"
        "NIX_PROFILES=/run/current-system/sw /nix/var/nix/profiles/default /etc/profiles/per-user/%u %h/.nix-profile"
        "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
      ];
    };
  };
}
