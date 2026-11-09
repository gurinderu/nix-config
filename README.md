# nix-config

Nix flake for my machines: nix-darwin on the Mac, NixOS on the thinkpad,
standalone home-manager on Ubuntu cloud VMs.

| Host                | Machine                         | Flake attr                                  |
| ------------------- | ------------------------------- | ------------------------------------------- |
| `mac_aarch64`       | Apple Silicon Mac               | `darwinConfigurations.mac_aarch64`          |
| `thinkpad-x1-gen12` | ThinkPad X1 Gen 12              | `nixosConfigurations.thinkpad-x1-gen12`     |
| `cloud-vm`          | x86_64 Ubuntu VM (cloud-vm-\*)  | `homeConfigurations.cloud-vm`               |
|                     | its root side (system-manager)  | `systemConfigs.cloud-vm{,-netbird}`         |

# Install

Nix is assumed installed; flakes need not be enabled yet.

Mac (needs the sops age key at `~/.config/sops/age/keys.txt` first):

```
sudo nix --extra-experimental-features 'nix-command flakes' run github:nix-darwin/nix-darwin/nix-darwin-26.05#darwin-rebuild -- switch --flake github:gurinderu/nix-config#mac_aarch64
```

Thinkpad (NixOS; `hardware-configuration.nix` is in the repo, and sops
decrypts with the SSH host key, so a new host key must be added to
`.sops.yaml` and the secrets re-encrypted):

```
sudo NIX_CONFIG='experimental-features = nix-command flakes' nixos-rebuild switch --flake github:gurinderu/nix-config#thinkpad-x1-gen12
```

Cloud VM (login user with passwordless sudo):

```
nix --extra-experimental-features 'nix-command flakes' run github:gurinderu/nix-config#bootstrap -- [--netbird] <tailscale-hostname>
```

The bootstrap (`hosts/cloud-vm/bootstrap.sh`, idempotent) roots the nix daemon
in root's profile, writes `/etc/nix/nix.conf` (trusted caches), makes the sops age key, clones
this repo to `~/projects/nix-config`, runs the first
home-manager switch, installs apt `uidmap` (rootless podman), runs the
system-manager switch (`systemConfigs.cloud-vm`, or `cloud-vm-netbird` with
`--netbird` or when NetBird already runs; it also brings up tailscaled from
nixpkgs, no apt repo), sets zsh as login shell, sshd keepalive, linger, ufw
(mosh and osewa on `tailscale0` only) and `tailscale up`, then prints what is
left by hand (osewa enroll from the Mac, per-account logins). Tailscale needs
no browser: it joins as `tag:cloud-vm` with the OAuth client secret
`tailscale_oauth` from `secrets/cloud-vm.yaml`. A new VM's age key is not a
recipient yet, so the first run prints the key and how to add it (`.sops.yaml`,
`sops updatekeys secrets/cloud-vm.yaml` on the Mac, push) and stops; re-run it
then. `--interactive-login` uses the browser login instead.

On a bare VM, install Nix first:
`sh <(curl -L https://nixos.org/nix/install) --daemon --yes`, then open a new
shell. If the provider's DHCP breaks DNS (`DNS=127.0.0.1`), fix it before
that:

```
sudo mkdir -p /etc/systemd/resolved.conf.d && printf '[Resolve]\nDNS=1.1.1.1 8.8.8.8\n' | sudo tee /etc/systemd/resolved.conf.d/10-upstream.conf && sudo systemctl restart systemd-resolved
```

# Rebuild

From the checkout:

```
sudo darwin-rebuild switch --flake .#mac_aarch64
sudo nixos-rebuild switch --flake .#thinkpad-x1-gen12
home-manager switch --flake .#cloud-vm
nix run .#system-manager -- switch --flake .#cloud-vm --sudo   # cloud-vm-netbird on cloud-vm-1
```

system-manager's `activate` can exit 0 with a unit failed: check
`systemctl --failed` after a switch. A switch that changes tailscaled's unit restarts
it, which blips ssh/mosh over tailscale; on cloud-vm-1 lo-accept then puts
netbird's wt0 accept back above tailscale's ts-input jump
(`hosts/cloud-vm/system/lo-accept.nix`).

Over SSH riding the thinkpad's own network (tailscale through sing-box), a
`switch` can drop the session halfway: use `sudo nixos-rebuild boot --flake
.#thinkpad-x1-gen12 && sudo reboot`, or run it inside tmux.

# Secrets

sops-nix with age, one file per recipient set (rules in `.sops.yaml`, the
role-to-file map in `secrets/default.nix`):

| File                    | Holds                                 | Recipients                        |
| ----------------------- | ------------------------------------- | --------------------------------- |
| `secrets/shared.yaml`   | sing-box VLESS (`sing_box_vless_N_*`) | gurinderu, thinkpad               |
| `secrets/thinkpad.yaml` | `github_runner_token`, `dockerhub_*`  | gurinderu, thinkpad               |
| `secrets/mac.yaml`      | SSH keys (`ssh_*`)                    | gurinderu                         |
| `secrets/cloud-vm.yaml` | Fluence mesh root CA (`mesh_root_ca`) | gurinderu, cloud-vm-1, cloud-vm-2 |

`gurinderu` (the Mac's key) is the admin key and can edit every file:
`sops secrets/mac.yaml`. Put a new secret in the file whose recipients are
exactly the hosts that read it. Each cloud VM decrypts with its own age key
(`~/.config/sops/age/keys.txt`, made by the bootstrap, which prints the public
key): add a new VM's key to `.sops.yaml` and run `sops updatekeys
secrets/cloud-vm.yaml`. Until then its switch only warns.
