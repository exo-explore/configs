#!/usr/bin/env bash
set -euo pipefail
# --- Config / overrides -------------------------------------------------------
WIRED_SERVICE="${1:-}" # e.g. "Ethernet" (default autodetected)
WIFI_SERVICE="${WIFI_SERVICE:-Wi-Fi}"
LAN_PREFIX="${LAN_PREFIX:-192.168.1}"
NETMASK="${NETMASK:-255.255.255.0}"
# -----------------------------------------------------------------------------
host="$(hostname -s)"

if [[ "$host" =~ ^a([0-9]+)(s-Mac-Studio)?$ ]]; then
  num="${BASH_REMATCH[1]}"
else
  echo "ERROR: Hostname '$host' does not match pattern like 'a1', 'a4s-Mac-Studio', ..."
  exit 0
fi
ip="$LAN_PREFIX.$num"

read_services() {
  local out=()
  while read -r line; do
    [[ "$line" == "An asterisk"* ]] && continue
    [[ -z "$line" ]] && continue
    [[ "$line" == \** ]] && line="${line#* }"
    out+=("$line")
  done < <(networksetup -listallnetworkservices)
  printf '%s\n' "${out[@]}"
}

if [[ -z "$WIRED_SERVICE" ]]; then
  if read_services | grep -Fxq "Ethernet"; then
    WIRED_SERVICE="Ethernet"
  else
    cand="$(read_services | grep -E 'Ethernet$|USB 10/100/1000 LAN|USB.*Ethernet|Thunderbolt Ethernet' | head -n1 || true)"
    if [[ -n "$cand" ]]; then
      WIRED_SERVICE="$cand"
    else
      echo "ERROR: Could not determine a wired service. Pass it explicitly, e.g.:"
      echo "       $0 'Ethernet'"
      exit 0
    fi
  fi
fi

echo "Configuring '$WIRED_SERVICE' to $ip/$NETMASK (no router) ..."
/usr/sbin/networksetup -setmanual "$WIRED_SERVICE" "$ip" "$NETMASK"
/usr/sbin/networksetup -setdnsservers "$WIRED_SERVICE" "Empty" || true
/usr/sbin/networksetup -setv6linklocal "$WIRED_SERVICE" || true

services=()
while IFS= read -r s; do services+=("$s"); done < <(read_services)

if printf '%s\n' "${services[@]}" | grep -Fxq "$WIFI_SERVICE"; then
  new_order=("$WIFI_SERVICE")
  for s in "${services[@]}"; do
    [[ "$s" == "$WIFI_SERVICE" ]] && continue
    new_order+=("$s")
  done
  /usr/sbin/networksetup -ordernetworkservices "${new_order[@]}" || true
fi

echo "Done."
echo "-> Wired $WIRED_SERVICE: $ip/$NETMASK (no router, no DNS)"
echo "-> Wi-Fi stays primary for internet."
