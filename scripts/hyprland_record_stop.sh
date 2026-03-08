#!/bin/bash
pkill -SIGINT wf-recorder
sleep 0.5
f=$(cat /tmp/qs-recording.path 2>/dev/null)
if [ -n "$f" ] && [ -f "$f" ]; then
  # Transcode RGB→YUV for compatibility (Telegram, Discord, etc.)
  tmp="${f%.mp4}_yuv.mp4"
  ffmpeg -y -i "$f" -c:v libx264 -preset fast -crf 18 \
    -pix_fmt yuv420p -colorspace bt709 -color_primaries bt709 -color_trc bt709 \
    -color_range pc -movflags +faststart "$tmp" 2>/dev/null && \
    mv "$tmp" "$f"
  notify-send -t 3000 "Recording saved" "$f"
else
  notify-send -t 3000 "Recording stopped" "No file found"
fi
rm -f /tmp/qs-recording.path
