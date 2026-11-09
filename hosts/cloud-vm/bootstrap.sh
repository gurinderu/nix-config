#!/usr/bin/env bash
# Set up a fresh Ubuntu VM (user with passwordless sudo) as the `cloud-vm`
# home-manager host. Idempotent: every step checks before it acts, so re-running
# is safe. Usage:
#
#   curl -fsSL https://raw.githubusercontent.com/gurinderu/nix-config/main/hosts/cloud-vm/bootstrap.sh | bash -s -- <tailscale-hostname>
#
# Without a hostname, tailscale keeps the machine's own name. See README
# "Rebuild" -> "Cloud VM" for the why behind each step.
#
# Everything runs inside main(): bash reads the whole function before it runs
# any of it, so a command that reads stdin cannot eat the rest of a piped
# script.
set -euo pipefail

REPO_URL=https://github.com/gurinderu/nix-config
REPO_DIR=$HOME/projects/nix-config
# Matches flake.nix's home-manager input.
HM_REF=home-manager/release-26.05

step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    WARNING: %s\n' "$*" >&2; }

# Downloads an installer script and runs it: run_remote_script URL CMD... --
# ARGS..., i.e. CMD... <script> ARGS... (stdin from /dev/null).
run_remote_script() {
  local url=$1 tmp cmd=()
  shift
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    cmd+=("$1")
    shift
  done
  [ $# -gt 0 ] && shift
  tmp=$(mktemp)
  curl -fsSL "$url" -o "$tmp"
  "${cmd[@]}" "$tmp" "$@" </dev/null
  rm -f "$tmp"
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

apt_install() {
  local missing=()
  local p
  for p in "$@"; do
    command -v "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  [ ${#missing[@]} -eq 0 ] && return 0
  info "apt-get install ${missing[*]}"
  sudo apt-get update -qq </dev/null
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" </dev/null
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

dns_sanity() {
  step "DNS sanity"
  if getent hosts github.com >/dev/null; then
    info "github.com resolves"
    return
  fi
  if systemctl is-active --quiet systemd-resolved; then
    # Seen on a provider whose DHCP hands out DNS=127.0.0.1.
    if printf '[Resolve]\nDNS=1.1.1.1 8.8.8.8\n' |
      write_root_file /etc/systemd/resolved.conf.d/10-upstream.conf; then
      sudo systemctl restart systemd-resolved
      info "restarted systemd-resolved"
    fi
    getent hosts github.com >/dev/null || {
      echo "github.com still does not resolve; fix DNS first" >&2
      exit 1
    }
  else
    echo "github.com does not resolve and systemd-resolved is not in use; fix DNS first" >&2
    exit 1
  fi
}

install_nix() {
  step "Nix (multi-user)"
  if [ -e /nix/var/nix/profiles/default/bin/nix ] || [ -e /etc/systemd/system/nix-daemon.service ]; then
    info "already installed"
  else
    info "running the official installer (--daemon --yes)"
    run_remote_script https://nixos.org/nix/install sh -- --daemon --yes
  fi
}

# The daemon must run from a store path root's profile keeps alive (README).
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
      *)
        echo "cannot find nix's store path from $unit ($n)" >&2
        exit 1
        ;;
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

# Without it the daemon ignores the caches from nix.settings in home.nix.
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

hm_switch() {
  step "home-manager switch (#cloud-vm)"
  if command -v home-manager >/dev/null 2>&1; then
    home-manager switch -b backup --flake "$REPO_DIR#cloud-vm" </dev/null
  else
    NIX_CONFIG="experimental-features = nix-command flakes" \
      nix run "$HM_REF" -- switch -b backup --flake "$REPO_DIR#cloud-vm" </dev/null
  fi
  load_nix_env
}

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

sshd_keepalive() {
  step "sshd keepalive"
  if printf 'ClientAliveInterval 10\nClientAliveCountMax 3\n' |
    write_root_file /etc/ssh/sshd_config.d/10-keepalive.conf; then
    sudo sshd -t
    sudo systemctl reload ssh
    info "reloaded ssh"
  fi
}

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
  apt_install ufw
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
    run_remote_script https://tailscale.com/install.sh sudo sh --
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
  info "- from the Mac, enroll osewa: osewa login ubuntu@$host --no-install --name $host"
  info "- per-account logins (gh, claude, codex, ...) and any ssh keys; cloud-vm"
  info "  has no sops secrets, so nothing here can decrypt them for you"
  info "- moshi-hook pairing (users/common/moshi-hook.nix) and the herdr-server"
  info "  cutover (README) if wanted"
  info "- optional NetBird: one-time root steps in hosts/cloud-vm/netbird.nix"
  info "Later switches: home-manager switch --flake $REPO_DIR#cloud-vm"
}

main() {
  local host=${1:-}
  if [ "$(id -u)" = 0 ]; then
    echo "run as the login user (with passwordless sudo), not root" >&2
    exit 1
  fi
  sudo -n true 2>/dev/null || {
    echo "needs passwordless sudo" >&2
    exit 1
  }
  dns_sanity
  apt_install curl git
  install_nix
  nix_root_profile
  nix_conf
  clone_repo
  hm_switch
  login_shell
  sshd_keepalive
  linger
  firewall
  tailscale_up "$host"
  summary "$host"
}

main "$@"
