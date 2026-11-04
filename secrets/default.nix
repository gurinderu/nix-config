# Which sops file each host module reads. Layout and recipients: README
# "Secrets" and .sops.yaml.
#
#   shared.yaml    sing-box VLESS credentials        gurinderu + thinkpad
#   thinkpad.yaml  CI runner + Docker Hub tokens     gurinderu + thinkpad
#   mac.yaml       SSH keys                          gurinderu only
{
  shared = ./shared.yaml;
  thinkpad = ./thinkpad.yaml;
  mac = ./mac.yaml;
}
