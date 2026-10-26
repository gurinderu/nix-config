# herdr-notify — Mac desktop notifications for herdr-managed agents on
# cloud-vm. Python, stdlib only; one package for both ends:
#
#   cloud-vm  bin/herdr-notify-hook   herdr event hook -> ~/.local/state spool
#             bin/herdr-notify-serve  forced command of the Mac's ssh key
#   Mac       bin/herdr-notify-agent  launchd agent: ssh stream -> Warp OSC 777
#
# Modules: hosts/cloud-vm/herdr-notify.nix (VM), users/gurinderu/herdr-notify.nix
# (Mac). Tests: tests/, run by checks.x86_64-linux.herdr-notify in flake.nix.
# Design notes and the threat model live in the module headers and the README.
#
# The scripts run with `python3 -I` (no PYTHONPATH, no user site, no script
# dir on sys.path); each one adds its own lib dir explicitly.
{
  lib,
  stdenvNoCC,
  runtimeShell,
  python3,
}:
stdenvNoCC.mkDerivation {
  pname = "herdr-notify";
  version = "1.0.0";
  src = ./src;
  dontConfigure = true;
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/herdr-notify $out/bin
    cp hnlib.py hnvm.py hook.py serve.py agent.py $out/lib/herdr-notify/
    for t in hook serve agent; do
      cat > $out/bin/herdr-notify-$t <<EOF
    #!${runtimeShell}
    exec ${python3}/bin/python3 -I $out/lib/herdr-notify/$t.py "\$@"
    EOF
      chmod 755 $out/bin/herdr-notify-$t
    done
    runHook postInstall
  '';
  meta = {
    description = "Mac desktop notifications for herdr agents on a remote VM";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
