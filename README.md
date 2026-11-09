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

Don't run `switch` over an SSH session that rides the thinkpad's own network
(tailscale through sing-box). When the switch stops NetworkManager or
sing-box, the ssh client times out, nixos-rebuild's piped output breaks,
switch-to-configuration exits 101 halfway, and the units it stopped are never
started again (2026-11-06). Over such a session, either stage the generation
and reboot:

```
sudo nixos-rebuild boot --flake .#thinkpad-x1-gen12 && sudo reboot
```

or run the `switch` inside tmux/zellij on the host, so it survives the drop.

Cloud VM (non-NixOS, standalone home-manager). A fresh Ubuntu VM whose login
user has passwordless sudo is set up in one go:

```
curl -fsSL https://raw.githubusercontent.com/gurinderu/nix-config/main/hosts/cloud-vm/bootstrap.sh | bash -s -- <tailscale-hostname>
```

`hosts/cloud-vm/bootstrap.sh` is idempotent (each step checks first, so it is
safe to re-run) and does, in order:

- DNS: if `github.com` doesn't resolve under systemd-resolved, adds
  `DNS=1.1.1.1 8.8.8.8` (some provider DHCP hands out `DNS=127.0.0.1`).
- Nix, multi-user (official installer, `--daemon --yes`), then the root-profile
  and `/etc/nix/nix.conf` fixes below.
- Clones this repo to `~/projects/nix-config` (or pulls) and runs the first
  switch: `NIX_CONFIG="experimental-features = nix-command flakes" nix run
  home-manager/release-26.05 -- switch -b backup --flake ...#cloud-vm` (`-b
  backup` moves pre-existing dotfiles aside instead of aborting).
- Login shell zsh from the nix profile (`/etc/shells` + `chsh`); standalone
  home-manager can't change it.
- sshd keepalive (`ClientAliveInterval 10`, `ClientAliveCountMax 3` in
  `/etc/ssh/sshd_config.d/10-keepalive.conf`), so a dropped ssh session goes
  away within ~30 s instead of lingering for hours with its herdr client still
  attached, which makes reattaching from a new login hang behind it.
- `loginctl enable-linger`, for the osewa user service.
- ufw: every default stays `allow`; mosh's UDP 60000:61000 and osewa's 7322
  (TCP+UDP) are accepted on `tailscale0` and denied elsewhere.
- Tailscale (official install script if missing), `tailscale up --ssh=false
  --hostname=<arg>` when not logged in (it prints a login URL to open), or
  `tailscale set --hostname` when it is.

Left by hand: the tailscale login click if it timed out, a re-login for zsh,
the osewa enrollment from the Mac (see osewa below), per-account logins (gh,
claude, codex, ssh keys; cloud-vm has no sops secrets) and moshi-hook
pairing.

Later switches:

```
home-manager switch --flake .#cloud-vm
```

