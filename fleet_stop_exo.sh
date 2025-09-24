#!/usr/bin/env bash
set -euo pipefail

HOSTS_FILE="${1:-hosts.txt}"

# read each line: "<name> <target>" OR just "<target>"
grep -v '^\s*#' "$HOSTS_FILE" | sed '/^\s*$/d' | \
while read -r NAME TARGET REST; do
  TARGET="${TARGET:-$NAME}"   # if no 2nd column, use the first
  echo "=== $TARGET ==="
  ssh -n "$TARGET" '
    pids=$(pgrep -f "exo" || true)
    if [ -n "$pids" ]; then
      echo "[remote] killing: $pids"
      kill -9 $pids || true
    else
      echo "[remote] nothing to kill"
    fi
  '
done
