# Body of `nix run github:gurinderu/nix-config#bootstrap -- [--netbird] [tailscale-hostname]`
# (packaged by ./bootstrap.nix with writeShellApplication, which adds the
# shebang, `set -euo pipefail`, PATH for the pinned tools, HOME_MANAGER and
# SYSTEM_MANAGER).
# Sets up a fresh Ubuntu VM, whose login user has passwordless sudo and Nix
# (multi-user) already installed, as the `cloud-vm` home-manager host.
# Idempotent: every step checks before it acts, so re-running is safe.

# Host tools (sudo, systemctl, apt-get, ufw, chsh, loginctl, sshd, tailscale)
# come from the distro; keep its dirs on PATH after the pinned ones.
PATH=$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
USER=${USER:-$(id -un)}

REPO_URL=https://github.com/gurinderu/nix-config
REPO_DIR=$HOME/projects/nix-config

usage() {
  cat <<'EOF'
Usage: bootstrap [--netbird] [tailscale-hostname]

Sets up this Ubuntu VM as the cloud-vm host: nix-daemon from root's profile,
/etc/nix/nix.conf, ~/projects/nix-config checkout, first home-manager
switch, apt uidmap (rootless podman), system-manager switch, zsh login shell,
sshd keepalive, linger, ufw, tailscale.
Run as the login user with passwordless sudo, after installing Nix.
Without a hostname, tailscale keeps the machine's own name.

--netbird  apply systemConfigs.cloud-vm-netbird (adds the NetBird daemon)
           instead of the base systemConfigs.cloud-vm. A VM that already
           runs netbird.service keeps the netbird config without the flag.
EOF
}

step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    WARNING: %s\n' "$*" >&2; }
die() {
  echo "$*" >&2
  exit 1
}

# Writes stdin to a root-owned file only when the content differs.
# Returns 0 when it wrote, 1 when the file was already up to date.
write_root_file() {
  local dst=$1 tmp
  tmp=$(mktemp)
  cat >"$tmp"
  if sudo cmp -s "$tmp" "$dst" 2>/dev/null; then
    rm -f "$tmp"
    info "$dst already up to date"
    return 1
  fi
  sudo mkdir -p "$(dirname "$dst")"
  sudo install -m 644 "$tmp" "$dst"
  rm -f "$tmp"
  info "wrote $dst"
}

load_nix_env() {
  local f=/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  if [ -e "$f" ]; then
    set +u
    # shellcheck source=/dev/null
    . "$f"
    set -u
  fi
  case ":$PATH:" in
    *":$HOME/.nix-profile/bin:"*) ;;
    *) PATH=$HOME/.nix-profile/bin:$PATH ;;
  esac
  export PATH
}

