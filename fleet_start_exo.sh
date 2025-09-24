#!/usr/bin/env bash
set -euo pipefail

HOSTS_FILE="${1:-hosts.txt}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"

# Read one line at a time: "<name> <target>" OR just "<target>"
grep -v '^\s*#' "$HOSTS_FILE" | sed '/^\s*$/d' | \
while read -r NAME TARGET REST; do
  TARGET="${TARGET:-$NAME}"  # if only one column, use it as target
  echo "=== $TARGET ==="
  ssh -n \
    -o IdentitiesOnly=yes -i "$SSH_KEY" \
    -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes \
    "$TARGET" /usr/bin/env bash -s <<'REMOTE'
set -euo pipefail

cd /opt/exo || exit 1

# Write to /tmp to avoid any perms quirks
LOG_OUT="/tmp/exo.log"
LOG_ERR="/tmp/exo.err"

# Mark the start
printf "[%s] starting: nix develop . --command uv run exo\n" "$(date -u +%FT%TZ)" >>"$LOG_ERR"

# Absolute nix path avoids PATH surprises on non-interactive shells
NIX_BIN="/nix/var/nix/profiles/default/bin/nix"

nohup "$NIX_BIN" develop . \
  --accept-flake-config \
  --extra-experimental-features "nix-command flakes" \
  --command uv run exo \
  >>"$LOG_OUT" 2>>"$LOG_ERR" &

echo "[remote] started exo, logs: $LOG_OUT / $LOG_ERR"
REMOTE
done
