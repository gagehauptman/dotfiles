#!/bin/bash
# hyprlock greeting. Weight is pango markup since hyprlock has no font_weight;
# keep it matched to the clock label in hyprlock.conf.

current_hour=$(date +%H)

if (( current_hour >= 0 && current_hour < 12 )); then
    greeting="good morning, $USER"
elif (( current_hour >= 12 && current_hour < 18 )); then
    greeting="good afternoon, $USER"
else
    greeting="good evening, $USER"
fi

printf "<span weight='medium'>%s</span>\n" "$greeting"
