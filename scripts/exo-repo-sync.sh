#!/usr/bin/env bash
set -euo pipefail

REPO_HTTPS_URL="${EXO_REPO_URL_HTTPS:-https://github.com/exo-explore/exo-v2.git}"
BRANCH="${EXO_REPO_BRANCH:-big-refactor}"
DEST="${EXO_REPO_DEST:-/opt/exo}"
OWNER="${EXO_REPO_OWNER:-$(id -un)}"

# Try user login keychain, then System keychain (headless-safe)
TOKEN="$(/usr/bin/security find-generic-password -s exo-github-pat -w 2>/dev/null || \
         /usr/bin/security find-generic-password -s exo-github-pat -w /Library/Keychains/System.keychain 2>/dev/null || true)"
if [[ -z "${TOKEN}" ]]; then
  echo "exo-repo-sync: no PAT found (login or System keychain). Skipping."
  exit 0
fi

# Build a one-shot Authorization header (do NOT persist token anywhere)
AUTH="Authorization: Basic $(printf 'x-access-token:%s' "$TOKEN" | /usr/bin/base64)"

mkdir -p "$DEST"
/usr/sbin/chown -R "$OWNER":staff "$DEST"

if [[ ! -d "$DEST/.git" ]]; then
  echo "exo-repo-sync: cloning (branch $BRANCH)"
  /usr/bin/git -c http.extraHeader="$AUTH" clone --single-branch --branch "$BRANCH" "$REPO_HTTPS_URL" "$DEST"
else
  echo "exo-repo-sync: updating (branch $BRANCH)"
  cd "$DEST"
  /usr/bin/git remote set-url origin "$REPO_HTTPS_URL" || true
  /usr/bin/git -c http.extraHeader="$AUTH" fetch origin
  /usr/bin/git switch -C "$BRANCH" --track "origin/$BRANCH" || /usr/bin/git switch "$BRANCH" || true
  /usr/bin/git -c http.extraHeader="$AUTH" reset --hard "origin/$BRANCH"
fi

/usr/sbin/chown -R "$OWNER":staff "$DEST"

