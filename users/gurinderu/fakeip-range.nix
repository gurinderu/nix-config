# The fakeip pool sing-box hands out, as ONE constant imported by everyone who
# needs it:
#
#   users/gurinderu/sing-box-config.nix   dns.servers[fakeip].inet4_range
#                                         route.rules ip_cidr -> vless-main
#   hosts/mac_aarch64/sing-box.nix        the stale-cache guard in the start
#                                         script (cache.db stores fakeip
#                                         mappings; entries outside the current
#                                         range must not survive a change)
#
# HISTORY, so the next incident doesn't repeat this exact investigation:
#
# 1) Started as the full 198.18.0.0/15 (RFC 2544 benchmark space, never
#    supposed to be live on a real network).
#
# 2) d599e57 narrowed it to 198.19.0.0/16 because awdl0 (AirDrop / AirPlay /
#    Handoff) took an address out of 198.18.x — measured 2026-09-01,
#    `awdl0 inet 198.18.2.58 netmask 0xffffff00`. A connected /24 beats any TUN
#    route, so every fakeip allocated inside it went to awdl0 and the
#    connection was refused in ~2ms. Victim: whichever domain happened to land
#    there (that day, codeload.github.com at 198.18.2.108, breaking
#    `nix flake update` while github.com itself was fine).
#
# 3) That "fix" was still broken, because the premise was wrong: macOS does
#    NOT pin awdl0 to the lower half of 198.18.0.0/15. It hands out an address
#    from the WHOLE /15 — re-measured 2026-09-03, `awdl0 inet 198.19.2.0
#    netmask 0xffffff00`, i.e. inside the very /16 (2) had just carved out to
#    dodge it. Narrowing within the same /15 only relocates the collision;
#    awdl0 can and does land anywhere in it. This is why the pool is moved
#    OUT of 198.18.0.0/15 entirely rather than sliced again.
#
# 4) The premise of the move in (3) — "the failure mode is specific to
#    198.18.0.0/15" — is DEAD, measured 2026-09-05: hours into the new range,
#    `awdl0 inet 172.24.1.235 netmask 0xffff0000` — a /16 claim INSIDE
#    172.24.0.0/14, blackholing the entire bottom /16 the pool allocates
#    from first (route -n get on any fresh fakeip: interface awdl0, connect
#    fails in ~3ms; the whole post-rebuild "tunnel dead" of that evening).
#    macOS's P2P allocator collides with wherever the pool lives; three
#    collisions across two unrelated blocks make range-hopping whack-a-mole.
#    So the range STAYS 172.24.0.0/14 and the defense moved to a guard:
#    hosts/mac_aarch64/dns-fallback.nix strips any awdl*/llw* IPv4 alias
#    that lands inside this pool (and logs, without stripping, a REAL
#    network using it — the residual risk below).
#
# New range: 172.24.0.0/14 (172.24.0.0-172.27.255.255), private RFC 1918
# space, chosen instead of another RFC 2544 slice because that whole benchmark
# block is exactly what macOS reaches into for awdl0/AWDL-adjacent interfaces
# — the failure mode in (2) and (3) was thought specific to 198.18.0.0/15
# (see (4): it is not, the guard is what actually closes the class).
#
# Why 172.24.0.0/14 specifically, not another RFC 1918 corner:
#   - Not 172.16.0.0/12 broadly: 172.17.0.0/16 is Docker's own default bridge
#     range and 172.31.0.0/16 is AWS's default VPC CIDR — both are things a
#     VPN client, container runtime, or corporate network on THIS machine is
#     likely to actually use, unlike a napkin RFC1918 pick.
#   - 172.24-172.27 are the least-conventional /16s inside 172.16.0.0/12: not
#     Docker's default, not AWS's default, and clear of 172.19.0.0/30 (this
#     TUN) and 172.20.10.0/28 (iPhone hotspot).
#   - Rejected 10.224.0.0/12: bigger blast radius for no benefit here, and
#     10.20.0.0/20 (this machine's coworking network) makes the 10/8 space
#     feel closer to "somewhere a real DHCP server here might hand out an
#     address" than 172.16.0.0/12 does.
#   - Rejected "never announced" curiosities like 28.0.0.0/8 (nominally
#     DoD-assigned public space): squatting on address space that ISN'T
#     RFC1918 risks a captive portal, ISP, or misconfigured network actually
#     routing it somewhere real — RFC1918 guarantees nothing external ever
#     legitimately answers for it, which is the property that makes handing
#     it out as fakeip safe. A collision with an unrelated LAN using the same
#     RFC1918 slice (e.g. a future coworking network on 172.24/16) is the
#     accepted residual risk — same category of risk 198.18.0.0/15 always
#     had, just moved to space macOS itself doesn't hand out to interfaces.
#
# /14 gives ~256k mappings, comfortably more than the /16 (65k) it replaces.
"172.24.0.0/14"