# The installer leaves the daemon units pointing at a store path only user
# profiles hold (a GC could delete the running daemon's nix): install that nix
# into root's profile (-p per-user/root/profile, which `default` links to) and
# link the units from there. Upgrade later the same way.
nix_root_profile() {
  step "nix-daemon from root's default profile"
  local d=/nix/var/nix/profiles/default/lib/systemd/system
  local unit=/etc/systemd/system/nix-daemon.service
  local sock=/etc/systemd/system/nix-daemon.socket
  local wants=/etc/systemd/system/sockets.target.wants/nix-daemon.socket
  if [ ! -e "$d/nix-daemon.service" ]; then
    local n
    n=$(readlink -f "$unit" | sed 's|/lib/systemd/.*||')
    case $n in
      /nix/store/*) ;;
      *) die "cannot find nix's store path from $unit ($n); is Nix installed (--daemon)?" ;;
    esac
    info "installing $n into root's profile"
    sudo "$n/bin/nix-env" -p /nix/var/nix/profiles/per-user/root/profile -i "$n" </dev/null
  else
    info "root's default profile has nix"
  fi
  local changed=0
  if [ "$(readlink "$unit")" != "$d/nix-daemon.service" ]; then
    sudo ln -sfn "$d/nix-daemon.service" "$unit"
    changed=1
  fi
  if [ "$(readlink "$sock")" != "$d/nix-daemon.socket" ]; then
    sudo ln -sfn "$d/nix-daemon.socket" "$sock"
    changed=1
  fi
  if [ "$(readlink "$wants")" != "$sock" ]; then
    sudo mkdir -p "$(dirname "$wants")"
    sudo ln -sfn "$sock" "$wants"
    changed=1
  fi
  if [ $changed = 1 ]; then
    info "pointed the units at $d"
    sudo systemctl daemon-reload
    sudo systemctl restart nix-daemon.socket nix-daemon.service
  else
    info "units already point there"
  fi
}

# Without it the daemon ignores the caches from nix.settings in home.nix (the
# user isn't trusted). A cache added there needs its URL and key here too.
nix_conf() {
  step "/etc/nix/nix.conf"
  sudo mkdir -p /etc/nix
  sudo chmod 755 /etc/nix
  if sudo test -e /etc/nix/nix.conf && ! sudo test -e /etc/nix/nix.conf.bootstrap-bak; then
    sudo cp -a /etc/nix/nix.conf /etc/nix/nix.conf.bootstrap-bak
  fi
  if write_root_file /etc/nix/nix.conf <<'NIXCONF'; then
build-users-group = nixbld
experimental-features = nix-command flakes
extra-trusted-substituters = https://cache.numtide.com https://ryoppippi.cachix.org
extra-trusted-public-keys = niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g= ryoppippi.cachix.org-1:b2LbtWNvJeL/qb1B6TYOMK+apaCps4SCbzlPRfSQIms=
NIXCONF
    sudo systemctl restart nix-daemon
    info "restarted nix-daemon"
  fi
  load_nix_env
  nix store info </dev/null | sed 's/^/    /' || warn "nix store info failed"
}

clone_repo() {
  step "nix-config checkout"
  if [ -d "$REPO_DIR/.git" ]; then
    info "pulling $REPO_DIR"
    git -C "$REPO_DIR" pull --ff-only </dev/null ||
      warn "pull failed (local changes?); switching the checkout as it is"
  else
    mkdir -p "$(dirname "$REPO_DIR")"
    git clone "$REPO_URL" "$REPO_DIR" </dev/null
  fi
}

# This VM's sops age key (hosts/cloud-vm/mesh-ca.nix). Never overwritten. Until
# its public key is a recipient of secrets/cloud-vm.yaml, the switch only warns
# that sops-nix could not decrypt, and the mesh CA step skips.
AGE_PUB=
age_key() {
  step "sops age key"
  local k=$HOME/.config/sops/age/keys.txt
  if [ -e "$k" ]; then
    info "$k exists"
  else
    mkdir -p "$(dirname "$k")"
    chmod 700 "$(dirname "$k")"
    (umask 077 && age-keygen -o "$k" 2>/dev/null)
    info "created $k"
  fi
  chmod 600 "$k"
  AGE_PUB=$(age-keygen -y "$k")
  info "public key: $AGE_PUB"
}

# -b backup moves pre-existing dotfiles aside instead of aborting.
hm_switch() {
  step "home-manager switch (#cloud-vm)"
  "$HOME_MANAGER" switch -b backup --flake "$REPO_DIR#cloud-vm" </dev/null
  load_nix_env
}

# setuid newuidmap/newgidmap for rootless podman (hosts/cloud-vm/podman.nix);
# nix cannot install setuid binaries on this host.
uidmap_pkg() {
  step "apt uidmap (rootless podman)"
  if [ -u /usr/bin/newuidmap ] && [ -u /usr/bin/newgidmap ]; then
    info "already installed"
  else
    sudo apt-get update -qq </dev/null
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq uidmap </dev/null
    info "installed"
  fi
  if ! grep -q "^$USER:" /etc/subuid || ! grep -q "^$USER:" /etc/subgid; then
    warn "$USER has no /etc/subuid or /etc/subgid range; rootless podman needs one"
  fi
}

# Units from before system-manager: home-manager wrote them to
# ~/.config/systemd-system and root linked them by hand. Unlink them so
# system-manager can own the names. A running unit keeps running (no stop),
# and the switch right after takes it over without a restart.
LEGACY_UNITS=(netbird.service lo-accept.service mesh-ca.service mesh-ca.path)
legacy_units() {
  local u found=0
  for u in "${LEGACY_UNITS[@]}"; do
    case $(readlink "/etc/systemd/system/$u" 2>/dev/null) in
      "$HOME"/.config/systemd-system/*)
        found=1
        sudo systemctl disable "$u"
        [ ! -L "/etc/systemd/system/$u" ] || sudo rm -f "/etc/systemd/system/$u"
        ;;
    esac
  done
  if [ $found = 1 ]; then
    sudo systemctl daemon-reload
    info "unlinked the hand-linked units"
  fi
}

# Root side (hosts/cloud-vm/system): systemConfigs.cloud-vm, or
# cloud-vm-netbird with --netbird or on a VM already running netbird.service
# (re-running without the flag must not drop the daemon).
SM_CONFIG=cloud-vm
sm_switch() {
  if [ "$(systemctl show netbird -p ActiveState --value 2>/dev/null)" = active ]; then
    SM_CONFIG=cloud-vm-netbird
  fi
  step "system-manager switch (#$SM_CONFIG)"
  legacy_units
  "$SYSTEM_MANAGER" switch --flake "$REPO_DIR#$SM_CONFIG" --sudo </dev/null
  rm -f "${LEGACY_UNITS[@]/#/$HOME/.config/systemd-system/}"
  rmdir "$HOME/.config/systemd-system" 2>/dev/null || true
  # activate can exit 0 with a unit failed (system-manager#581).
  local failed
  failed=$(systemctl --failed --no-legend --plain | sed 's/ .*//')
  [ -z "$failed" ] || warn "failed units: $failed (systemctl status <unit>)"
}

