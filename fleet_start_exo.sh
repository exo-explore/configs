#!/usr/bin/env bash
set -euo pipefail

HOSTS_FILE="${1:-hosts.txt}"

for host in $(grep -v '^\s*#' "$HOSTS_FILE"); do
  echo "=== $host ==="
  ssh -n "$host" '
    cd /opt/exo || exit 1
    nohup nix develop . \
      --accept-flake-config \
      --extra-experimental-features "nix-command flakes" \
      --command uv run exo \
      >>/tmp/exo.log 2>>/tmp/exo.err &
    disown || true
    echo "[remote] started exo, logging to /tmp/exo.log and exo.err"
  '
done
