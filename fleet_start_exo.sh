#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./ops/fleet_start_exo.sh [hosts_file]
#
# hosts.txt lines:
#   "<flake-attr>  <ssh-target>"   OR   "<name>" (used for both)
#
# This script:
#   - SSHes to each host
#   - ensures /opt/exo and ~/Library/Logs exist
#   - cd /opt/exo
#   - runs: nix develop . --accept-flake-config --extra-experimental-features "nix-command flakes" --command uv run exo
#   - starts it in the background with nohup, logs to ~/Library/Logs/exo.{log,err}
#   - writes a PID file at /tmp/exo.pid on the remote host
#
# Helpful admin actions (per host; run manually over ssh if needed):
#   - Stop:   'test -f /tmp/exo.pid && kill "$(cat /tmp/exo.pid)" || true'
#   - Status: 'ps -p "$(cat /tmp/exo.pid 2>/dev/null || echo 0)" -o pid,etime,cmd='
#   - Logs:   'tail -n 200 -f ~/Library/Logs/exo.log ~/Library/Logs/exo.err'

HOSTS_FILE="${1:-ops/hosts.txt}"

[[ -f "$HOSTS_FILE" ]] || { echo "ERROR: hosts file not found: $HOSTS_FILE" >&2; exit 1; }

# Normalize hosts into two columns: <attr> <target>
norm_list="$(mktemp)"
awk '
  NF==0 || $1 ~ /^#/ { next }
  NF==1 { printf "%s %s\n", $1, $1; next }
  { printf "%s %s\n", $1, $2 }
' "$HOSTS_FILE" > "$norm_list"

# Pre-seed known_hosts (strip user@ if present)
mkdir -p ~/.ssh; touch ~/.ssh/known_hosts
awk '{print $2}' "$norm_list" | while read -r tgt; do
  [[ -z "$tgt" ]] && continue
  host="$tgt"; [[ "$host" == *@* ]] && host="${host#*@}"
  ssh-keyscan -T 5 -H "$host" 2>/dev/null >> ~/.ssh/known_hosts || true
done

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes -o ServerAliveInterval=10 -o ServerAliveCountMax=3)

echo "==> Starting exo on fleet (remote background via nohup)"
while read -r _ target; do
  [[ -z "$target" ]] && continue
  echo "---- $target"
  ssh -n "${SSH_OPTS[@]}" "$target" /usr/bin/env bash -lc '
    set -euo pipefail

    # Paths
    EXO_DIR="/opt/exo"
    LOG_DIR="$HOME/Library/Logs"
    LOG_OUT="$LOG_DIR/exo.log"
    LOG_ERR="$LOG_DIR/exo.err"
    PID_FILE="/tmp/exo.pid"

    # Ensure dirs & logs
    mkdir -p "$EXO_DIR" "$LOG_DIR"
    : > "$LOG_OUT"
    : > "$LOG_ERR"

    # If already running, stop it first (best-effort)
    if [[ -f "$PID_FILE" ]]; then
      old_pid="$(cat "$PID_FILE" || true)"
      if [[ -n "${old_pid:-}" ]] && ps -p "$old_pid" >/dev/null 2>&1; then
        echo "[remote] stopping existing exo (pid=$old_pid)" >> "$LOG_ERR"
        kill "$old_pid" 2>>"$LOG_ERR" || true
        # give it a moment, then SIGKILL if needed
        for i in {1..10}; do
          ps -p "$old_pid" >/dev/null 2>&1 || break
          sleep 0.2
        done
        ps -p "$old_pid" >/dev/null 2>&1 && kill -9 "$old_pid" 2>>"$LOG_ERR" || true
      fi
      rm -f "$PID_FILE"
    fi

    cd "$EXO_DIR"

    # Timestamp so we know a new run started
    printf "[%s] starting: nix develop . --command uv run exo\n" "$(date -u +%FT%TZ)" >> "$LOG_ERR"

    # Run in background with nohup; no shell wrapping beyond this subshell
    # NOTE: we exec nix directly so no interactive shell init is required.
    nohup '"${NIX_BIN:-nix}"' develop . \
      --accept-flake-config \
      --extra-experimental-features "nix-command flakes" \
      --command '"${UV_BIN:-uv}"' run exo \
      >>"$LOG_OUT" 2>>"$LOG_ERR" &

    echo $! > "$PID_FILE"
    disown || true

    echo "[remote] exo started pid=$(cat "$PID_FILE")" >> "$LOG_ERR"
  '
done < "$norm_list"

echo "==> Done. Use the commands above to check status/logs on each host."
