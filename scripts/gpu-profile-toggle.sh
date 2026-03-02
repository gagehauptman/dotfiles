#!/bin/bash
# Cycle GPU power profile: 0 (default) -> 1 (3D gaming) -> 2 (power saving) -> 0
CARD="/sys/class/drm/card1/device"
current=$(grep '\*' "$CARD/pp_power_profile_mode" | awk '{print $1}')

case "$current" in
  0) new=1 ;;
  1) new=2 ;;
  *) new=0 ;;
esac

echo "$new" > "$CARD/pp_power_profile_mode"

# Read back the name
name=$(grep '\*' "$CARD/pp_power_profile_mode" | sed 's/^[[:space:]]*[0-9]*//' | sed 's/\*.*//' | xargs)
echo "$new|$name"
