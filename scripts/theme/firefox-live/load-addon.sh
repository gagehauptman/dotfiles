#!/usr/bin/env bash
# Load extension/ as a temporary add-on into the running Firefox by driving about:debugging
# with Hyprland send_shortcut (no input tools needed). Needs the Firefox window on a visible workspace.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd -P)
addr() { hyprctl clients -j | python3 -c "import json,sys;print(next((c['address'] for c in json.load(sys.stdin) if c['class']=='$1' or '$1' in c['title']),''))"; }
key() { hyprctl dispatch "hl.dsp.send_shortcut({ mods = '$2', key = '$3', window = 'address:$1' })" >/dev/null; sleep 0.15; }
ff=$(addr firefox); [[ -n $ff ]] || { echo "no Firefox window" >&2; exit 1; }
firefox "about:debugging#/runtime/this-firefox" >/dev/null 2>&1 & sleep 3
key "$ff" CTRL L; for _ in 1 2 3 4 5 6 7 8; do key "$ff" "" Tab; done   # -> "Load Temporary Add-on..."
key "$ff" "" Return; sleep 2
dlg=$(addr "Select manifest.json"); [[ -n $dlg ]] || { echo "file dialog did not open" >&2; exit 1; }
printf %s "$HERE/extension/manifest.json" | wl-copy >/dev/null 2>&1
key "$dlg" CTRL L; key "$dlg" CTRL V; sleep 0.3; key "$dlg" "" Return
key "$ff" CTRL W   # close the about:debugging tab
