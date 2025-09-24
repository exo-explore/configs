#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   PUBKEY_FILE=~/.ssh/id_ed25519.pub GH_PAT=ghp_xxx ./ops/fleet_setup.sh [hosts_file]
#
# Notes:
#   - hosts.txt lines: "<flake-attr>  <ssh-target>"  OR just "<name>" (used for both)
#   - Step 1 uses password SSH once to seed your pubkey and install passwordless sudo for the remote user.
#   - Steps 2/3 are fully non-interactive (key-only + sudo -n).

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

# --------- STEP 1: seed pubkeys + install passwordless sudo (serial; password SSH) ----------
echo "==> [1/3] Seeding SSH pubkeys + enabling passwordless sudo (first run uses passwords)"
SSH_BOOT=(-o PreferredAuthentications=password -o PubkeyAuthentication=no
          -o NumberOfPasswordPrompts=1 -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

while read -r _ target; do
  [[ -z "$target" ]] && continue
  echo "---- $target"
  # 1a) copy public key to temp
  tmpkey="$(mktemp)"; printf '%s\n' "$KEY_LINE" > "$tmpkey"
  scp "${SSH_BOOT[@]}" "$tmpkey" "$target:/tmp/.exo_seed.pub" < /dev/null
  rm -f "$tmpkey"

  # 1b) append key, set perms, and install a sudoers drop-in for the remote user
  #     IMPORTANT: no `-n` here; do use `-tt` so sudo can read the password.
  ssh -tt "${SSH_BOOT[@]}" "$target" "bash -lc '
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

    # Cache sudo credentials (will prompt once, with working TTY)
    sudo -v

    # Ensure sudo reads drop-ins; check as root to avoid permission errors
    if ! sudo grep -q \"#includedir /etc/sudoers.d\" /etc/sudoers; then
      echo \"#includedir /etc/sudoers.d\" | sudo tee -a /etc/sudoers >/dev/null
    fi

    # Catch-all NOPASSWD for this user; validate with visudo for safety
    me=\$(id -un)
    echo \"\${me} ALL=(ALL) NOPASSWD: ALL\" | sudo tee /etc/sudoers.d/exo-nopasswd-\${me} >/dev/null
    sudo chmod 440 /etc/sudoers.d/exo-nopasswd-\${me}
    sudo visudo -cf /etc/sudoers >/dev/null
  '"

done < "$norm_list"

# From here on, key-only + non-interactive sudo.
SSH_OPTS='-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes -o ServerAliveInterval=10 -o ServerAliveCountMax=3'

# --------- STEP 2: install Nix (daemon) + enable flakes (idempotent, non-interactive) ----------
echo "==> [2/3] Installing Nix (daemon mode) + enabling flakes (idempotent)"
while read -r _ target; do
  [[ -z "$target" ]] && continue
  ssh -n $SSH_OPTS "$target" "bash -lc '
    set -e
    # Only install if Nix missing or store absent
    if ! command -v nix >/dev/null 2>&1 || [ ! -d /nix/store ]; then
      # Prepare synthetic mount point for /nix
      sudo -n touch /etc/synthetic.conf
      sudo -n chown root:wheel /etc/synthetic.conf
      sudo -n chmod 0644 /etc/synthetic.conf
      # Run installer as root non-interactively
      curl -L https://nixos.org/nix/install | sudo -n sh -s -- --daemon --yes
    fi

    # Enable flakes
    sudo -n mkdir -p /etc/nix
    if ! grep -q \"experimental-features\" /etc/nix/nix.conf 2>/dev/null; then
      echo \"experimental-features = nix-command flakes\" | sudo -n tee -a /etc/nix/nix.conf >/dev/null
    fi

    # Ensure daemon is up
    sudo -n launchctl kickstart -k system/org.nixos.nix-daemon || true
  '"
done < "$norm_list"

# --------- STEP 3: seed GitHub PAT into System.keychain + kick repo sync (idempotent) ----------
echo "==> [3/3] Seeding GitHub PAT into System.keychain + kicking repo sync"
while read -r _ target; do
  [[ -z "$target" ]] && continue
  ssh -n $SSH_OPTS "$target" "bash -lc '
    set -e
    # Store PAT in System.keychain for a system daemon to use
    sudo -n /usr/bin/security delete-generic-password -s exo-github-pat /Library/Keychains/System.keychain >/dev/null 2>&1 || true
    sudo -n /usr/bin/security add-generic-password -s exo-github-pat -a x-access-token -w '"$GH_PAT"' -A /Library/Keychains/System.keychain

    # Optional: ensure a repo-sync service (if installed via Nix) gets kicked
    sudo -n /bin/launchctl kickstart -k system/org.nixos.exo-repo-sync || true
  '"
done < "$norm_list"

echo "All done. From now on, SSH is key-only and sudo is passwordless on those hosts."

