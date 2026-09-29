#!/usr/bin/env bash
# Install the fonts the wallpaper themes use, per user (no sudo), and link the
# fontconfig rule that makes every font fall back to Symbols Nerd Font for the
# icon glyphs. Also needs the packages ttf-nerd-fonts-symbols (the icons) and
# ttf-jetbrains-mono-nerd (the presets' mono font).
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
confd=${XDG_CONFIG_HOME:-$HOME/.config}/fontconfig/conf.d
mkdir -p "$confd"
rm -f "$confd/61-wallpaper-theme-symbols.conf"   # the old per-family list; it went stale whenever a theme changed font
ln -sfn "$here/fontconfig/60-nerd-symbols-fallback.conf" "$confd/60-nerd-symbols-fallback.conf"
fc-cache -f "$dest"
echo "fonts installed in $dest; restart quickshell to pick them up"
