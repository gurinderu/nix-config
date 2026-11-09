# Keep `-i lo -j ACCEPT` as the first rule of the iptables filter INPUT chain
# on cloud-vm, ahead of tailscale's ts-input jump. Only in the cloud-vm-netbird
# system config: without NetBird nothing needs it.
#
# Why: NetBird's DNS resolver listens on the host's own wt0 address. The
# host's queries to it never touch wt0: they go over `lo`, with that
# 100.64.0.0/10 address as the source. tailscale's ts-input chain (jumped from
# INPUT) has `-s 100.64.0.0/10 ! -i tailscale0 -j DROP`, so those queries are
# dropped and mesh DNS times out (and so does everything that resolves
# through systemd-resolved, sudo's hostname lookup included). netbird's own
# `-i wt0 -j ACCEPT` does not help: the packets arrive on lo. The rule here
# carries no address on purpose, loopback traffic is local by definition.
#
# It also keeps netbird's own `-i wt0 -j ACCEPT` (when present) above the
# ts-input jump. netbird puts it there when it starts, but a later tailscaled
# restart re-inserts ts-input at the top, and its `-s 100.64.0.0/10 !
# -i tailscale0 -j DROP` then drops NetBird peers' traffic on wt0 (NetBird's
# range is inside 100.64.0.0/10). The script moves that rule (delete one copy,
# insert it at position 2) so the chain starts lo, wt0, ts-input. It never adds
# a wt0 rule that netbird has not: on a host without netbird nothing changes.
#
# Both daemons insert at INPUT position 1 on every start, AFTER their unit
# reports started (measured 2026-11-09): tailscaled's ts-input jump about a
# second later (tailscale 1.104.4), netbird's `-i wt0 -j ACCEPT` about six
# seconds later (0.81.4), so a plain oneshot ordered After= them runs too
# early and ends up below. The script therefore re-asserts the order, then
# polls (up to 30 s) until each active daemon's rule is present and the order
# (loopback first, wt0 above ts-input) has held for a few consecutive checks.
# netbird's own insert at 1 (wt0, lo, ts-input) only needs loopback moved back
# to the top, which leaves wt0 second: the two never fight. A netbird that is
# running but logged out never adds its rule; the script then just times out,
# still with loopback first, and exits 0.
# partOf makes a stop/restart of tailscaled or netbird restart this unit too;
# wantedBy starts it whenever either starts (and at boot).
#
# iptables is the system /usr/sbin/iptables (nf_tables backend here), the same
# one tailscale and ufw drive; a nix iptables could pick a different backend.
#
# Check: `sudo iptables -S INPUT` shows `-A INPUT -i lo -j ACCEPT` first,
# then `-i wt0 -j ACCEPT` (on a netbird host), then `-j ts-input`;
# `journalctl -u lo-accept` logs each run.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  script = pkgs.writeShellScript "lo-accept" ''
    ipt="/usr/sbin/iptables -w"
    rule="-i lo -j ACCEPT"
    wt0="-i wt0 -j ACCEPT"

    put_first() {
      while $ipt -C INPUT $rule 2>/dev/null; do
        $ipt -D INPUT $rule
      done
      $ipt -I INPUT 1 $rule
    }
    is_first() {
      [ "$($ipt -S INPUT | ${pkgs.gnused}/bin/sed -n 2p)" = "-A INPUT $rule" ]
    }
    # Line of the first INPUT rule exactly matching $1 (empty if none).
    line_of() {
      $ipt -S INPUT | ${pkgs.gnugrep}/bin/grep -nxm1 -- "-A INPUT $1" | ${pkgs.coreutils}/bin/cut -d: -f1
    }
    # netbird's wt0 accept, if it exists, sits above the ts-input jump.
    wt0_ok() {
      w=$(line_of "$wt0")
      t=$(line_of "-j ts-input")
      [ -z "$w" ] || [ -z "$t" ] || [ "$w" -lt "$t" ]
    }
    # Move one copy (the topmost) right below loopback; never adds one.
    put_wt0() {
      $ipt -D INPUT $wt0 && $ipt -I INPUT 2 $wt0
    }
    has() {
      $ipt -S INPUT | ${pkgs.gnugrep}/bin/grep -qx -- "-A INPUT $1"
    }
    # Both daemons insert at position 1 some seconds after they report
    # started; wait for each active one's rule to show up.
    peers_ready() {
      if /usr/bin/systemctl -q is-active tailscaled; then
        has "-j ts-input" || return 1
      fi
      if /usr/bin/systemctl -q is-active netbird; then
        has "$wt0" || return 1
      fi
    }

    put_first
    stable=0
    for _ in $(seq 60); do
      if ! is_first; then
        put_first
        echo "re-inserted loopback accept as INPUT rule 1"
        stable=0
      elif ! wt0_ok; then
        put_wt0
        echo "moved netbird's wt0 accept above the ts-input jump"
        stable=0
      elif peers_ready; then
        stable=$((stable + 1))
        [ "$stable" -ge 4 ] && exit 0
      fi
      sleep 0.5
    done
    # Timed out, e.g. netbird running but logged out (no wt0 rule ever).
    echo "peer rules not all present after 30 s; current chain:" >&2
    $ipt -S INPUT >&2
    is_first && wt0_ok
  '';
in
{
  systemd.services.lo-accept = {
    description = "Keep loopback and wt0 accepts ahead of tailscale's INPUT drop";
    after = [
      "tailscaled.service"
      "netbird.service"
      "ufw.service"
    ];
    partOf = [
      "tailscaled.service"
      "netbird.service"
    ];
    wantedBy = [
      "multi-user.target"
      "tailscaled.service"
      "netbird.service"
    ];
    environment.PATH = lib.mkForce config.cloudVm.servicePath;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = script;
    };
  };
}
