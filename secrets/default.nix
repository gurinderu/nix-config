# Which sops file each host module reads. Layout and recipients: README
# "Secrets" and .sops.yaml.
#
#   shared.yaml    sing-box VLESS credentials        gurinderu + thinkpad
#   thinkpad.yaml  CI runner + Docker Hub tokens     gurinderu + thinkpad
#   mac.yaml       SSH keys                          gurinderu only
#
# Transitional: the split files are produced on the Mac by
# scripts/split-sops-secrets.sh (it has to decrypt secrets.yaml, so it runs
# where the gurinderu age key lives). Until they are committed, every role
# resolves to the
# legacy secrets.yaml, so the config keeps evaluating and deploying exactly as
# before. sops-nix hashes each sopsFile at eval time, so a path to a file that
# does not exist yet would break eval outright. Once the split is committed and
# secrets.yaml is gone, drop `legacy` and the conditional.
let
  split = builtins.pathExists ./shared.yaml;
  legacy = ./secrets.yaml;
in
{
  shared = if split then ./shared.yaml else legacy;
  thinkpad = if split then ./thinkpad.yaml else legacy;
  mac = if split then ./mac.yaml else legacy;
}
