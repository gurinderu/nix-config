#!/usr/bin/env bash
# Bump pkgs/moshi-hook to upstream's newest release. The CDN drops old
# versions (v0.4.48 went 404), so a stale pin breaks every build that needs
# the package. Latest version: the newest "moshi-hook v<ver>" commit of the
# rjyo/homebrew-moshi tap; hashes: that release's checksums.txt.
set -euo pipefail
cd "$(dirname "$0")"
ver=$(curl -fsSL https://api.github.com/repos/rjyo/homebrew-moshi/commits?per_page=20 |
  grep -oE '"message": "moshi-hook v[0-9.]+' | head -1 | grep -oE '[0-9.]+$')
sums=$(curl -fsSL "https://cdn.getmoshi.app/hook/v$ver/checksums.txt")
sed -i -E "s/version = \"[0-9.]+\";/version = \"$ver\";/" default.nix
for asset in moshi-hook_Linux_x86_64 moshi-hook_Linux_arm64 \
  moshi-hook-app_Darwin_arm64 moshi-hook-app_Darwin_x86_64; do
  hex=$(awk -v a="$asset.tar.gz" '$2 == a { print $1 }' <<<"$sums")
  sri=$(nix hash convert --hash-algo sha256 --to sri "$hex")
  sed -i -E "/asset = \"$asset\.tar\.gz\";/{n;s|hash = \"[^\"]+\"|hash = \"$sri\"|}" default.nix
done
echo "moshi-hook $ver"
