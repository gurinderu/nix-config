# Requirements

- Installed [nix](https://nixos.org/download/)
- Enabled [flakes](https://nixos.wiki/wiki/Flakes)


# Install

`
nix run nix-darwin --experimental-feature nix-command --experimental-feature flakes -- switch --flake .
`

# Rebuild
`
darwin-rebuild switch --flake .#mac_aarch64
`