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

# netbird on cloud-vm

`hosts/cloud-vm/netbird.nix` puts `netbird` on PATH and writes a systemd
unit to `~/.config/systemd-system/netbird.service`; root links it in once
(home-manager can't own a system unit). sudo's `secure_path` lacks the nix
profile, so root calls need the full path (plain `sudo netbird` fails with "No
such file or directory"); non-root `netbird status` works as is:

```
sudo systemctl link ~/.config/systemd-system/netbird.service
sudo systemctl enable --now netbird
netbird status    # Daemon status: NeedsLogin
sudo ~/.nix-profile/bin/netbird up --management-url https://netbird.cloudless.dev:443 --no-browser
```

`--no-browser` prints an `https://authentik.cloudless.dev/device?code=...`
link (device code, valid 10 min; consent screen "NetBird CLI login", served by
the public authentik client `netbird-cli`). The `--management-url` on the
first `up` is required: the unit passes the same URL to `netbird service run`,
but that doesn't seed a new profile, which starts out pointing at
`api.netbird.io` (checked on 0.75.1). `up` saves the URL to
`/var/lib/netbird/default.json`, so later `up` calls can leave it out. The
session expires after 24h unless login expiration is disabled for the peer in
the dashboard; `up --setup-key <key>` is the alternative.

After a switch that changes the unit (the switch says so), reload it:

```
sudo systemctl daemon-reload && sudo systemctl restart netbird
```

State is in `/var/lib/netbird`, the log in `/var/log/netbird/client.log`
(plus `journalctl -u netbird`). Remove: `sudo systemctl disable --now netbird`,
which also drops the link.

Tailscale shares 100.64.0.0/10 (netbird peers are in 100.90.0.0/16). Its
`ts-input` chain drops any 100.64.0.0/10 source that doesn't come in on
`tailscale0`, but netbird inserts `-A INPUT -i wt0 -j ACCEPT` as the first
`INPUT` rule, ahead of the `ts-input` jump, so `wt0` traffic gets through
(checked after login). A tailscaled restart could re-order the rules; check
with `sudo iptables -S INPUT`. Don't use
`tailscale set --netfilter-mode=nodivert`: that also drops the
`ts-postrouting` masquerade this node's exit-node offer needs. Routes don't
clash: tailscale only installs /32s for its own peers (table 52), so netbird's
subnet route via `wt0` loses only on an address both meshes hand out.

# herdr-notify (Mac notifications for agents on cloud-vm)

When a Claude Code or Codex agent in cloud-vm's default herdr session finishes
or needs input, the Mac shows a Warp notification; clicking it (or switching
back to Warp) focuses that herdr pane. The Mac pulls over ssh with a dedicated,
restricted key; the VM opens no port and sends only ids, labels and the pane
title. Code: `pkgs/herdr-notify`; modules: `hosts/cloud-vm/herdr-notify.nix`,
`users/gurinderu/herdr-notify.nix`.

Bootstrap, once:

1. On the Mac, create the key (no passphrase; launchd uses it unattended, and
   the VM only lets it read the spool and focus a pane, from the Mac's tailnet
   address):

   ```
   ssh-keygen -t ed25519 -N '' -C herdr-notify@macbook -f ~/.ssh/herdr_notify_ed25519
   cat ~/.ssh/herdr_notify_ed25519.pub
   ```

2. Put that line into `macPubKey` in `hosts/cloud-vm/herdr-notify.nix`
   (replacing `null`), commit, and apply on the VM:
   `home-manager switch --flake .#cloud-vm`. That writes
   `~/.ssh/authorized_keys2` (the hand-managed `authorized_keys` is untouched).
3. On the Mac: `darwin-rebuild switch --flake .#mac_aarch64`. Check the switch
   output's BTM report for `org.nix-community.home.herdr-notify`.
4. In Warp, desktop notifications must be enabled in its settings (sound is Warp's
   setting too), and macOS must allow Warp's notifications.

Check from the Mac:

```
ssh -F /dev/null -i ~/.ssh/herdr_notify_ed25519 -o IdentitiesOnly=yes ubuntu@100.72.145.54 'stream 0'   # hello + heartbeats
tail -f ~/Library/Logs/herdr-notify.log
```

On the VM: `herdr plugin list` shows `herdr-notify`; events land in
`~/.local/state/herdr-notify/spool.jsonl` (`touch
~/.local/state/herdr-notify/debug` for a hook log in `debug.log` there).

Notifications go to the Warp tab whose `mosh-client` talks to the VM (the one
most recently typed into, if several). With no such tab they are dropped and
logged. Revoke the key: delete `~/.ssh/authorized_keys2` on the VM, or set
`macPubKey = null` and switch.
