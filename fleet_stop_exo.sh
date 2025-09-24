#!/usr/bin/env bash
set -euo pipefail

HOSTS_FILE="${1:-hosts.txt}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"

# Read one line at a time: "<name> <target>" OR just "<target>"
grep -v '^\s*#' "$HOSTS_FILE" | sed '/^\s*$/d' | \
while read -r NAME TARGET REST; do
  TARGET="${TARGET:-$NAME}"   # fallback to first field if only one column
  echo "=== $TARGET ==="
  ssh -n \
    -o IdentitiesOnly=yes -i "$SSH_KEY" \
    -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes \
    "$TARGET" /usr/bin/env bash -lc '
      set -euo pipefail
      # Kill any process whose command line contains "exo"
      # (BSD pkill is available on macOS)
      if /usr/bin/pgrep -f "exo" >/dev/null 2>&1; then
        /usr/bin/pkill -f -9 "exo" || true
        echo "[remote] killed processes matching: exo"
      else
        echo "[remote] nothing to kill"
      fi
    '
done
