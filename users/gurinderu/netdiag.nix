# netdiag — ручной снапшот сетевого состояния для расследования "Mac не пингует gw
# в коворкинге (MikroTik)". Снимает ARP-слой (arp -an, force-ARP, DHCP-lease,
# broadcast-ping, IPConfiguration-лог, приватный MAC) — то, чего нет в
# постоянном логе net-observer (см. ../../hosts/mac_aarch64/net-observer.nix).
#
# Запускается под sudo по полному пути (`sudo ~/netdiag.sh ok|broken`), поэтому
# ставится как home.file по фиксированному пути, а не как writeShellScriptBin:
# бинарь из per-user nix-профиля в sudo-PATH на macOS не находится.
{ ... }:
{
  home.file."netdiag.sh" = {
    source = ./netdiag.sh;
    executable = true;
  };
}