Why the nix fixes: the nix daemon must run from a store path that root's
profile keeps alive. The `--daemon` installer here left
`/nix/var/nix/profiles/default` (-> `per-user/root/profile`) dangling and the
units in `/etc/systemd/system` pointing straight at a store path that only
user profiles held, so a GC could have deleted the running daemon's nix. The
script installs that nix into root's profile with `nix-env -p
/nix/var/nix/profiles/per-user/root/profile -i` (rather than `-p default`:
`default` is a link to it, and `nix-env -p default` would replace that link
with its own generations) and links the units from
`/nix/var/nix/profiles/default/lib/systemd/system`. To upgrade the daemon
later, `nix-env -p ... -i` a newer nix the same way and `sudo systemctl
restart nix-daemon` when no build is running.

The installer also wrote no `/etc/nix/nix.conf`. Without one the daemon
ignores the binary caches from `nix.settings` in `hosts/cloud-vm/home.nix`
("ignoring untrusted substituter", the user isn't trusted), so llm-agents and
claude get built from source. The script writes `build-users-group = nixbld`
(what the daemon used by default; keeps builds on the nixbld users), the
flakes feature and `extra-trusted-substituters` / `extra-trusted-public-keys`
for cache.numtide.com and ryoppippi.cachix.org. A cache added to
`nix.settings` later needs its URL and key in the script's `nix.conf` too.

home-manager runs `nix-collect-garbage --delete-older-than 14d` weekly
(`nix.gc` in `hosts/cloud-vm/home.nix`, `systemctl --user list-timers
nix-gc.timer`), which keeps two weeks of generations to roll back to. It only
prunes this user's profiles; root's (`/nix/var/nix/profiles/per-user/root`)
stay as they are.

# Secrets

sops-nix with age. Secrets are split by who has to read them, so the
thinkpad's key (derived from its SSH host key) cannot decrypt the Mac-only
ones:

| File                    | Holds                                    | Recipients          |
| ----------------------- | ---------------------------------------- | ------------------- |
| `secrets/shared.yaml`   | sing-box VLESS (`sing_box_vless_N_*`)    | gurinderu, thinkpad |
| `secrets/thinkpad.yaml` | `github_runner_token`, `dockerhub_*`     | gurinderu, thinkpad |
| `secrets/mac.yaml`      | SSH keys (`ssh_*`)                       | gurinderu           |

Recipients come from the `path_regex` rules in `.sops.yaml`; `gurinderu` is
the Mac's key and the admin key, so it can edit every file.
`secrets/default.nix` maps each role to its file; each host's
`defaultSopsFile` is its own file, and both sing-box modules read
`shared.yaml` explicitly. Put a new secret in the file whose recipients are
exactly the hosts that read it, e.g. `sops secrets/mac.yaml`.

# GitHub runner microVMs (thinkpad)

The warp and trading runners run in one cloud-hypervisor microVM each
(`microvm@warp-1`, `microvm@trading-1`), defined in
`hosts/thinkpad-x1-gen12/github-runner.nix` (host side) and
`github-runner-vm.nix` (guest). The guest gets the host store read-only, a
registration token minted on the host (the PAT stays there) and the Docker Hub
pull credentials, and reaches the network only through sing-box's TUN. Docker
in jobs is the runner's own rootless podman inside the VM.

Deploy with `test` first, which activates without making the generation the
boot default, so a reboot undoes it:

```
sudo nixos-rebuild test --flake .#thinkpad-x1-gen12
```

Then check, and `switch` once a job has gone green:

```
systemctl status microvm@warp-1 microvm@trading-1      # active = guest booted (vsock notify)
journalctl -u microvm@warp-1 -f                        # guest console + its journal, runner included
systemctl status ghr-token-warp-1 ghr-token-trading-1  # registration token minted?
systemctl list-timers 'ghr-token-*'
ip -br addr show | grep ghr-                           # taps up, 10.89.255.x/30
sudo iptables -S ghr-fwd; sudo iptables -t raw -S ghr-pre; sudo iptables -t nat -S ghr-nat
sudo nixos-rebuild switch --flake .#thinkpad-x1-gen12
```

Both runners should show as Idle under the repos' Settings → Actions →
Runners. `ls -l /dev/kvm` must exist on the host, and nested VMX must be on for
trading's `.#qcow` build: `cat /sys/module/kvm_intel/parameters/nested` → `Y`.

The VM state is under `/var/lib/microvms/<name>`: `var.img` (persistent caches,
podman images, runner state and logs), `tmp.img` and `nix-store.img`
(recreated empty on every VM start). To read the runner's `_diag` logs or
inspect the caches, stop the VM and mount its `/var` read-only:

```
sudo systemctl stop microvm@warp-1
sudo mount -o ro,loop,noload /var/lib/microvms/warp-1/var.img /mnt
ls /mnt/log/github-runner/warp-1/   # Runner_*.log, Worker_*.log
sudo umount /mnt && sudo systemctl start microvm@warp-1
```

`sudo systemctl restart microvm@warp-1` reboots a VM (killing a job in flight);
deleting `var.img` while it is stopped starts it from cold caches.

Rollback: `sudo reboot` after a `test` that went wrong, or after a `switch`,
`sudo nixos-rebuild switch --rollback`. The previous generation brings back
the host-side runner services and their `/var/cache/github-runner-*` caches,
which this change leaves on disk. Once the VMs have run for a while, those
can go, along with the old runner users' files:
`sudo rm -rf /var/cache/github-runner-* /var/lib/github-runner /var/log/github-runner`.

