#!/bin/bash
pkill -SIGINT wf-recorder
sleep 0.5
f=$(cat /tmp/qs-recording.path 2>/dev/null)
notify-send -t 3000 "Recording saved" "$f"
rm -f /tmp/qs-recording.path
