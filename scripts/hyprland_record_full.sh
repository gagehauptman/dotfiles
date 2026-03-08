#!/bin/bash
output=$(hyprctl monitors -j | jq -r '.[] | select(.focused) | .name')
f_temp=/tmp/recording_temp.mp4
f=~/recordings/recording_$(date +%Y%m%d_%H%M%S).mp4

echo "$f" > /tmp/qs-recording.path

# Record to a temporary file
wf-recorder -o "$output" -f "$f_temp" --no-dmabuf --codec libx264rgb --pixel-format bgr0 \
  -p preset=fast -p color_range=2

# Add a silent audio track and save to the final destination
ffmpeg -y -f lavfi -i anullsrc -i "$f_temp" -c:v copy -c:a aac -shortest "$f"

# Clean up temp file
rm "$f_temp"
