#!/usr/bin/env bash
set -euo pipefail

HOSTS_FILE="${1:-hosts.txt}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"

# Read one line at a time: "<name> <target>" OR "<target>"
grep -v '^\s*#' "$HOSTS_FILE" | sed '/^\s*$/d' | \
while read -r NAME TARGET REST; do
  TARGET="${TARGET:-$NAME}"     # if only one column, use it as target
  echo "=== $TARGET ==="
  ssh -n \
    -o IdentitiesOnly=yes -i "$SSH_KEY" \
    -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes \
    "$TARGET" /usr/bin/env bash -lc '
      set -e
      EXO_DIR=/opt/exo
      LOG_DIR=$HOME/Library/Logs
      mkdir -p "$LOG_DIR"
      cd "$EXO_DIR" || exit 1
      nohup /nix/var/nix/profiles/default/bin/nix develop . \
        --accept-flake-config \
        --extra-experimental-features "nix-command flakes" \
        --command uv run exo \
        >>"$LOG_DIR/exo.log" 2>>"$LOG_DIR/exo.err" &
      disown || true
      echo "[remote] started exo, logs: $LOG_DIR/exo.log / $LOG_DIR/exo.err"
    '
done
