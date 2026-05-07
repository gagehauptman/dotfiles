#!/usr/bin/env bash
# Days since the last `pacman -Syu` on this system, parsed from /var/log/pacman.log.
# Output: <days>  (or "NA" if the log is unreadable / has no upgrade entries)

LOG="/var/log/pacman.log"
[ -r "$LOG" ] || { echo "NA"; exit 0; }

last=$(grep -F "starting full system upgrade" "$LOG" | tail -n 1 | sed -n 's/^\[\([^]]*\)\].*/\1/p')
[ -z "$last" ] && { echo "NA"; exit 0; }

last_epoch=$(date -d "$last" +%s 2>/dev/null) || { echo "NA"; exit 0; }
[ -z "$last_epoch" ] && { echo "NA"; exit 0; }

now_epoch=$(date +%s)
echo $(( (now_epoch - last_epoch) / 86400 ))
