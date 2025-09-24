#!/usr/bin/env bash
set -euo pipefail

HOSTS_FILE="${1:-hosts.txt}"
grep -v '^\s*#' "$HOSTS_FILE" | sed '/^\s*$/d' | while read -r host; do
  echo "=== $host ==="
  ssh -n "$host" /usr/bin/env bash -lc '
    set -euo pipefail

    # Try to match nix develop or uv run exo processes
    pids=$(pgrep -f "nix develop .*uv run exo" || true)

    if [ -z "$pids" ]; then
      # fallback: just any uv run exo
      pids=$(pgrep -f "uv run exo" || true)
    fi

    if [ -n "$pids" ]; then
      echo "[remote] killing: $pids"
      kill $pids || true
      sleep 0.5
      for p in $pids; do
        if ps -p "$p" >/dev/null 2>&1; then
          echo "[remote] force killing $p"
          kill -9 "$p" || true
        fi
      done
    else
      echo "[remote] nothing to kill"
    fi
  '
done
