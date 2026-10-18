#!/bin/sh
# Live weather for the sailboat wallpaper: Open-Meteo forecast (wind, gusts,
# clouds, rain, thunder, visibility) and Open-Meteo Marine (waves, swell), free
# and keyless. Writes `key=value` lines to $3 atomically. One fetch at a time
# (flock) across the wallpaper, the lock screen and the selector preview, and
# none if another instance fetched in the last 9 minutes.
# Usage: fetch_weather.sh LAT LON OUT [MARINE_LAT MARINE_LON]
set -u
lat=$1 lon=$2 out=$3
mlat=${4:-$lat} mlon=${5:-$lon}
dir=$(dirname "$out")
mkdir -p "$dir" || exit 1
exec 9>"$dir/.fetch.lock"
flock -n 9 || exit 0
if [ -f "$out" ] && [ $(( $(date +%s) - $(stat -c %Y "$out") )) -lt 540 ]; then
  exit 0
fi
command -v curl >/dev/null && command -v jq >/dev/null || exit 1
f=$(curl -fsS --max-time 20 "https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&current=wind_speed_10m,wind_direction_10m,wind_gusts_10m,cloud_cover,cloud_cover_low,cloud_cover_mid,cloud_cover_high,precipitation,rain,showers,weather_code,visibility&wind_speed_unit=kn&timezone=GMT" 2>/dev/null) || f=""
[ -n "$f" ] || exit 1
m=$(curl -fsS --max-time 20 "https://marine-api.open-meteo.com/v1/marine?latitude=$mlat&longitude=$mlon&current=wave_height,wave_direction,wave_period,swell_wave_height,swell_wave_direction,swell_wave_period,wind_wave_height&timezone=GMT" 2>/dev/null) || m=""
tmp="$out.tmp.$$"
{
  printf '%s' "$f" | jq -r '.current | to_entries[] | select(.value|type=="number") | "\(.key)=\(.value)"' || exit 1
  if [ -n "$m" ]; then
    printf '%s' "$m" | jq -r '.current | to_entries[] | select(.value|type=="number") | "marine_\(.key)=\(.value)"'
  fi
  echo "fetched=$(date +%s)"
} >"$tmp" && mv -f "$tmp" "$out"
rm -f "$tmp"
