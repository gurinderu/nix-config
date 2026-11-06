# The sing-box config is no longer rendered here. Until 2026-11-06 this
# home-manager activation decrypted the VLESS secrets and wrote
# ~/.config/sing-box/config.json, which the ROOT launchd daemon then ran and a
# root WatchPaths job reloaded on change — so any process running as this user
# could rewrite a root daemon's config and make root write wherever log.output,
# cache_file.path or clash_api's external_ui pointed. Rendering now happens as
# root into /etc/sing-box/config.json (hosts/mac_aarch64/sing-box.nix,
# renderConfig).
#
# What is left is removing the old rendered file: it still holds the
# decrypted credentials in cleartext and nothing reads it any more. Done here,
# as the user, on purpose — root deleting paths inside a user-controlled
# directory is the same trust inversion this move removes (a symlinked
# ~/.config/sing-box would aim the delete anywhere). Idempotent; drop this
# module once every machine has switched past it.
{ config, lib, ... }:
{
  home.activation.singBoxLegacyConfigCleanup = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    legacy="${config.home.homeDirectory}/.config/sing-box"
    if [ -e "$legacy/config.json" ] || [ -L "$legacy/config.json" ]; then
      $DRY_RUN_CMD rm -f "$legacy/config.json"
      $DRY_RUN_CMD rmdir "$legacy" 2>/dev/null || true
    fi
  '';
}
