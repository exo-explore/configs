#!/usr/bin/env bash
set -euo pipefail

HOSTS_FILE="${1:-hosts.txt}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"

# read each line: "<name> <target>" OR just "<target>"
grep -v '^\s*#' "$HOSTS_FILE" | sed '/^\s*$/d' | \
while read -r NAME TARGET REST; do
  TARGET="${TARGET:-$NAME}"  # if only one column, use it as target
  echo "=== $TARGET ==="

  # 1) start it (detached) and write logs to /tmp on the remote
  ssh -n \
    -o IdentitiesOnly=yes -i "$SSH_KEY" \
    -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes \
    "$TARGET" /usr/bin/env bash -s <<'REMOTE'
set -euo pipefail
EXO_DIR="/opt/exo"
LOG_OUT="/tmp/exo.log"
LOG_ERR="/tmp/exo.err"
NIX_BIN="/nix/var/nix/profiles/default/bin/nix"

mkdir -p /tmp
: > "$LOG_OUT"; : > "$LOG_ERR"

echo "[start] user=$(whoami) home=$HOME" >>"$LOG_ERR"
echo "[start] exo_dir=$EXO_DIR flake=$( [ -f "$EXO_DIR/flake.nix" ] && echo yes || echo no )" >>"$LOG_ERR"
echo "[start] nix_bin=$NIX_BIN exists=$( [ -x "$NIX_BIN" ] && echo yes || echo no )" >>"$LOG_ERR"

cd "$EXO_DIR" || { echo "[start] missing $EXO_DIR" >>"$LOG_ERR"; exit 2; }

printf "[%s] starting: nix develop . --command uv run exo\n" "$(date -u +%FT%TZ)" >>"$LOG_ERR"

nohup "$NIX_BIN" develop . \
  --accept-flake-config \
  --extra-experimental-features "nix-command flakes" \
  --command uv run exo \
  >>"$LOG_OUT" 2>>"$LOG_ERR" &

echo $! >/tmp/exo.pid 2>/dev/null || true
disown || true
REMOTE

  # 2) show immediate status + last error lines so you can see what happened
  ssh -n \
    -o IdentitiesOnly=yes -i "$SSH_KEY" \
    -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes \
    "$TARGET" /usr/bin/env bash -lc '
      echo "--- status ---"
      /usr/bin/pgrep -fl "nix develop .* --command uv run exo" || true
      /usr/bin/pgrep -fl "uv run exo" || true
      /usr/bin/pgrep -fl "python.*-m exo" || true
      echo "--- /tmp/exo.err (tail) ---"
      tail -n 40 /tmp/exo.err 2>/dev/null || echo "(no /tmp/exo.err yet)"
      echo "--- /tmp/exo.log (tail) ---"
      tail -n 20 /tmp/exo.log 2>/dev/null || echo "(no /tmp/exo.log yet)"
  '
done
