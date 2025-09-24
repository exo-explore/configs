#!/usr/bin/env bash
set -euo pipefail

HOSTS_FILE="${1:-hosts.txt}"

for host in $(grep -v '^\s*#' "$HOSTS_FILE"); do
  echo "=== $host ==="
  ssh -n "$host" '
    pids=$(pgrep -f "uv run exo" || true)
    if [ -n "$pids" ]; then
      echo "[remote] killing: $pids"
      kill $pids || true
    else
      echo "[remote] nothing to kill"
    fi
  '
done
