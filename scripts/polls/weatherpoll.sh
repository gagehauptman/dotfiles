#!/bin/bash
# Weather poll script for Quickshell
# Uses ipinfo.io for geolocation, Open-Meteo for weather (no API key needed)

# Optional args (set from the dashboard preset's weather options):
#   $1  location: "lat,lon" or a place name (geocoded via Open-Meteo). Empty = IP geolocation.
#   $2  label: display name override for the city field.
LOCATION="${1:-}"
LABEL="${2:-}"

CACHE_FILE="/tmp/weather_cache${LOCATION:+_$(printf '%s|%s' "$LOCATION" "$LABEL" | md5sum | cut -c1-8)}"
CACHE_MAX_AGE=300  # 5 minutes

# Return cache if fresh enough
if [[ -f "$CACHE_FILE" ]]; then
  cache_age=$(( $(date +%s) - $(stat -c %Y "$CACHE_FILE") ))
  if (( cache_age < CACHE_MAX_AGE )); then
    cat "$CACHE_FILE"
    exit 0
  fi
fi

if [[ "$LOCATION" =~ ^-?[0-9]+(\.[0-9]+)?,-?[0-9]+(\.[0-9]+)?$ ]]; then
  # Explicit coordinates
  lat="${LOCATION%,*}"
  lon="${LOCATION#*,}"
  city="${LABEL:-$LOCATION}"
elif [[ -n "$LOCATION" ]]; then
  # Place name -> coordinates via Open-Meteo geocoding
  q=$(jq -rn --arg s "$LOCATION" '$s|@uri')
  geo=$(curl -s --max-time 5 "https://geocoding-api.open-meteo.com/v1/search?name=${q}&count=1&language=en&format=json" 2>/dev/null)
  lat=$(echo "$geo" | jq -r '.results[0].latitude // empty')
  lon=$(echo "$geo" | jq -r '.results[0].longitude // empty')
  if [[ -z "$lat" || -z "$lon" ]]; then
    echo "${LABEL:-$LOCATION}|?|0|0|0|0"
    exit 1
  fi
  city="${LABEL:-$(echo "$geo" | jq -r '.results[0].name // "Unknown"')}"
else
  # Get geolocation from IP
  geo=$(curl -s --max-time 5 "https://ipinfo.io/json" 2>/dev/null)
  if [[ -z "$geo" ]]; then
    echo "??|?|0|0|0|0"
    exit 1
  fi

  city="${LABEL:-$(echo "$geo" | jq -r '.city // "Unknown"')}"
  loc=$(echo "$geo" | jq -r '.loc // "0,0"')
  lat=$(echo "$loc" | cut -d',' -f1)
  lon=$(echo "$loc" | cut -d',' -f2)
fi

# Fetch weather from Open-Meteo (free, no key)
weather=$(curl -s --max-time 5 \
  "https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}&current=temperature_2m,relative_humidity_2m,wind_speed_10m,weather_code&temperature_unit=celsius&wind_speed_unit=kmh" \
  2>/dev/null)

if [[ -z "$weather" ]]; then
  echo "${city}|?|0|0|0|0"
  exit 1
fi

temp=$(echo "$weather" | jq -r '.current.temperature_2m // 0')
humidity=$(echo "$weather" | jq -r '.current.relative_humidity_2m // 0')
wind=$(echo "$weather" | jq -r '.current.wind_speed_10m // 0')
code=$(echo "$weather" | jq -r '.current.weather_code // 0')

# Output: city|weather_code|temp|humidity|wind_speed
result="${city}|${code}|${temp}|${humidity}|${wind}"
echo "$result" | tee "$CACHE_FILE"
