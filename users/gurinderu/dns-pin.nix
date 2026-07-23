# The address the Mac's system DNS is pinned to, and the address sing-box's DNS
# listener binds. ONE constant, imported by both sides, because a mismatch does
# not degrade — it takes DNS out entirely:
#
#   hosts/mac_aarch64/configuration.nix       networking.dns  (what macOS asks)
#   users/gurinderu/sing-box-config-darwin.nix  dnsListen     (who answers)
#   hosts/mac_aarch64/sing-box.nix            the en0 alias it is bound to
#
# 192.0.2.0/24 is TEST-NET-1 (RFC 5737): reserved for documentation and
# guaranteed never to be routed or assigned on a real network, so the alias
# cannot collide with any Wi-Fi you join — including the coworking 10.20.0.0/20
# and an iPhone hotspot's 172.20.10.0/24. .53 is a mnemonic for the port.
#
# Why an alias on the physical interface rather than the TUN address or a
# loopback one: macOS derives an INTERFACE-SCOPED resolver from networking.dns,
# and a scoped query carries IP_BOUND_IF, so it ignores the route table. Only an
# address that the bound interface itself owns gets delivered locally; anything
# else (a utun address, 127.0.0.1) is flung at the default gateway and dies. See
# the long comment in hosts/mac_aarch64/configuration.nix for the full story.
"192.0.2.53"