# Local agents (thinkpad)

`hosts/thinkpad-x1-gen12/local-agents.nix` runs infinity coding agents
against a local model (abliterated Qwen3.6-35B-A3B in llama.cpp on the Arc
iGPU). The daemon is `infinity-daemon.service`, running as the `agent` system
user with home `/var/lib/agent`; 0xff drives it through three commands:

```
agent-import ~/src/foo        # copy the repo's branches and tags in, as workspace "foo"
agents foo                    # infinity TUI in /var/lib/agent/work/foo
agents foo -H "task"          # headless
cd ~/src/foo && agent-fetch foo
git log -p HEAD..agent-foo/<branch>   # review, then merge/cherry-pick what you want
```

`agent-import` takes only committed state (a `git bundle` of branches and
tags): no working-tree changes, no `.git/config`, hooks or shared objects.
`agent-fetch` brings the agent's branches back the same way, as
`agent-<name>/*` remote-tracking refs, with object fsck on; your git never
opens the agent's repository, so nothing the agent writes into its
`.git/config` or hooks runs as you. Never `cd` into
`/var/lib/agent/work/<name>` and run git or a build there as yourself.
`agents` runs the CLI as the agent user through sudo (NOPASSWD for exactly
these commands, on a fresh pty), because the CLI only finds the daemon in
`$HOME/.infinity`; it refuses to start when the service is down (the CLI
would start an unconfined daemon of its own). Removing a workspace:
`sudo rm -rf /var/lib/agent/work/<name>`.

Checks:

```
systemctl status infinity-daemon llama-cpp
journalctl -u infinity-daemon -u llama-cpp -f
sudo cat /var/lib/agent/.infinity/daemon.log
sudo iptables -S agent-out; sudo iptables -S agent-reply; sudo ip6tables -S agent-out
systemd-analyze security infinity-daemon
```

What the sandbox does: the agent user owns nothing of 0xff's, and the unit
hides `/home`, `/root`, `/run/user`, devices, other users' processes, and the
tailscale/podman/libvirt/D-Bus/nix-daemon sockets and the secrets under
`/run`. Its network (iptables owner rules, `agent-out`/`agent-reply`): the
internet through sing-box, DNS, llama-server on 127.0.0.1:18101, and its own
local listeners (the daemon talks to its tool servers over loopback); not
other users' ports on this laptop, not the tailnet, the runner VMs or host
podman/libvirt networks. The LAN is open by default;
`thinkpad.localAgents.allowLan = false` closes it. With the firewall stopped,
the agent user sends nothing.

What it does not: the agent has the internet, so anything you import can
leave the machine (keep secrets out of imported repos). The kernel is shared
(a kernel bug is an escape; the runner microVMs are the stronger boundary).
Whatever it writes is untrusted code: read it before you build or run it,
especially `.envrc`, build scripts and CI files. It can read world-readable
files (`/nix/store`, `/etc`) and use CPU, RAM and disk without a cap.

# herdr server unit (cloud-vm)

`hosts/cloud-vm/herdr-server.nix` defines `herdr-server.service`, a systemd
user unit that runs `herdr server` with MemoryHigh=20G, MemoryMax=24G,
OOMPolicy=continue and Restart=on-failure, so a runaway pane gets OOM-killed
on its own instead of the global OOM killer taking down the server and every
pane (as on 2026-10-26). Until the cutover it is defined but not started
(`autostart = false` in the module): the server in use is still the one the
first `herdr` client spawned. Clients need no change; they attach to whatever
server listens on `~/.config/herdr/herdr.sock`.

Cutover, when losing the current panes is fine:

```
herdr server stop                       # ends every pane of the old server
pgrep -af 'herdr server'                # nothing left
systemctl --user start herdr-server
systemctl --user status herdr-server    # active, Memory: ... (high: 20G max: 24G)
herdr status server                     # status: running
```

