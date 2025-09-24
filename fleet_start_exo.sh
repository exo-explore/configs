#!/usr/bin/env bash
set -euo pipefail

HOSTS_FILE="${1:-ops/hosts.txt}"
[[ -f "$HOSTS_FILE" ]] || { echo "ERROR: hosts file not found: $HOSTS_FILE" >&2; exit 1; }

# Normalize: "<attr> <target>"
norm_list="$(mktemp)"
awk 'NF==0 || $1 ~ /^#/ { next } NF==1 { printf "%s %s\n",$1,$1; next } { printf "%s %s\n",$1,$2 }' "$HOSTS_FILE" > "$norm_list"

# Known_hosts warmup
mkdir -p ~/.ssh; : > ~/.ssh/known_hosts
awk '{print $2}' "$norm_list" | while read -r tgt; do
  [[ -z "$tgt" ]] && continue
  host="$tgt"; [[ "$host" == *@* ]] && host="${host#*@}"
  ssh-keyscan -T 5 -H "$host" 2>/dev/null >> ~/.ssh/known_hosts || true
done

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes -o ServerAliveInterval=10 -o ServerAliveCountMax=3)

# Use absolute nix; uv will be provided by the devShell
NIX_BIN="/nix/var/nix/profiles/default/bin/nix"

echo "==> Starting exo on fleet (remote background via nohup)"
while read -r _ target; do
  [[ -z "$target" ]] && continue
  echo "---- $target"

  ssh -n "${SSH_OPTS[@]}" "$target" /usr/bin/env bash -s <<'REMOTE'
set -euo pipefail

EXO_DIR="/opt/exo"
LOG_DIR="$HOME/Library/Logs"
LOG_OUT="$LOG_DIR/exo.log"
LOG_ERR="$LOG_DIR/exo.err"
PID_FILE="/tmp/exo.pid"
NIX_BIN="/nix/var/nix/profiles/default/bin/nix"

# Ensure dirs/logs
/usr/bin/install -d -m 0755 "$EXO_DIR" "$LOG_DIR"
/usr/bin/touch "$LOG_OUT" "$LOG_ERR"

# Basic preflight diagnostics into the error log
{
  printf "[%s] fleet_start: user=%s HOME=%s\n" "$(date -u +%FT%TZ)" "$(whoami)" "$HOME"
  printf "[%s] fleet_start: EXO_DIR=%s\n" "$(date -u +%FT%TZ)" "$EXO_DIR"
  printf "[%s] fleet_start: has_flake=%s\n" "$(date -u +%FT%TZ)" "$([ -f "$EXO_DIR/flake.nix" ] && echo yes || echo no)"
  printf "[%s] fleet_start: nix=%s\n"   "$(date -u +%FT%TZ)" "$($NIX_BIN --version 2>&1 || echo 'not found')"
} >>"$LOG_ERR" 2>&1

# Stop previous instance if any
if [[ -f "$PID_FILE" ]]; then
  old_pid="$(cat "$PID_FILE" || true)"
  if [[ -n "${old_pid:-}" ]] && ps -p "$old_pid" >/dev/null 2>&1; then
    echo "[remote] stopping existing exo pid=$old_pid" >>"$LOG_ERR"
    kill "$old_pid" 2>>"$LOG_ERR" || true
    for i in {1..10}; do ps -p "$old_pid" >/dev/null 2>&1 || break; sleep 0.2; done
    ps -p "$old_pid" >/dev/null 2>&1 && kill -9 "$old_pid" 2>>"$LOG_ERR" || true
  fi
  rm -f "$PID_FILE"
fi

cd "$EXO_DIR"

# Start and immediately write the PID
{
  printf "[%s] starting: nix develop . --command uv run exo\n" "$(date -u +%FT%TZ)"
} >>"$LOG_ERR"

# Spawn in background; devShell supplies 'uv'
nohup "$NIX_BIN" develop . \
  --accept-flake-config \
  --extra-experimental-features "nix-command flakes" \
  --command uv run exo \
  >>"$LOG_OUT" 2>>"$LOG_ERR" &

echo $! > "$PID_FILE"
disown || true
REMOTE

  # Show first few lines of the remote err/log right away so we know it ran
  ssh -n "${SSH_OPTS[@]}" "$target" "bash -lc 'tail -n +1 -q ~/Library/Logs/exo.err 2>/dev/null | tail -n 20; echo \"---\"; tail -n 5 ~/Library/Logs/exo.log 2>/dev/null || true'"
done < "$norm_list"

echo "==> Done. To follow a host live:"
echo "    ssh <host> 'tail -f ~/Library/Logs/exo.err ~/Library/Logs/exo.log'"
