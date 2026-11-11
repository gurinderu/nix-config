# Activation step for the herdr plugins (./herdr-tab-title.nix):
# link the plugin directory into herdr, relinking only when the registered
# manifest_path differs from the current manifest (see the herdr-tab-title.nix
# header for why that comparison is the right trigger).
# Never fails activation: every failure path just reports and continues.
#
# Returns a function building the home.activation entry text:
#   id         herdr plugin_id (also the message prefix)
#   pluginDir  directory holding herdr-plugin.toml
#   var        shell variable prefix, unique per plugin (the entries share one
#              activation script)
#   linkedMsg  message printed after a first successful link
{
  lib,
  pkgs,
  herdr,
}:
{
  id,
  pluginDir,
  var,
  linkedMsg,
}:
''
  ${var}_reg=$(${herdr}/bin/herdr plugin list --json 2>/dev/null \
    | ${pkgs.python3}/bin/python3 -I -c '
  import json, sys
  try:
      ps = json.load(sys.stdin)["result"]["plugins"]
  except Exception:
      sys.exit(1)
  for p in ps:
      if p.get("plugin_id") == "${id}":
          print(p.get("manifest_path") or "?")
  ') || ${var}_reg="?error"
  ${var}_want=$(readlink -f ${lib.escapeShellArg pluginDir}/herdr-plugin.toml)
  case "${"$"}${var}_reg" in
    "?error")
      echo "${id}: could not read 'herdr plugin list'; plugin not linked (continuing)" >&2 ;;
    "${"$"}${var}_want")
      : ;;
    "")
      if run ${herdr}/bin/herdr plugin link ${lib.escapeShellArg pluginDir}; then
        echo "${id}: ${linkedMsg}" >&2
      else
        echo "${id}: 'herdr plugin link' failed (continuing)" >&2
      fi ;;
    *)
      echo "${id}: plugin registered from ${"$"}${var}_reg, relinking to ${"$"}${var}_want" >&2
      run ${herdr}/bin/herdr plugin unlink ${id} || true
      run ${herdr}/bin/herdr plugin link ${lib.escapeShellArg pluginDir} \
        || echo "${id}: 'herdr plugin link' failed (continuing)" >&2 ;;
  esac
''
