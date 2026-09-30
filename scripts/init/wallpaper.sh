#!/bin/sh

set -u

SAVE_FILE="$HOME/.config/scripts/wallpaper/wpsave.txt"
LIST="$HOME/.config/scripts/wallpaper/list.sh"

# Per-device wallpapers/local.conf: `active <stem>` wins over the saved
# selection; a saved wallpaper that is now disabled or gone falls back to the
# first enabled one (see list.sh).
SELECTION="$("$LIST" --active 2>/dev/null || true)"
[ -n "$SELECTION" ] || SELECTION="$(cat "$SAVE_FILE" 2>/dev/null || true)"
[ -n "$SELECTION" ] || exit 0

stem="${SELECTION##*/}"
stem="${stem%.*}"
"$LIST" 2>/dev/null | grep -qE "/$stem\.[^/]*\$" || SELECTION="$("$LIST" --first 2>/dev/null || true)"
[ -n "$SELECTION" ] || exit 0

exec "$HOME/.config/scripts/wallpaper/wallpaper_select.sh" "$SELECTION"
