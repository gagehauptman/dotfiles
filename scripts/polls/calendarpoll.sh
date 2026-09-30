#!/bin/bash
# Proton Calendar for the bar calendar widget, from calro (read-only, end-to-end encrypted; see ~/calro).
# calro runs on the server; it is used locally when its socket is here, otherwise over ssh to CALRO_SSH
# (from the env or ~/.config/calro/env), falling back to NOVA_GATEWAY_SSH from ~/.config/nova-voice/env.
# Prints one JSON object, always exit 0:
#   {"state":"ok","stale":false,"events":[{"summary","start","end","all_day","calendar","location","skip","verified"}]}
#   {"state":"offline","reason":"..."}  when calro is not installed, not running or not reachable
# Test mode, no calro needed:  calendarpoll.sh --fixture <file>  (TODAY/TOMORROW in the file become dates).
if [ "${1:-}" = "--fixture" ]; then
  f=${2:-$(dirname "$0")/fixtures/calendar.json}
  sed "s/TODAY/$(date +%F)/g; s/TOMORROW/$(date -d tomorrow +%F)/g" "$f" 2>/dev/null || echo '{"state":"offline","reason":"fixture missing"}'
  exit 0
fi
[ -f "$HOME/.config/calro/env" ] && . "$HOME/.config/calro/env"
[ -z "$CALRO_SSH" ] && [ -f "$HOME/.config/nova-voice/env" ] && CALRO_SSH=$(. "$HOME/.config/nova-voice/env"; echo "$NOVA_GATEWAY_SSH")
offline() { jq -cn --arg r "$1" '{state:"offline",reason:$r}'; exit 0; }
tz=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')
args="events --from $(date +%F) --to $(date -d '+7 days' +%F)${tz:+ --tz $tz}"
if command -v calro >/dev/null && [ -S /run/calro/calro.sock ]; then
  json=$(timeout 15 calro $args 2>/dev/null)
elif [ -n "$CALRO_SSH" ]; then
  json=$(timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=3 "$CALRO_SSH" "calro $args" 2>/dev/null)
  [ $? = 127 ] && offline "calro not installed on $CALRO_SSH"
else
  offline "calro not installed"
fi
[ -n "$json" ] || offline "calro not reachable"
echo "$json" | jq -c 'if .error then {state:"offline",reason:.error} else
  {state:"ok", stale:(.stale // false), events:[.events[] | {summary:(if (.summary // "") == "" then "(no title)" else .summary end), start, end, all_day,
   calendar, location:(.location // ""), skip:(.cancelled or .declined), verified}] | .[:40]} end' 2>/dev/null \
  || offline "bad reply from calro"
