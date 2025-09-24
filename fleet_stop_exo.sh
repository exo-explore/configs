#!/usr/bin/env bash
set -euo pipefail

HOSTS_FILE="${1:-hosts.txt}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"

# Read one line at a time: "<name> <target>" OR just "<target>"
grep -v '^\s*#' "$HOSTS_FILE" | sed '/^\s*$/d' | \
while read -r NAME TARGET REST; do
  TARGET="${TARGET:-$NAME}"   # if no 2nd column, use the first
  echo "=== $TARGET ==="
  ssh -n \
    -o IdentitiesOnly=yes -i "$SSH_KEY" \
    -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes \
    "$TARGET" /usr/bin/env bash -s <<'REMOTE'
set -euo pipefail

if /usr/bin/pgrep -f "exo" >/dev/null 2>&1; then
  echo "[remote] killing exo processes..."
  /usr/bin/pkill -9 -f "exo" || true
else
  echo "[remote] nothing to kill"
fi
REMOTE
done
