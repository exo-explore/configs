#!/usr/bin/env bash
set -euo pipefail

# Tunables via env (safe defaults):
PCT_HIGH="${PCT_HIGH:-80}"              # % of total RAM for iogpu.wired_limit_mb
PCT_LOW="${PCT_LOW:-70}"                # % of total RAM for iogpu.wired_lwm_mb
FLOOR_MINUS_MB_HIGH="${FLOOR_MINUS_MB_HIGH:-5120}"  # totalMB - 5 GiB
FLOOR_MINUS_MB_LOW="${FLOOR_MINUS_MB_LOW:-8192}"    # totalMB - 8 GiB

# Total RAM in MB
total_bytes="$(/usr/sbin/sysctl -n hw.memsize)"
total_mb=$(( total_bytes / 1024 / 1024 ))

# Candidates
eighty_pct=$(( total_mb * PCT_HIGH / 100 ))
minus_5gb=$(( total_mb - FLOOR_MINUS_MB_HIGH ))
seventy_pct=$(( total_mb * PCT_LOW / 100 ))
minus_8gb=$(( total_mb - FLOOR_MINUS_MB_LOW ))

# Choose higher of each pair
wired_limit_mb="$eighty_pct"
if [ "$minus_5gb" -gt "$wired_limit_mb" ]; then wired_limit_mb="$minus_5gb"; fi

wired_lwm_mb="$seventy_pct"
if [ "$minus_8gb" -gt "$wired_lwm_mb" ]; then wired_lwm_mb="$minus_8gb"; fi

# Clamp to sensible range
[ "$wired_limit_mb" -lt 0 ] && wired_limit_mb=0
[ "$wired_lwm_mb" -lt 0 ] && wired_lwm_mb=0
[ "$wired_limit_mb" -gt "$total_mb" ] && wired_limit_mb="$total_mb"
[ "$wired_lwm_mb" -gt "$wired_limit_mb" ] && wired_lwm_mb="$wired_limit_mb"

echo "$(date '+%F %T') total=${total_mb}MB limit=${wired_limit_mb}MB lwm=${wired_lwm_mb}MB"

# Apply (best-effort; these keys may be read-only on some macOS versions)
#/usr/sbin/sysctl -n iogpu.wired_limit_mb 2>/dev/null || true
/usr/sbin/sysctl -w iogpu.wired_limit_mb="$wired_limit_mb" || echo "warn: could not set iogpu.wired_limit_mb" >&2
/usr/sbin/sysctl -w iogpu.wired_lwm_mb="$wired_lwm_mb"     || echo "warn: could not set iogpu.wired_lwm_mb" >&2
