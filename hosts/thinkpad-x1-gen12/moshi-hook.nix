# moshi-hook for 0xff on the thinkpad: the daemon, the agent hooks and the
# pairing watcher are users/common/moshi-hook.nix, as on cloud-vm. Pairing
# stays manual (`moshi-hook pair --token ...`, see that module).
#
# The Moshi app probes a host over ssh with its own PATH, which starts with
# ~/.local/bin and does not include /etc/profiles/per-user/$USER/bin, where
# home.packages land here. An old hand-installed moshi-hook 0.2.34 sat in
# ~/.local/bin and answered the app's `mux ls --json` with "unknown flag",
# so the app's sessions to this laptop failed. The links below put the
# packaged binaries there instead; force replaces that old file.
{
  home-manager.users."0xff" =
    { config, ... }:
    let
      bin = "${config.home.profileDirectory}/bin";
    in
    {
      imports = [ ../../users/common/moshi-hook.nix ];
      home.file = {
        ".local/bin/moshi-hook" = {
          source = config.lib.file.mkOutOfStoreSymlink "${bin}/moshi-hook";
          force = true;
        };
        ".local/bin/moshi" = {
          source = config.lib.file.mkOutOfStoreSymlink "${bin}/moshi";
          force = true;
        };
      };
    };
}
