#!/bin/bash

# 1. Take the first parameter ($1) as the selection
selection=$1

# 2. Check if a parameter was actually passed; if not, exit or show an error
if [ -z "$selection" ]; then
  echo "Usage: $0 <wallpaper_path>"
  exit 1
fi

# 3. Apply the wallpaper using swww
swww img --transition-type outer \
  --transition-pos 0.$((RANDOM % 999)),0.$((RANDOM % 999)) \
  --transition-step 25 \
  --transition-fps 120 \
  --transition-duration 0.15 \
  "$selection"

# 4. Save the selection to your tracking file
if [ -n "$selection" ]; then
  echo "$selection" >"$HOME/.config/scripts/wallpaper/wpsave.txt"
fi
