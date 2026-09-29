#!/usr/bin/env bash
# Install the fonts the wallpaper themes use, per user (no sudo), and add a
# fontconfig rule so each falls back to the Nerd Font symbols for icon glyphs.
# Restart Quickshell afterwards: Qt reads the font list once at start.
# Where a family is packaged you can use pacman instead (ttf-cormorant,
# ttf-jetbrains-mono, ttf-ibm-plex, ttf-lato, ttf-montserrat, ...); this
# fetches the OFL fonts straight from github.com/google/fonts.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
dest=${XDG_DATA_HOME:-$HOME/.local/share}/fonts/wallpaper-themes
mkdir -p "$dest"; cd "$dest"
for d in cormorantgaramond ebgaramond playfairdisplay lora orbitron rajdhani spacegrotesk oxanium \
         sharetechmono ibmplexmono jetbrainsmono spacemono quicksand nunito dmsans outfit josefinsans; do
  curl -fsS "https://api.github.com/repos/google/fonts/contents/ofl/$d" | python3 -c "
import sys, json
for f in json.load(sys.stdin):
    n = f[\"name\"]
    if n.endswith(\".ttf\") and (\"Italic\" not in n or \"$d\" in (\"cormorantgaramond\", \"ebgaramond\", \"lora\")):
        print(f[\"download_url\"])" | while read -r u; do
    n=$(python3 -c "import urllib.parse,sys; print(urllib.parse.unquote(sys.argv[1].rsplit(\"/\",1)[1]))" "$u")
    [[ -s $n ]] || curl -fsS -o "$n" "$u"
  done
done
conf=${XDG_CONFIG_HOME:-$HOME/.config}/fontconfig/conf.d/61-wallpaper-theme-symbols.conf
mkdir -p "$(dirname "$conf")"
python3 - "$here/../../wallpapers" "$conf" <<PY
import glob, json, sys
fams = set()
for f in glob.glob(sys.argv[1] + "/*/theme.json") + glob.glob(sys.argv[1] + "/_presets/*.json"):
    fams.update(json.load(open(f))["fonts"].values())
fams.discard("monospace")
x = ["<?xml version=\"1.0\"?>", "<!DOCTYPE fontconfig SYSTEM \"urn:fontconfig:fonts.dtd\">", "<fontconfig>"]
x += ["  <match target=\"pattern\"><test name=\"family\" qual=\"any\"><string>%s</string></test><edit name=\"family\" mode=\"append\"><string>Symbols Nerd Font</string></edit></match>" % n for n in sorted(fams)]
open(sys.argv[2], "w").write("\n".join(x + ["</fontconfig>"]) + "\n")
PY
fc-cache -f "$dest"
echo "fonts installed in $dest; restart quickshell to pick them up"
