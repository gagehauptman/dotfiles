#!/bin/bash
output=$(hyprctl monitors -j | jq -r '.[] | select(.focused) | .name')
f=~/recordings/recording_$(date +%Y%m%d_%H%M%S).mp4
echo "$f" > /tmp/qs-recording.path
wf-recorder -o "$output" -f "$f" --codec libx264 -p preset=fast
