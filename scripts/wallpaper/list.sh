#!/usr/bin/env bash
# Lists the wallpapers, one path per line: each wallpaper lives alone in
# wallpapers/<stem>/ and its main file (image, or <stem>.live for a dynamic
# one) is wallpapers/<stem>/<stem>.<ext>. Sorted by stem.
set -euo pipefail
dir=${XDG_CONFIG_HOME:-$HOME/.config}/wallpapers
for d in "$dir"/*/; do
  stem=$(basename "$d")
  [[ $stem == _* ]] && continue
  for f in "$d$stem".{jpg,jpeg,png,webp,live,JPG,JPEG,PNG,WEBP}; do
    [[ -f $f ]] && { printf "%s\n" "$f"; break; }
  done
done | LC_ALL=C sort -f
