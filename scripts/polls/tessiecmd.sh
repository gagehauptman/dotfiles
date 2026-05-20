#!/usr/bin/env bash
# Send a command to the first Tessie-managed vehicle.
# Usage: tessiecmd.sh <lock|unlock|start_climate|stop_climate>
# Output: "ok" on success (exit 0); failure reason from the API on error (exit 1).

ACTION="$1"
case "$ACTION" in
  lock|unlock|start_climate|stop_climate) ;;
  *) echo "usage: $0 <lock|unlock|start_climate|stop_climate>" >&2; exit 1 ;;
esac

_die() { echo "$1"; exit 1; }
source "$(dirname "$0")/_tessie.sh"

tessie_load_token
tessie_load_vin

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
