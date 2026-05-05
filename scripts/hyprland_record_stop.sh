#!/bin/bash
pkill -SIGINT wf-recorder
f=$(cat /tmp/qs-recording.path 2>/dev/null)

if [ -n "$f" ]; then
  for _ in {1..30}; do
    [ -f "$f" ] && break
    sleep 0.5
  done
fi

if [ -n "$f" ] && [ -f "$f" ]; then
  notify-send -t 3000 "Recording saved" "$f"
else
  notify-send -t 3000 "Recording stopped" "No file found"
fi
rm -f /tmp/qs-recording.path
