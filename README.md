# Requirements

- Installed [nix](https://nixos.org/download/)
- Enabled [flakes](https://nixos.wiki/wiki/Flakes)

# Hosts

- `mac_aarch64` — Apple Silicon Mac (nix-darwin + home-manager).
- `thinkpad-x1-gen12` — NixOS host (CI runner pool, sing-box).
- `cloud-vm` — x86_64-linux cloud VM (standalone home-manager on Ubuntu).

# Install (macOS)

```
nix run nix-darwin --experimental-features "nix-command flakes" -- switch --flake .#mac_aarch64
```

# Rebuild

macOS:

```
darwin-rebuild switch --flake .#mac_aarch64
```

NixOS (thinkpad):

```
sudo nixos-rebuild switch --flake .#thinkpad-x1-gen12
```

Cloud VM (non-NixOS, standalone home-manager):

```
nix run home-manager/release-26.05 -- switch --flake .#cloud-vm   # first time
home-manager switch --flake .#cloud-vm
```

First time, before flakes are enabled by the profile's own nix.conf, prefix the
`nix run` with `NIX_CONFIG="experimental-features = nix-command flakes"` and add
`-b backup` so pre-existing dotfiles are moved aside instead of aborting.

Standalone home-manager can't change the login shell, so set zsh once by hand:

```
Z=$HOME/.nix-profile/bin/zsh
grep -qxF "$Z" /etc/shells || echo "$Z" | sudo tee -a /etc/shells
sudo chsh -s "$Z" "$USER"
```

Make sshd drop dead connections within ~30 s. Otherwise a dropped ssh session
lingers for hours with its zellij client still attached, and reattaching to
`main` from a new login hangs behind it:

```
printf 'ClientAliveInterval 10\nClientAliveCountMax 3\n' | sudo tee /etc/ssh/sshd_config.d/10-keepalive.conf
sudo sshd -t && sudo systemctl reload ssh
```

Accept mosh over tailscale only. Every other default stays `allow`, so the only
change is that mosh's UDP range is closed outside the tailnet:

```
sudo ufw default allow incoming
sudo ufw default allow routed
sudo ufw allow in on tailscale0 to any port 60000:61000 proto udp
sudo ufw deny 60000:61000/udp
sudo ufw --force enable
```
