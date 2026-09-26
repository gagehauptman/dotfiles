#!/usr/bin/env bash
# Send a command to the first Tessie-managed vehicle.
# Usage: tessiecmd.sh <lock|unlock|start_climate|stop_climate>
#        tessiecmd.sh <play|pause|next|prev|next_fav|prev_fav|vol_up|vol_down|vol N|now>
# Media commands go through Tessie's Tesla Fleet API passthrough (api.tessie.com/api/1/...), which signs them.
# `now` prints "artist - title (source, playing|paused, vol X/Y)" from cached state and never wakes the car.
# Output: "ok" on success (exit 0); failure reason from the API on error (exit 1).

ACTION="$1"
case "$ACTION" in
  lock|unlock|start_climate|stop_climate) ;;
  play|pause|next|prev|next_fav|prev_fav|vol_up|vol_down|vol|now) MEDIA=1 ;;
  *) echo "usage: $0 <lock|unlock|start_climate|stop_climate|play|pause|next|prev|next_fav|prev_fav|vol_up|vol_down|vol N|now>" >&2; exit 1 ;;
esac

_die() { echo "$1"; exit 1; }
source "$(dirname "$0")/_tessie.sh"

tessie_load_token
tessie_load_vin

media_info() {
  curl -sf -m 10 -H "Authorization: Bearer $TESSIE_TOKEN" "$TESSIE_BASE/$TESSIE_VIN/state?use_cache=true" \
    | jq -c ".vehicle_state.media_info // empty"
}

fleet_cmd() {  # fleet_cmd <command> [json body]
  local r
  r=$(curl -s -m 15 -X POST -H "Authorization: Bearer $TESSIE_TOKEN" -H "Content-Type: application/json" \
      -d "${2:-{\}}" "$TESSIE_BASE/api/1/vehicles/$TESSIE_VIN/command/$1")
  [ -n "$r" ] || _die "no response"
  if [ "$(echo "$r" | jq -r ".response.result // false" 2>/dev/null)" = "true" ]; then echo "ok"; exit 0; fi
  echo "$r" | jq -r ".response.reason // .error // .message // \"command rejected\"" 2>/dev/null || echo "$r"
  exit 1
}

if [ -n "${MEDIA:-}" ]; then
  case "$ACTION" in
    now)
      m=$(media_info) || _die "state fetch failed"
      [ -n "$m" ] || _die "no media info (car asleep?)"
      echo "$m" | jq -r "\"\(.now_playing_artist // \"?\") - \(.now_playing_title // \"?\") (\(.now_playing_source // \"?\"), \(.media_playback_status // \"?\" | ascii_downcase), vol \(.audio_volume // 0 | .*10 | round / 10)/\(.audio_volume_max // 0 | .*10 | round / 10))\""
      exit 0 ;;
    play|pause)
      st=$(media_info | jq -r ".media_playback_status // empty")
      if [ "$ACTION" = play ] && [ "$st" = Playing ]; then echo "ok"; exit 0; fi   # toggle only when it changes something
      if [ "$ACTION" = pause ] && [ -n "$st" ] && [ "$st" != Playing ]; then echo "ok"; exit 0; fi
      fleet_cmd media_toggle_playback ;;
    next) fleet_cmd media_next_track ;;
    prev) fleet_cmd media_prev_track ;;
    next_fav) fleet_cmd media_next_fav ;;
    prev_fav) fleet_cmd media_prev_fav ;;
    vol_up|vol_down|vol)
      m=$(media_info)
      cur=$(echo "$m" | jq -r ".audio_volume // 5"); max=$(echo "$m" | jq -r ".audio_volume_max // 11")
      case "$ACTION" in
        vol_up) v=$(awk -v c="$cur" "BEGIN{print c+1}") ;;
        vol_down) v=$(awk -v c="$cur" "BEGIN{print c-1}") ;;
        vol) v="${2:?usage: $0 vol <0-$max>}" ;;
      esac
      v=$(awk -v v="$v" -v m="$max" "BEGIN{if (v<0) v=0; if (v>m) v=m; printf \"%.2f\", v}")
      fleet_cmd adjust_volume "{\"volume\": $v}" ;;
  esac
fi

response=$(curl -s -m 15 -X POST -H "Authorization: Bearer $TESSIE_TOKEN" \
  "$TESSIE_BASE/$TESSIE_VIN/command/$ACTION")
[ -n "$response" ] || _die "no response"

result=$(echo "$response" | jq -r '.result // false' 2>/dev/null)
if [ "$result" = "true" ]; then
  echo "ok"
  exit 0
fi

reason=$(echo "$response" | jq -r '.reason // .error // .message // "command rejected"' 2>/dev/null)
echo "${reason:-unknown error}"
exit 1
