#!/usr/bin/env bash
# One-time, needs sudo: install autoconfig/ into the Firefox install dir so every Firefox start loads
# extension/ (the live wallpaper theme) as a temporary add-on. Not owned by the firefox package, so
# it survives upgrades. Existing different files are backed up as *.bak-wallpaper-theme.
# Usage: install-autoconfig.sh [firefox-install-dir]   (default: dir of the firefox binary, /usr/lib/firefox)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd -P)
dir=${1:-}
if [[ -z $dir ]]; then
  bin=$(command -v firefox || true)
  for d in /usr/lib/firefox /usr/lib64/firefox /opt/firefox; do [[ -f $d/application.ini ]] && { dir=$d; break; }; done
  [[ -n $bin && -f $(dirname "$(readlink -f "$bin")")/application.ini ]] && dir=$(dirname "$(readlink -f "$bin")")
fi
[[ -n $dir && -f $dir/application.ini ]] || { echo "Firefox install dir not found; pass it as argument" >&2; exit 1; }
put() {  # src dest
  if [[ -e $2 ]] && ! cmp -s "$1" "$2"; then sudo cp -a "$2" "$2.bak-wallpaper-theme"; fi
  sudo install -Dm644 "$1" "$2"
}
put "$HERE/autoconfig/autoconfig.js" "$dir/defaults/pref/autoconfig.js"
put "$HERE/autoconfig/firefox.cfg" "$dir/firefox.cfg"
echo "installed into $dir; restart Firefox"
