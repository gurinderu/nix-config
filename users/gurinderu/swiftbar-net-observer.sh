#!/bin/bash
# SwiftBar plugin: the net-observer daemon's last TICK in the menu bar.
# Deployed by users/gurinderu/swiftbar.nix; the daemon it reads is
# ../../hosts/mac_aarch64/net-observer.nix.
#
# Reads only. Every action it offers is a `touch` in the daemon's request
# drop-box (/var/lib/net-observer/requests, mode 1777) — that indirection is
# why the plugin needs no sudo and why the daemon honours file NAMES only.
#
# <xbar.title>net-observer</xbar.title>
# <xbar.desc>Gateway RTT and link state from the net-observer daemon.</xbar.desc>

LOG=/var/log/net-observer.log
LIB=/var/lib/net-observer
REQ="$LIB/requests"

# --- actions (re-entry: SwiftBar calls this same file with param1) ----------
case "$1" in
  freeze)    /usr/bin/touch "$REQ/freeze";    exit 0 ;;
  snapshot)  /usr/bin/touch "$REQ/snapshot";  exit 0 ;;
  quiet-on)  /usr/bin/touch "$REQ/quiet";     exit 0 ;;
  quiet-off) /bin/rm -f "$REQ/quiet";         exit 0 ;;
esac

QUIET=0
[ -f "$REQ/quiet" ] && QUIET=1

tick=$(/usr/bin/grep -F ' TICK ' "$LOG" 2>/dev/null | /usr/bin/tail -1)

# The daemon being dead must not look like a healthy network: with no TICK at
# all, or one older than four tick intervals, the bar says so rather than
# showing a stale number that reads as current. (Absence of a signal is itself
# the diagnostic — the same rule the daemon's SKIP verdicts follow.)
age=-1
if [ -n "$tick" ]; then
  tick_ts=$(printf '%s' "$tick" | /usr/bin/cut -d' ' -f1-2)
  tick_s=$(/bin/date -j -f '%Y-%m-%d %H:%M:%S' "$tick_ts" '+%s' 2>/dev/null)
  [ -n "$tick_s" ] && age=$(( $(/bin/date +%s) - tick_s ))
fi

field() { printf '%s' "$tick" | /usr/bin/sed -n "s/.*[ ]$1=\\([^ ]*\\).*/\\1/p"; }

gwst=$(printf '%s' "$tick" | /usr/bin/sed -n 's/.*gw(\([^)]*\))=\([^ ]*\).*/\2/p')
gwip=$(printf '%s' "$tick" | /usr/bin/sed -n 's/.*gw(\([^)]*\))=.*/\1/p')

if [ -z "$tick" ] || [ "$age" -lt 0 ]; then
  echo "gw ? | color=#8e8e93"
elif [ "$age" -gt 60 ]; then
  echo "gw stale ${age}s | color=#8e8e93"
else
  case "$gwst" in
    QUIET)
      echo "gw 🔇 | color=#5ac8fa"
      ;;
    OK*)
      rtt=$(printf '%s' "$gwst" | /usr/bin/sed -n 's/OK(\([0-9.]*\)ms)/\1/p')
      col=$(/usr/bin/awk -v r="$rtt" 'BEGIN { print (r > 300) ? "#ffb700" : "#2ecc40" }')
      echo "gw ${rtt}ms | color=$col"
      ;;
    *)
      echo "gw ✕ | color=#ff3b30"
      ;;
  esac
fi

echo "---"

if [ -z "$tick" ]; then
  echo "No TICK in $LOG — daemon not running? | color=#ff3b30"
else
  echo "$(printf '%s' "$tick" | /usr/bin/cut -d' ' -f1-2)  (${age}s ago) | font=Menlo size=11"
  echo "gw($gwip) = $gwst | font=Menlo size=12"
  for f in if link ip ssid tun sel sb load site; do
    v=$(field "$f")
    [ -n "$v" ] && echo "$f = $v | font=Menlo size=12"
  done
  # The DNS columns are the hunt this daemon was built around; keep them
  # visible rather than making the log the only place to see a FAKEIP.
  for f in 'direct\[1.1.1.1\]' 'nks\[sb\]' 'ru\[sb\]' 'nks\[rtr\]' 'nks\[doh\]'; do
    v=$(printf '%s' "$tick" | /usr/bin/sed -n "s/.*[ ]$f=\\([^ ]*\\).*/\\1/p")
    [ -n "$v" ] && echo "$(printf '%s' "$f" | /usr/bin/tr -d '\\') = $v | font=Menlo size=12"
  done
fi

echo "---"
echo "Recent events"
events=$(/usr/bin/grep -E ' (ACT|GWD|GWCHG|DNS ALERT) ' "$LOG" 2>/dev/null | /usr/bin/tail -8)
if [ -n "$events" ]; then
  printf '%s\n' "$events" | while IFS= read -r line; do
    # Trim to the menu's width; the full line lives in the log, one click away.
    echo "$(printf '%s' "$line" | /usr/bin/cut -c1-110) | font=Menlo size=11"
  done
else
  echo "(none) | color=#8e8e93 font=Menlo size=11"
fi

echo "---"
echo "Freeze pcap now | bash=\"$0\" param1=freeze terminal=false refresh=true"
echo "Snapshot (SNAP block) | bash=\"$0\" param1=snapshot terminal=false refresh=true"
if [ "$QUIET" = 1 ]; then
  echo "Quiet: ON — resume gateway probes | bash=\"$0\" param1=quiet-off terminal=false refresh=true color=#5ac8fa"
else
  echo "Quiet: off — stop probing the gateway | bash=\"$0\" param1=quiet-on terminal=false refresh=true"
fi
echo "---"
echo "Reveal captures | bash=/usr/bin/open param1=$LIB terminal=false"
echo "Open log | bash=/usr/bin/open param1=$LOG terminal=false"
echo "Refresh | refresh=true"