# Standalone home-manager can't change the login shell.
login_shell() {
  step "login shell zsh"
  local z=$HOME/.nix-profile/bin/zsh
  [ -x "$z" ] || {
    warn "$z missing; skipping"
    return
  }
  if ! grep -qxF "$z" /etc/shells; then
    echo "$z" | sudo tee -a /etc/shells >/dev/null
    info "added $z to /etc/shells"
  fi
  if [ "$(getent passwd "$USER" | cut -d: -f7)" != "$z" ]; then
    sudo chsh -s "$z" "$USER"
    info "login shell is now $z (takes effect on the next login)"
  else
    info "already $z"
  fi
}

# A dropped ssh session goes away within ~30 s instead of lingering with its
# herdr client attached (which makes reattaching hang behind it).
sshd_keepalive() {
  step "sshd keepalive"
  if printf 'ClientAliveInterval 10\nClientAliveCountMax 3\n' |
    write_root_file /etc/ssh/sshd_config.d/10-keepalive.conf; then
    sudo sshd -t
    sudo systemctl reload ssh
    info "reloaded ssh"
  fi
}

# For the osewa user service.
linger() {
  step "linger for $USER"
  if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" = yes ]; then
    info "already enabled"
  else
    sudo loginctl enable-linger "$USER"
    info "enabled"
  fi
}

