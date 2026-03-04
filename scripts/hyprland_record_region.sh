#!/bin/bash
region=$(slurp) || exit 1
f=~/recordings/recording_$(date +%Y%m%d_%H%M%S).mp4
echo "$f" > /tmp/qs-recording.path
wf-recorder -g "$region" -f "$f" --codec libx264 -p preset=fast
