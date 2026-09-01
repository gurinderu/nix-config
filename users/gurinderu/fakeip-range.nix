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
# 198.19.0.0/16 rather than the whole 198.18.0.0/15 benchmark block: macOS gives
# awdl0 (AirDrop / AirPlay / Handoff) an address out of 198.18.x — measured
# 2026-09-01, `awdl0 inet 198.18.2.58 netmask 0xffffff00`. A connected /24 beats
# any TUN route, so every fakeip allocated inside it goes to awdl0 and the
# connection is refused in ~2ms. The victim domain is whichever one happens to
# land there (2026-09-01: codeload.github.com at 198.18.2.108, which broke
# `nix flake update` while github.com itself was fine) and it changes on every
# cache wipe — a failure that looks random and unreproducible until the route
# table is read.
#
# Staying inside RFC 2544 benchmark space is what makes handing out fakeip safe
# at all, so narrow rather than relocate. 65k mappings is ample.
"198.19.0.0/16"
