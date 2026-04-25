#!/bin/sh

set -u

SAVE_FILE="$HOME/.config/scripts/wallpaper/wpsave.txt"
SELECTION="$(cat "$SAVE_FILE" 2>/dev/null || true)"

[ -n "$SELECTION" ] || exit 0

exec "$HOME/.config/scripts/wallpaper/wallpaper_select.sh" "$SELECTION"
