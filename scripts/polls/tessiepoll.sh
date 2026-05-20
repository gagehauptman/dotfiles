#!/usr/bin/env bash
# Tessie car status poll.
# Output (pipe-delimited, one line):
#   ok|<state>|<battery_pct>|<range_mi>|<charging>|<locked>|<climate_on>|<inside_temp_c>|<name>|<charger_kw>
#   error|<message>

_die() { echo "error|$1"; exit 0; }
source "$(dirname "$0")/_tessie.sh"

tessie_load_token
tessie_load_vin

state_json=$(curl -sf -m 5 -H "Authorization: Bearer $TESSIE_TOKEN" \
  "$TESSIE_BASE/$TESSIE_VIN/state?use_cache=true") || _die "state fetch failed"

echo "$state_json" | jq -r '
  [
    "ok",
    (.state // "unknown"),
    (.charge_state.battery_level // 0),
    ((.charge_state.battery_range // 0) | floor),
    (.charge_state.charging_state // "Unknown"),
    (.vehicle_state.locked // false),
    (.climate_state.is_climate_on // false),
    (.climate_state.inside_temp // 0),
    (.display_name // .vehicle_state.vehicle_name // "Car"),
    (.charge_state.charger_power // 0)
  ] | join("|")
'
