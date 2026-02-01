#!/bin/bash

# Wallpaper selector script
# Handles both regular wallpapers (via swww) and the spinning globe

selection=$1

if [ -z "$selection" ]; then
  echo "Usage: $0 <wallpaper_path>"
  exit 1
fi

GLOBE_BIN="$HOME/.config/scripts/wallpaper/bins/spinning_globe/target/release/layer_shell_bevy"

# Check if this is the spinning globe
if [[ "$selection" == *"spinning_globe"* ]]; then
  # Kill swww if running
  pkill -x swww-daemon 2>/dev/null
  
  # Kill any existing globe instance
  pkill -f "layer_shell_bevy" 2>/dev/null
  sleep 0.1
  
  # Start the spinning globe
  "$GLOBE_BIN" &
  disown
else
  # Kill the spinning globe if running
  pkill -f "layer_shell_bevy" 2>/dev/null
  
  # Make sure swww is running
  if ! pgrep -x swww-daemon >/dev/null; then
    swww-daemon &
    sleep 0.3
  fi
  
  # Apply the wallpaper using swww
  swww img --transition-type outer \
    --transition-pos 0.$((RANDOM % 999)),0.$((RANDOM % 999)) \
    --transition-step 25 \
    --transition-fps 120 \
    --transition-duration 0.15 \
    "$selection"
fi

# Save the selection
echo "$selection" >"$HOME/.config/scripts/wallpaper/wpsave.txt"
