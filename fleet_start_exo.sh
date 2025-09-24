#!/usr/bin/env bash
set -euo pipefail

for host in $(grep -v '^\s*#' "${1:-hosts.txt}"); do
  echo "=== $host ==="
  ssh -tt "$host" '
    set -e
    cd /opt/exo
    /nix/var/nix/profiles/default/bin/nix develop . \
      --accept-flake-config \
      --extra-experimental-features "nix-command flakes" \
      --command uv run exo
  '
done
