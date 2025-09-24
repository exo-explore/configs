#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Args & prerequisites
###############################################################################
if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [hosts_file]" >&2
  exit 1
fi
HOSTS_FILE=${1:-hosts.txt}

###############################################################################
# Load & normalize hosts.txt -> two columns: <attr> <target>
# - blank lines & comments (#) skipped
# - single-column lines treated as "<name> <name>"
###############################################################################
if [[ ! -f "$HOSTS_FILE" ]]; then
  echo "Error: $HOSTS_FILE not found" >&2
  exit 1
fi

norm_list="$(mktemp)"
trap 'rm -f "$norm_list"' EXIT

awk '
  NF==0 || $1 ~ /^#/ { next }
  NF==1 { printf "%s %s\n", $1, $1; next }
  { printf "%s %s\n", $1, $2 }
' "$HOSTS_FILE" > "$norm_list"

# Extract just the SSH targets into TARGETS[]
if builtin command -v mapfile >/dev/null 2>&1; then
  mapfile -t TARGETS < <(awk '{print $2}' "$norm_list")
else
  TARGETS=()
  while read -r _ tgt; do
    [[ -n "$tgt" ]] && TARGETS+=("$tgt")
  done <"$norm_list"
fi

[[ ${#TARGETS[@]} -gt 0 ]] || {
  echo "No valid hosts found in $HOSTS_FILE" >&2
  exit 1
}

###############################################################################
# Helper – run a remote command and capture rc
###############################################################################
ssh_opts=(
  -o StrictHostKeyChecking=accept-new
  -o LogLevel=ERROR
  -o ConnectTimeout=10
)

run_remote() { # $1 host   $2 command
  local host=$1 cmd=$2 rc
  if ssh "${ssh_opts[@]}" "$host" "$cmd"; then
    rc=0
  else
    rc=$?
  fi
  return $rc
}

###############################################################################
# Phase 1 – kill exo everywhere (parallel)
###############################################################################
echo "=== Stage 1: killing exo on ${#TARGETS[@]} host(s) ==="
fail=0
for h in "${TARGETS[@]}"; do
  (
    run_remote "$h" 'pkill -f exo || true'
  ) || fail=1 &
done
wait
((fail == 0)) || {
  echo "❌ Some hosts could not be reached—check SSH access."
  exit 1
}
echo "✓ exo processes killed on all reachable hosts."

###############################################################################
# Phase 2 – start new exo processes in Terminal windows (parallel)
###############################################################################
echo "=== Stage 2: starting new exo processes ==="
fail=0
for h in "${TARGETS[@]}"; do
  # Use osascript to open Terminal windows on remote Mac
  remote_cmd='osascript -e "tell app \"Terminal\" to do script \"cd /opt/exo; nix develop --command uv run exo\""'
  (run_remote "$h" "$remote_cmd") || fail=1 &
done
wait

((fail == 0)) && echo "🎉 Deployment finished!" || {
  echo "⚠️  Some starts failed—see above."
  exit 1
}
