# MikroTik Hotspot diagnostics — read-only command list

## RouterOS version notes (as of 2026-09-25)

This router runs **7.20.8** (2026-02-02) — the tail of the previous long-term
branch. Released since then: 7.21–7.21.5, 7.22–7.22.3, 7.23–7.23.7
(18 releases). Current stable = **7.23.7** (2026-09-16); conservative
option = **7.21.5** (2026-07-03, current long-term branch).

Fixes shipped after 7.20.8 that are directly relevant to hotspot clients
being deauthorized while L2 stays up:

- **7.22: "hotspot - do not invalidate static ARP entries"** — if the hotspot
  bridge uses `arp=reply-only` with static/lease-synced ARP entries, the
  hotspot invalidating them breaks keepalive probing, so authorized clients
  get kicked by `keepalive-timeout` even though they are reachable.
- **7.22: "hotspot - fixed www response after login by cookie"** — broken
  cookie re-login turns every deauth into a full portal login instead of a
  transparent re-auth.
- 7.21.5 / 7.23.1: "bridge - fixed stability issue when using DHCPv4 snooping".
- Security: 7.21.5 / 7.23.2 fix a service security issue ("recommend the
  upgrade for all users regardless"); 7.23.6 fixes CVE-2026-67278 (crypto)
  and CVE-2026-16347 (failed-login delay).

Config-side check that needs no upgrade: `keepalive-timeout` in
`/ip hotspot user profile` — a regular ~5 min deauth cadence usually means
keepalive probes (ARP/ICMP) to the client fail, not an expired session.
Setting it to none (or fixing ARP mode on the hotspot bridge) removes the
symptom; `session-timeout`/`idle-timeout` in the same profile are the other
two candidates.

References (MikroTik has no public bug tracker; SUP-xxxxx tickets are private,
so the changelog line + forum are the only public trace):

- v7.22 stable announcement (both hotspot fixes in the changelog):
  <https://forum.mikrotik.com/t/v7-22-stable-is-released/269092>
  (first appeared in 7.22beta1, 2026-01-02:
  <https://forum.mikrotik.com/t/v7-22beta-development-is-released/267611>)
- Long-running public thread on the underlying ARP bug family
  (`arp=reply-only` + DHCP `add-arp=yes` → invalid ARP entries, hotspot
  deployments affected; SUP-137777; partial fix in 7.16, completed for
  hotspot in 7.22): <https://forum.mikrotik.com/viewtopic.php?t=187802>
- Symptom threads for the keepalive mechanism ("logged out: keepalive
  timeout" every few minutes):
  <https://forum.mikrotik.com/t/users-keep-getting-logged-out-every-few-minutes/121655>,
  <https://forum.mikrotik.com/t/hotspot-problem-with-keepalive-timeout/51213>

## Export sections

```
/ip hotspot export
/ip firewall export
/ip dhcp-server export
/system scheduler export
/queue export
/radius export
```

## Granular prints

### Device / firmware
```
/system resource print
/system routerboard print
```

### Hotspot
```
/ip hotspot print
/ip hotspot profile print
/ip hotspot profile print detail
/ip hotspot user profile print
/ip hotspot user print
/ip hotspot active print
/ip hotspot host print
/ip hotspot ip-binding print
/ip hotspot walled-garden print
/ip hotspot walled-garden ip print
```

### Firewall
```
/ip firewall filter print
/ip firewall filter print stats
/ip firewall address-list print
/ip firewall nat print
/ip firewall mangle print
/ip firewall raw print
/ip firewall connection tracking print
/ip firewall service-port print
```

### Scheduler / scripts
```
/system scheduler print
/system script print
```

### DHCP
```
/ip dhcp-server print
/ip dhcp-server network print
/ip dhcp-server lease print
```

### RADIUS / AAA
```
/radius print
/user aaa print
```

### Queues
```
/queue simple print
/queue tree print
```

### Logs
```
/log print where topics~"hotspot"
/log print where topics~"firewall"
```
