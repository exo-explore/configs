#!/usr/bin/env bash
set -euo pipefail

HOSTS_FILE="${1:-hosts.txt}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"

# Emit exactly one SSH target per line: second column if present, else first
awk 'NF && $1 !~ /^#/ { print (NF==1 ? $1 : $2) }' "$HOSTS_FILE" |
# read targets line-by-line; strip any trailing \r (Windows line endings)
while IFS= read -r TARGET; do
  TARGET="${TARGET%$'\r'}"
  echo "=== $TARGET ==="
  ssh -n \
    -o IdentitiesOnly=yes -i "$SSH_KEY" \
    -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes \
    "$TARGET" /usr/bin/env bash -s <<'REMOTE'
set -euo pipefail
# If anything matching "exo" is running, kill it (macOS/BSD pkill syntax)
if /usr/bin/pgrep -f "exo" >/dev/null 2>&1; then
  echo "[remote] killing processes matching: exo"
  /usr/bin/pkill -9 -f "exo" || true
else
  echo "[remote] nothing to kill"
fi
REMOTE
done
