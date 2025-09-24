#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./ops/fleet_update.sh [hosts_file]
#
# hosts.txt lines (whitespace separated):
#   <flake-attr>  <ssh-target>
#   <one-field>   # used for both attr and ssh target
#
# First-time password bootstrap:
#   export USE_PASSWORD=1
#   export JOBS=1
#   ./ops/fleet_update.sh ./ops/hosts.txt
#
# Subsequent runs (keys only, fully parallel):
#   unset USE_PASSWORD
#   JOBS=6 ./ops/fleet_update.sh ./ops/hosts.txt

HOSTS_FILE="${1:-ops/hosts.txt}"
JOBS="${JOBS:-1}"

# Public configs flake repo to apply on each host
CONFIGS_REPO="${CONFIGS_REPO:-https://github.com/exo-explore/configs.git}"
CONFIGS_BRANCH="${CONFIGS_BRANCH:-main}"
CONFIGS_DIR="${CONFIGS_DIR:-/opt/exo-configs}"

# SSH options
if [[ "${USE_PASSWORD:-}" == "1" ]]; then
  # Force password (no key prompts) for the first bootstrap
  export SSH_OPTS='-o PreferredAuthentications=password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10'
else
  # Key-only, fully non-interactive
  export SSH_OPTS='-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes -o ServerAliveInterval=10 -o ServerAliveCountMax=3'
fi

# Prefer a specific identity to avoid password prompts
DEFAULT_IDENTITY_FILE="${SSH_IDENTITY_FILE:-$HOME/.ssh/id_ed25519}"
if [[ -r "$DEFAULT_IDENTITY_FILE" ]]; then
  export SSH_OPTS="$SSH_OPTS -i $DEFAULT_IDENTITY_FILE -o IdentitiesOnly=yes"
fi

[[ -f "$HOSTS_FILE" ]] || { echo "ERROR: hosts file not found: $HOSTS_FILE" >&2; exit 1; }

# Install prerequisties
brew install parallel

# Normalize hosts -> two columns: <attr> <target>
norm_list="$(mktemp)"
awk '
  NF==0 || $1 ~ /^#/ { next }
  NF==1 { printf "%s %s\n", $1, $1; next }
  { printf "%s %s\n", $1, $2 }
' "$HOSTS_FILE" > "$norm_list"

# Pre-seed known_hosts (strip any user@ from target for keyscan)
mkdir -p ~/.ssh; touch ~/.ssh/known_hosts
awk '{print $2}' "$norm_list" | while read -r tgt; do
  [[ -z "$tgt" ]] && continue
  host="$tgt"
  if [[ "$host" == *@* ]]; then host="${host#*@}"; fi
  ssh-keyscan -T 5 -H "$host" 2>/dev/null >> ~/.ssh/known_hosts || true
done

# Per-host runner (executed on controller; drives each host via SSH)
runner="$(mktemp)"
cat >"$runner" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
attr="$1"; target="$2"; repo="$3"; branch="$4"; confdir="$5"

SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes -o ServerAliveInterval=10 -o ServerAliveCountMax=3}"

echo "==== $attr -> $target ===="
echo "STEP1: prepare config dir"

# 1) Ensure configs dir exists and is owned by the login user
ssh -n $SSH_OPTS "$target" "sudo mkdir -p '$confdir' && sudo chown -R \$(id -un):staff '$confdir'"

# 2) Clone or update configs ON THE HOST (use nix-provided git to avoid CLT prompts)
echo "STEP2: sync repo (this may take a few minutes the first time)"
ssh -n $SSH_OPTS "$target" "nix shell nixpkgs#git -c bash -lc '
  set -euo pipefail
  if [ ! -d \"$confdir/.git\" ]; then
    echo \"cloning $repo (branch $branch) into $confdir\"
    git clone --verbose --single-branch --branch \"$branch\" \"$repo\" \"$confdir\"
  else
    echo \"updating $confdir\"
    git -C \"$confdir\" fetch --verbose origin
    git -C \"$confdir\" checkout \"$branch\"
    git -C \"$confdir\" reset --hard \"origin/$branch\"
  fi
'"

# Preflight: migrate conflicting /etc authorized_keys to .before-nix-darwin (one-time)
echo "PRE: migrate /etc/ssh/authorized_keys if present"
ssh -n $SSH_OPTS "$target" "bash -lc '
  set -e
  u=\$(id -un)
  f=/etc/ssh/authorized_keys/\$u
  if [ -e \"\$f\" ] && [ ! -L \"\$f\" ]; then
    echo \"Renaming \$f -> \$f.before-nix-darwin\"
    sudo mv \"\$f\" \"\$f.before-nix-darwin\" || true
  fi
'"

# 3) Switch from the on-host checkout (must be root)
echo "STEP3: nix-darwin switch"
ssh -n $SSH_OPTS "$target" "sudo -H nix run --extra-experimental-features 'nix-command flakes' nix-darwin -- switch --flake '$confdir#$attr'"

# 4) Ensure code + service are live now
echo "STEP4: kick services"
ssh -n $SSH_OPTS "$target" 'sudo launchctl kickstart -k system/org.nixos.exo-repo-sync || true'
ssh -n $SSH_OPTS "$target" 'sudo launchctl kickstart -k system/org.nixos.exo-service   || true'

echo "==== $attr DONE ===="
RUNNER
chmod +x "$runner"

# Fan-out
if [[ "${FORCE_SERIAL:-}" == "1" || "$JOBS" == "1" ]]; then
  while read -r attr target; do
    [[ -z "$attr" ]] && continue
    "$runner" "$attr" "$target" "$CONFIGS_REPO" "$CONFIGS_BRANCH" "$CONFIGS_DIR"
  done < "$norm_list"
elif command -v parallel >/dev/null 2>&1; then
  # {1}=attr, {2}=target
  parallel --will-cite --verbose --lb --colsep '[[:space:]]+' -a "$norm_list" -j "$JOBS" --halt now,fail=1 \
    --tagstring '{1}->{2}' \
    "$runner" {1} {2} "$CONFIGS_REPO" "$CONFIGS_BRANCH" "$CONFIGS_DIR"
else
  while read -r attr target; do
    [[ -z "$attr" ]] && continue
    "$runner" "$attr" "$target" "$CONFIGS_REPO" "$CONFIGS_BRANCH" "$CONFIGS_DIR"
  done < "$norm_list"
fi

rm -f "$norm_list" "$runner"
echo "All done."
