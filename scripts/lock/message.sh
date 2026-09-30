#!/bin/bash
# hyprlock greeting. --plain prints bare text (lockgen adds weight/style via
# markup.sh); without it, the old fixed-weight markup for the static config.

current_hour=$(date +%H)

if (( current_hour >= 0 && current_hour < 12 )); then
    greeting="good morning, $USER"
elif (( current_hour >= 12 && current_hour < 18 )); then
    greeting="good afternoon, $USER"
else
    greeting="good evening, $USER"
fi

[[ $1 == --plain ]] && { echo "$greeting"; exit; }
printf "<span weight='medium'>%s</span>\n" "$greeting"
