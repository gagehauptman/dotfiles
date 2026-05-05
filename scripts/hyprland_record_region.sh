#!/bin/bash
region=$(slurp) || exit 1
mkdir -p "$HOME/recordings"
f_temp="/tmp/recording_$$.mp4"
f="$HOME/recordings/recording_$(date +%Y%m%d_%H%M%S).mp4"

echo "$f" > /tmp/qs-recording.path

# Record H.264 in yuv420p so the MP4 works in common players and chat apps.
wf-recorder -g "$region" -f "$f_temp" --no-dmabuf --codec libx264 --pixel-format yuv420p \
  -p preset=fast -p crf=23

# Add a silent AAC track and move metadata to the front for streaming/sharing.
ffmpeg -y -f lavfi -i anullsrc -i "$f_temp" -c:v copy -c:a aac -shortest \
  -movflags +faststart "$f"

rm -f "$f_temp"
