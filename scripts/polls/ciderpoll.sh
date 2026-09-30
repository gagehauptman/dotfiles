#!/bin/bash
# Cider (Apple Music) now-playing line for the bar music widget.
# Cider's MPRIS metadata is empty, so read its local API instead.
# Prints Cider<QSMUSIC>Playing|Paused<QSMUSIC>artist<QSMUSIC>title, or nothing if Cider is not reachable.
api=http://127.0.0.1:10767/api/v1/playback
np=$(curl -sf -m2 "$api/now-playing") || exit 0
playing=$(curl -sf -m2 "$api/is-playing" | jq -r 'if .is_playing then "Playing" else "Paused" end') || exit 0
echo "$np" | jq -r --arg s "$playing" 'select(.info.name) | "Cider<QSMUSIC>\($s)<QSMUSIC>\(.info.artistName // "")<QSMUSIC>\(.info.name)"'