Then attach as usual (mosh login or the Moshi app). To keep it across reboots,
set `autostart = true` in `hosts/cloud-vm/herdr-server.nix`, commit and
`home-manager switch --flake .#cloud-vm` (that adds it to
`default.target.wants`; the running server is left alone). `systemctl --user
enable` does not work instead: the home-manager unit file has no `[Install]`
section while `autostart` is false.

After that, a switch never restarts the unit (X-RestartIfChanged=false), so a
herdr bump runs the old binary until `systemctl --user restart herdr-server`,
which ends all panes. If a client ever starts while the unit is down, it
spawns an unmanaged server again; `systemctl --user status herdr-server` shows
which one is running.

# osewa (persistent terminals, next to mosh)

[osewa](https://github.com/rjyo/osewa) keeps the shell on the VM and reaches
it over QUIC (UDP 7322), falling back to a TLS WebSocket (TCP 7322) where UDP
is blocked. Sessions survive roaming, sleep and server restarts, and it does
port forwards and exec as well. mosh stays as it is.

- `pkgs/osewa`: upstream's release binaries repacked, one version for both
  ends (they must match). Bump with `nix run .#osewa.updateScript`, then switch
  the VM and the Mac together.
- `hosts/cloud-vm/osewa.nix`: `osewa` on PATH, `~/.local/bin/osewa` symlinked
  to it (what `ssh host cmd` finds), and the `osewa` systemd user service
  (`osewa server` from the store path, `OSEWA_AUTO_UPDATE=off`,
  `Restart=always`).
- `users/gurinderu/osewa.nix`: the client on the Mac.

Both activations run `osewa set auto-update off`: nix owns upgrades, and
osewa must never replace its own binary.

The bootstrap script (see Rebuild above) enables linger, so the user service
runs without a login session, and accepts 7322 (TCP+UDP) on `tailscale0` only,
denying it elsewhere. tailscale0 is already accepted ahead of ufw
(`ts-input`), so the deny rules are what matters: they close 7322 on the
public interface.

Enroll the Mac, once (after both switches):

```
osewa login ubuntu@cloud-vm-1 --no-install --name cloud-vm-1
```

`--no-install` is required. It makes `login` run only `osewa enroll && osewa
server --daemon` over ssh: enroll adds the Mac's key to `~/.config/osewa/devices`
on the VM, and `server --daemon` sees the service already running and leaves
it alone. Ignore the hint `login` prints afterwards ("won't come back after
... reboots; ... --service"): the systemd unit and linger take care of that.
Don't use plain `login` (it copies a binary to `~/.local/bin/osewa`), `login
--service` (it writes its own unit over home-manager's), or `osewa update
cloud-vm-1`. Each of them replaces a file nix owns. The server address saved
on the Mac is the ssh target's host (`cloud-vm-1`, tailscale MagicDNS) with
port 7322. Keys and hosts are in `~/.config/osewa` on both ends.

Use from the Mac:

```
osewa attach cloud-vm-1       # attach to a session (or create one): zsh -l
osewa attach cloud-vm-1 <id>  # a given one; ~. detaches
osewa new cloud-vm-1 -- /home/ubuntu/.nix-profile/bin/herdr   # a session running herdr
osewa ls cloud-vm-1
osewa exec cloud-vm-1 --env PATH=/home/ubuntu/.nix-profile/bin:/usr/bin:/bin \
  -- zsh -lc 'git -C ~/projects/nix-config status'
osewa forward cloud-vm-1 3000
```

`exec` and `new <host> -- cmd` look the command up in osewa's own fixed PATH
(`/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`), which holds no nix tools,
zsh included. It is built per session, not taken from the server, so no
setting in the unit can change it. Pass a PATH with `exec --env` (the client's
entries win) or give `new` an absolute path. Plain `attach` / `new` run the
passwd shell by its absolute path as `zsh -l`, which sets the usual PATH.

osewa sessions have no `SSH_CONNECTION` and no `mosh-server` parent, so
neither the ssh nor the mosh herdr auto-attach runs in them.

On the VM: `systemctl --user status osewa`, `journalctl --user -u osewa`,
`ss -lunpt | grep 7322`. A switch that changes the unit restarts the server.
Sessions survive that (`KillMode=process`), but only between builds that speak
the same protocol and snapshot version (`osewa version --json`).