# mosh and osewa only over tailscale; every other default stays allow.
firewall() {
  step "ufw (mosh 60000:61000/udp, osewa 7322 over tailscale0 only)"
  if ! command -v ufw >/dev/null 2>&1; then
    info "apt-get install ufw"
    sudo apt-get update -qq </dev/null
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw </dev/null
  fi
  sudo ufw default allow incoming >/dev/null
  sudo ufw default allow routed >/dev/null
  sudo ufw allow in on tailscale0 to any port 60000:61000 proto udp >/dev/null
  sudo ufw deny 60000:61000/udp >/dev/null
  sudo ufw allow in on tailscale0 to any port 7322 proto tcp >/dev/null
  sudo ufw allow in on tailscale0 to any port 7322 proto udp >/dev/null
  sudo ufw deny 7322/tcp >/dev/null
  sudo ufw deny 7322/udp >/dev/null
  if sudo ufw status | grep -q '^Status: active'; then
    info "ufw active"
  else
    sudo ufw --force enable >/dev/null
    info "ufw enabled"
  fi
}

TS_STATE=unknown
tailscale_up() {
  local host=$1
  step "tailscale"
  if ! command -v tailscale >/dev/null 2>&1; then
    info "installing via tailscale.com/install.sh"
    local tmp
    tmp=$(mktemp)
    curl -fsSL https://tailscale.com/install.sh -o "$tmp"
    sudo sh "$tmp" </dev/null
    rm -f "$tmp"
  fi
  if tailscale status >/dev/null 2>&1; then
    info "already logged in"
    if [ -n "$host" ]; then
      sudo tailscale set --hostname="$host" </dev/null
      info "hostname set to $host"
    fi
    TS_STATE=up
    return
  fi
  local args=(--ssh=false --timeout=10m)
  [ -n "$host" ] && args+=("--hostname=$host")
  info "open the login URL below to add this machine (waits up to 10 min)"
  if sudo tailscale up "${args[@]}" </dev/null; then
    TS_STATE=up
  else
    warn "tailscale up did not finish; re-run: sudo tailscale up ${args[*]}"
    TS_STATE=pending
  fi
}

summary() {
  local host=${1:-<tailscale-name>}
  step "Done. Left to do by hand:"
  [ "$TS_STATE" = up ] || info "- finish the tailscale login: sudo tailscale up --ssh=false${1:+ --hostname=$1}"
  info "- log out and back in for the zsh login shell"
  info "- on the Mac, enroll osewa: osewa login ubuntu@$host --no-install --name $host"
  info "- sops: if new, add $AGE_PUB to .sops.yaml, run"
  info "  sops updatekeys secrets/cloud-vm.yaml, push, pull here and switch"
  info "- per-account logins (gh, claude, codex, ...) and ssh keys"
  info "- moshi-hook pairing (users/common/moshi-hook.nix)"
  info "- herdr unit, when losing panes is fine: herdr server stop && systemctl --user start herdr-server"
  info "  (then autostart = true in hosts/cloud-vm/herdr-server.nix)"
  if [ "$SM_CONFIG" = cloud-vm-netbird ]; then
    info "- NetBird login if new: see hosts/cloud-vm/system/netbird.nix"
  else
    info "- optional NetBird: re-run with --netbird, then log in (hosts/cloud-vm/system/netbird.nix)"
  fi
  info "Later switches: home-manager switch --flake $REPO_DIR#cloud-vm"
  info "  and: nix run $REPO_DIR#system-manager -- switch --flake $REPO_DIR#$SM_CONFIG --sudo"
}

main() {
  while [ $# -gt 0 ]; do
    case $1 in
      -h | --help)
        usage
        return
        ;;
      --netbird)
        SM_CONFIG=cloud-vm-netbird
        shift
        ;;
      -*) die "unknown option $1 (see --help)" ;;
      *) break ;;
    esac
  done
  local host=${1:-}
  [ "$(id -u)" != 0 ] || die "run as the login user (with passwordless sudo), not root"
  sudo -n true 2>/dev/null || die "needs passwordless sudo"
  nix_root_profile
  nix_conf
  clone_repo
  age_key
  hm_switch
  uidmap_pkg
  sm_switch
  login_shell
  sshd_keepalive
  linger
  firewall
  tailscale_up "$host"
  summary "$host"
}

main "$@"
