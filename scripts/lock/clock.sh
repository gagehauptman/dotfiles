#!/bin/bash
# hyprlock clock. --plain prints bare text (lockgen adds weight/style via
# markup.sh); without it, the old fixed-style markup for the static config.
t=$(date +%H:%M)
[[ $1 == --plain ]] && { echo "$t"; exit; }
printf "<span weight='medium'><i>%s</i></span>\n" "$t"
