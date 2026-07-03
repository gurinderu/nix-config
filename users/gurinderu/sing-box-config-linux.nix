# Linux/NixOS-specific sing-box config: fills the platform holes in
# ./sing-box-config.nix. Imported by hosts/thinkpad-x1-gen12/sing-box.nix.
import ./sing-box-config.nix {
  # On Linux the Tailscale daemon process is `tailscaled`.
  tailscaleProcs = [ "tailscaled" ];

  # Podman's default bridge. Without this the TUN swallows container traffic
  # (10.88.x.x and its DNAT'd published ports), so the CI runner's tests can't
  # reach their own Testcontainers Postgres and fail/leak. Keep it off the VPN.
  extraTunExcludes = [ "10.88.0.0/16" ];

  # strict_route enforces routing on Linux (unsupported networks become
  # unreachable), preventing leaks around the TUN.
  tunExtra = {
    strict_route = true;
  };

  # Persist the fakeip table across restarts. Lives under StateDirectory
  # (/var/lib/sing-box, created by the systemd unit), the canonical writable
  # state dir for a root system service.
  cacheFilePath = "/var/lib/sing-box/cache.db";
}
