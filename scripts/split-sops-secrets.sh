#!/usr/bin/env bash
# One-shot: split secrets/secrets.yaml into per-recipient files so the
# thinkpad's age key no longer decrypts the Mac-only SSH keys.
#
#   secrets/shared.yaml    sing-box VLESS credentials   gurinderu + thinkpad
#   secrets/thinkpad.yaml  CI runner + Docker Hub        gurinderu + thinkpad
#   secrets/mac.yaml       SSH keys                      gurinderu only
#
# Unused keys (anthropic_api_key, github_token_read, and the removed fabro /
# night-llm stack's four) are dropped; they stay recoverable from git history.
#
# Run on the Mac (it holds the gurinderu age key), from the repo root:
#   nix shell nixpkgs#sops nixpkgs#yq-go -c bash scripts/split-sops-secrets.sh
#
# Plaintext only ever exists in a private mktemp dir outside the repo, removed
# on exit. Values are copied, not re-generated: no key or token is rotated.
set -euo pipefail
umask 077

die() {
  echo "split-sops-secrets: $*" >&2
  exit 1
}

[ -f .sops.yaml ] && [ -f secrets/secrets.yaml ] ||
  die "run from the nix-config repo root, with secrets/secrets.yaml still present"
command -v sops >/dev/null || die "sops not on PATH (use the nix shell line above)"
yq --version 2>/dev/null | grep -q mikefarah || die "need yq-go (mikefarah) as yq"
for t in shared thinkpad mac; do
  [ ! -e "secrets/$t.yaml" ] || die "secrets/$t.yaml already exists; refusing to overwrite"
done

# sops-nix on the Mac reads the key from here (users/gurinderu/sops.nix), which
# is not where sops itself looks by default on macOS.
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"

GURINDERU=age136r67xtts44mvg8a84mkeq4pfsv47gs5jkm7xddwnzwkfq3wwvnqrmj9s6
THINKPAD=age1mzmfv3k2rw5ut0zn76y46wh7cl7x4ac6zh9mq08fpxxu23mqqdysnvwv3q

shared_keys=()
for n in 1 2 3 4 5 6 7 8; do
  for f in server server_port uuid public_key short_id server_name; do
    shared_keys+=("sing_box_vless_${n}_${f}")
  done
done
thinkpad_keys=(github_runner_token dockerhub_username dockerhub_token)
mac_keys=(ssh_ed25519 ssh_ed25519_2 ssh_rsa ssh_ed25519_pub ssh_ed25519_2_pub ssh_rsa_pub)
dropped_keys=(anthropic_api_key github_token_read night_llm_repos fabro_dev_token
  night_llm_github_token fabro_session_secret)

tmp=$(mktemp -d "${TMPDIR:-/tmp}/split-sops.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
case "$(cd "$tmp" && pwd -P)/" in
  "$(pwd -P)/"*) die "temp dir $tmp is inside the repo; set TMPDIR elsewhere" ;;
esac

sops -d secrets/secrets.yaml >"$tmp/all.yaml" ||
  die "cannot decrypt secrets/secrets.yaml (SOPS_AGE_KEY_FILE=$SOPS_AGE_KEY_FILE)"

sorted() { printf '%s\n' "$@" | sort; }

# The source must hold exactly the keys this script knows about, so a key
# added since it was written is never silently dropped.
want_all=$(sorted "${shared_keys[@]}" "${thinkpad_keys[@]}" "${mac_keys[@]}" "${dropped_keys[@]}")
have_all=$(yq 'keys | .[]' "$tmp/all.yaml" | sort)
if [ "$want_all" != "$have_all" ]; then
  echo "key set mismatch (< expected by this script, > present in secrets.yaml):" >&2
  diff <(echo "$want_all") <(echo "$have_all") >&2 || true
  die "update the key lists in this script first"
fi

# make_file <target> <recipients (space-separated)> <keys...>
make_file() {
  local t=$1 recipients=$2
  shift 2
  local list
  list=$(printf '"%s",' "$@")
  yq "pick([${list%,}])" "$tmp/all.yaml" >"$tmp/$t.yaml"

  # --filename-override makes sops pick the creation rule for the real target
  # path, so the recipients come from .sops.yaml, not from this script.
  sops -e --config .sops.yaml --filename-override "secrets/$t.yaml" \
    --input-type yaml --output-type yaml "$tmp/$t.yaml" >"$tmp/$t.enc.yaml"

  # Verify: recipients, key set and every value round-trip.
  # shellcheck disable=SC2086 # word-split the recipient list on purpose
  [ "$(yq '.sops.age[].recipient' "$tmp/$t.enc.yaml" | sort)" = "$(sorted $recipients)" ] ||
    die "secrets/$t.yaml: unexpected recipients (check .sops.yaml path_regex)"
  sops -d "$tmp/$t.enc.yaml" >"$tmp/$t.check.yaml"
  [ "$(yq 'keys | .[]' "$tmp/$t.check.yaml" | sort)" = "$(sorted "$@")" ] ||
    die "secrets/$t.yaml: key set differs after round-trip"
  [ "$(yq -o json 'sort_keys(.)' "$tmp/$t.check.yaml")" = \
    "$(yq -o json 'sort_keys(.)' "$tmp/$t.yaml")" ] ||
    die "secrets/$t.yaml: values differ after round-trip"
  echo "secrets/$t.yaml: $# keys, recipients: $recipients"
}

make_file shared "$GURINDERU $THINKPAD" "${shared_keys[@]}"
make_file thinkpad "$GURINDERU $THINKPAD" "${thinkpad_keys[@]}"
make_file mac "$GURINDERU" "${mac_keys[@]}"

# Only ciphertext enters the repo, and only after all three verified.
for t in shared thinkpad mac; do
  mv "$tmp/$t.enc.yaml" "secrets/$t.yaml"
done
git add secrets/shared.yaml secrets/thinkpad.yaml secrets/mac.yaml
git rm -q secrets/secrets.yaml

cat <<'EOF'

Done. Staged: secrets/{shared,thinkpad,mac}.yaml added, secrets/secrets.yaml removed.
Dropped (unused): anthropic_api_key github_token_read night_llm_repos
  fabro_dev_token night_llm_github_token fabro_session_secret

Next:
  git status
  nix flake check
  git commit -m "Split sops secrets per host"
  darwin-rebuild switch --flake .#mac_aarch64   # ssh keys + sing-box still render
  then switch the thinkpad (sudo nixos-rebuild switch --flake .#thinkpad-x1-gen12).
Afterwards, drop the legacy fallback in secrets/default.nix and the
secrets.yaml rule in .sops.yaml.
EOF
