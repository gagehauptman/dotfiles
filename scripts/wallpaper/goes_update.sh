#!/bin/bash
# GOES Earth Live Wallpaper Updater
# Always fetches latest image, only applies if selected

GOES_WALLPAPER="$HOME/.config/wallpapers/goes_earth_live.png"
WPSAVE="$HOME/.config/scripts/wallpaper/wpsave.txt"

# Always update the image (so it's fresh when switching to it)
goes-imagery -q --sat goes-west -s 2048 -p 2.1 -o "$GOES_WALLPAPER"

# Only apply with swww if GOES wallpaper is currently selected
current_wallpaper=$(cat "$WPSAVE" 2>/dev/null | tr -d '\n\r')

if [ "$current_wallpaper" = "$GOES_WALLPAPER" ]; then
    export WAYLAND_DISPLAY=wayland-1
    swww img "$GOES_WALLPAPER" \
        --transition-type fade \
        --transition-duration 2
fi
