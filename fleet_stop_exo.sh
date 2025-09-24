#!/usr/bin/env bash
set -euo pipefail
HOSTS_FILE="${1:-ops/hosts.txt}"

norm_list="$(mktemp)"
awk 'NF==0 || $1 ~ /^#/ { next } NF==1 { printf "%s %s\n", $1, $1; next } { printf "%s %s\n", $1, $2 }' "$HOSTS_FILE" > "$norm_list"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes -o ServerAliveInterval=10 -o ServerAliveCountMax=3)

while read -r _ target; do
  [[ -z "$target" ]] && continue
  echo "---- $target"
  ssh -n "${SSH_OPTS[@]}" "$target" /usr/bin/env bash -lc '
    set -euo pipefail
    PID_FILE="/tmp/exo.pid"
    if [[ -f "$PID_FILE" ]]; then
      pid="$(cat "$PID_FILE" || true)"
      if [[ -n "${pid:-}" ]] && ps -p "$pid" >/dev/null 2>&1; then
        kill "$pid" || true
        sleep 0.5
        ps -p "$pid" >/dev/null 2>&1 && kill -9 "$pid" || true
      fi
      rm -f "$PID_FILE"
      echo "[remote] exo stopped"
    else
      echo "[remote] no pid file; nothing to stop"
    fi
  '
done < "$norm_list"
