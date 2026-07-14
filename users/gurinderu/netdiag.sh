#!/bin/bash
# Snapshot сетевого состояния для диагностики "мак не пингует gw в коворкинге".
# Запускать: sudo ~/netdiag.sh <метка>   (метка: ok | broken)
# Результат: ~/netdiag-<метка>-<время>.txt

LABEL="${1:-snap}"
OUT="$HOME/netdiag-$LABEL-$(date +%H%M%S).txt"
IF=en0

{
echo "=== $(date) label=$LABEL ==="

echo "--- Wi-Fi (wdutil info) ---"
wdutil info 2>/dev/null | grep -viE "^\s*(MAC Address|BSSID)\s*:\s*<redacted>"

echo "--- interface ---"
ifconfig $IF

echo "--- default route ---"
route -n get default

GW=$(route -n get default 2>/dev/null | awk '/gateway/{print $2}')
echo "--- DHCP lease ($IF) ---"
ipconfig getpacket $IF

echo "--- ARP table ---"
arp -an

echo "--- ping gw ($GW) 5x ---"
ping -c 5 -t 5 "$GW" 2>&1

echo "--- принудительный ARP к gw (после очистки) ---"
arp -d "$GW" 2>/dev/null
ping -c 3 -t 5 "$GW" 2>&1
arp -an | grep "$GW"

echo "--- ping broadcast (кто жив в сегменте) ---"
BCAST=$(ifconfig $IF | awk '/inet /{print $6}')
ping -c 3 -t 5 "$BCAST" 2>&1 | tail -15
arp -an | head -30

echo "--- ping 1.1.1.1 (мимо DNS) ---"
ping -c 3 -t 5 1.1.1.1 2>&1 | tail -3

echo "--- лог IPConfiguration за 30 мин ---"
log show --last 30m --predicate 'subsystem == "com.apple.IPConfiguration"' --style compact 2>/dev/null | grep -iE "arp|router|conflict|lease|roam" | tail -40

echo "--- вердикт Wi-Fi-драйвера (CoreCapture: Beacons Lost / Deauth / reassoc) ---"
# L1/L2-причина падения линка — именно её не видно в IPConfiguration-логе выше.
ls -1t /Library/Logs/CrashReporter/CoreCapture/WiFi 2>/dev/null | head -8

echo "--- смены сетевой эпохи en0 (roam/noroam) за 30 мин ---"
log show --last 30m --predicate 'process == "symptomsd" AND category == "netepochs"' --style compact 2>/dev/null | grep -iE "roam" | tail -20

echo "--- приватный MAC для текущей сети ---"
CURSSID=$(wdutil info 2>/dev/null | awk -F': ' '/ SSID/{print $2; exit}')
/usr/libexec/PlistBuddy -c "Print" /Library/Preferences/com.apple.wifi.known-networks.plist 2>/dev/null | grep -A5 -i "$CURSSID" | head -20
} > "$OUT" 2>&1

echo "Снято: $OUT"
