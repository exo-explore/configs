#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   PUBKEY_FILE=~/.ssh/id_ed25519.pub GH_PAT=ghp_xxx ./ops/fleet_setup.sh [hosts_file]
# Notes:
#   - hosts.txt lines: "<flake-attr>  <ssh-target>"  OR just "<name>" (used for both)
#   - Step 1 uses password auth (one prompt per host) to seed your pubkey; after that, it’s key-only.

HOSTS_FILE="${1:-ops/hosts.txt}"
CONFIGS_REPO="${CONFIGS_REPO:-https://github.com/exo-explore/configs.git}"
CONFIGS_BRANCH="${CONFIGS_BRANCH:-main}"
CONFIGS_DIR="${CONFIGS_DIR:-/opt/exo-configs}"

[[ -f "$HOSTS_FILE" ]] || { echo "ERROR: hosts file not found: $HOSTS_FILE" >&2; exit 1; }

# --- load public key (one line) ---
if [[ -n "${PUBKEY:-}" ]]; then
  KEY_LINE="$PUBKEY"
else
  KEY_FILE="${PUBKEY_FILE:-$HOME/.ssh/id_ed25519.pub}"
  [[ -r "$KEY_FILE" ]] || { echo "ERROR: set PUBKEY or PUBKEY_FILE (e.g., PUBKEY_FILE=~/.ssh/id_ed25519.pub)" >&2; exit 1; }
  KEY_LINE="$(cat "$KEY_FILE")"
fi

# --- require GH_PAT for PAT step ---
: "${GH_PAT:?ERROR: set GH_PAT (export GH_PAT=ghp_xxx) before running.}"

# --- normalize hosts -> two columns: <attr> <target> ---
norm_list="$(mktemp)"
awk '
  NF==0 || $1 ~ /^#/ { next }
  NF==1 { printf "%s %s\n", $1, $1; next }
  { printf "%s %s\n", $1, $2 }
' "$HOSTS_FILE" > "$norm_list"

# --- pre-seed known_hosts (strip user@ if present) ---
mkdir -p ~/.ssh; touch ~/.ssh/known_hosts
awk '{print $2}' "$norm_list" | while read -r tgt; do
  [[ -z "$tgt" ]] && continue
  host="$tgt"; [[ "$host" == *@* ]] && host="${host#*@}"
  ssh-keyscan -T 5 -H "$host" 2>/dev/null >> ~/.ssh/known_hosts || true
done

# --------- STEP 1: seed pubkeys (password auth, serial) ----------
echo "==> [1/3] Seeding SSH pubkeys to users' ~/.ssh/authorized_keys (first run uses passwords)"
SSH_BOOT=(-o PreferredAuthentications=password -o PubkeyAuthentication=no
          -o NumberOfPasswordPrompts=1 -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

while read -r _ target; do
  [[ -z "$target" ]] && continue
  echo "---- $target"
  # scp key to temp file
  tmpkey="$(mktemp)"; printf '%s\n' "$KEY_LINE" > "$tmpkey"
  scp "${SSH_BOOT[@]}" "$tmpkey" "$target:/tmp/.exo_seed.pub" < /dev/null
  rm -f "$tmpkey"
  # append if missing; dedupe; perms
  ssh -n "${SSH_BOOT[@]}" "$target" "bash -lc '
    set -e
    umask 077
    mkdir -p ~/.ssh
    touch ~/.ssh/authorized_keys
    if ! grep -Fqx -f /tmp/.exo_seed.pub ~/.ssh/authorized_keys; then
      cat /tmp/.exo_seed.pub >> ~/.ssh/authorized_keys
    fi
    sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys
    rm -f /tmp/.exo_seed.pub
    chmod 700 ~/.ssh
    chmod 600 ~/.ssh/authorized_keys
  '"
done < "$norm_list"

# From here on, default to key-only noninteractive SSH
SSH_OPTS='-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes -o ServerAliveInterval=10 -o ServerAliveCountMax=3'

# --------- STEP 2: install Nix (daemon) + enable flakes (idempotent) ----------
echo "==> [2/3] Installing Nix (daemon mode) + enabling flakes (idempotent)"
while read -r _ target; do
  [[ -z "$target" ]] && continue
  ssh -n $SSH_OPTS "$target" "bash -lc '
    set -e
    if ! command -v nix >/dev/null 2>&1 || [ ! -d /nix/store ]; then
      sudo touch /etc/synthetic.conf && sudo chown root:wheel /etc/synthetic.conf && sudo chmod 0644 /etc/synthetic.conf
      curl -L https://nixos.org/nix/install | sh -s -- --daemon --yes
      curl -fsSL https://install.determinate.systems/nix | sh -s -- install
    fi
    sudo mkdir -p /etc/nix
    if ! grep -q \"experimental-features\" /etc/nix/nix.conf 2>/dev/null; then
      echo \"experimental-features = nix-command flakes\" | sudo tee -a /etc/nix/nix.conf >/dev/null
    fi
    sudo launchctl kickstart -k system/org.nixos.nix-daemon || true
  '"
done < "$norm_list"

# --------- STEP 3: seed GitHub PAT into System.keychain (idempotent) ----------
echo "==> [3/3] Seeding GitHub PAT into System.keychain + kicking repo sync"
while read -r _ target; do
  [[ -z "$target" ]] && continue
  ssh -n $SSH_OPTS "$target" "bash -lc '
    set -e
    sudo /usr/bin/security delete-generic-password -s exo-github-pat /Library/Keychains/System.keychain >/dev/null 2>&1 || true
    sudo /usr/bin/security add-generic-password -s exo-github-pat -a x-access-token -w '"$GH_PAT"' -A /Library/Keychains/System.keychain
    sudo /bin/launchctl kickstart -k system/org.nixos.exo-repo-sync || true
  '"
done < "$norm_list"

# keep setup script focused; use fleet_update.sh for applying configs
