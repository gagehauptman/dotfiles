#!/usr/bin/env bash
# Lists the wallpapers, one path per line: each wallpaper lives alone in
# wallpapers/<stem>/ and its main file (image, or <stem>.live for a dynamic
# one) is wallpapers/<stem>/<stem>.<ext>. Sorted by stem.
#
# Per-device changes (untracked) come from wallpapers/local.conf, see
# wallpapers/local.conf.example. Directives, one per line, "#" comments:
#   add <path>       a folder of wallpaper folders (<stem>/<stem>.<ext>) and/or
#                    loose images, or one image file; "~" and $HOME expand
#   disable <stem>   hide a wallpaper (repo or added) by its stem
#   repo off         hide every wallpaper shipped in the repo
#   active <stem>    the wallpaper init/wallpaper.sh applies at login
#
# list.sh            all enabled wallpapers
# list.sh --active   the path of the `active` wallpaper (nothing if unset/gone)
# list.sh --first    the first enabled wallpaper (fallback when the saved one is gone)
set -euo pipefail
dir=${XDG_CONFIG_HOME:-$HOME/.config}/wallpapers
conf=${WALLPAPER_CONF:-$dir/local.conf}
exts=(jpg jpeg png webp live JPG JPEG PNG WEBP)

repo=on active=""
adds=()
declare -A off=()
if [[ -f $conf ]]; then
  while read -r key val; do
    val=${val%%[[:space:]]#*}
    val=${val%"${val##*[![:space:]]}"}
    val=${val/#\~/$HOME}
    val=${val//\$HOME/$HOME}
    case $key in
      add) [[ -n $val ]] && adds+=("$val") ;;
      disable) off[${val%.*}]=1; off[$val]=1 ;;
      repo) [[ $val == off ]] && repo=off ;;
      active) active=${val%.*} ;;
    esac
  done < <(grep -v "^[[:space:]]*#" "$conf" || true)
fi

# Prints the main file of <root>/<stem>/, if it has one.
folder_main() {
  local d=${1%/} stem f ext
  stem=${d##*/}
  for ext in "${exts[@]}"; do
    f=$d/$stem.$ext
    [[ -f $f ]] && { printf "%s\n" "$f"; return 0; }
  done
  return 1
}

# Lists one root: wallpaper folders plus (for added roots) loose images.
list_root() {
  local root=${1%/} loose=$2 d f
  for d in "$root"/*/; do
    [[ -d $d ]] || continue
    [[ $(basename "$d") == _* ]] && continue
    folder_main "$d" || true
  done
  [[ $loose == loose ]] || return 0
  for f in "$root"/*; do
    [[ -f $f ]] || continue
    case ${f##*.} in jpg|jpeg|png|webp|JPG|JPEG|PNG|WEBP) printf "%s\n" "$f" ;; esac
  done
}

all() {
  [[ $repo == off ]] || list_root "$dir" repo
  local a
  for a in "${adds[@]}"; do
    if [[ -f $a ]]; then printf "%s\n" "$a"
    elif [[ -d $a ]]; then
      # An added dir may itself be one wallpaper folder.
      folder_main "$a" 2>/dev/null || list_root "$a" loose
    fi
  done
}

# Drops disabled stems and repeated stems (repo first, then `add` order).
enabled() {
  local -A seen=()
  local f stem
  while IFS= read -r f; do
    stem=${f##*/}; stem=${stem%.*}
    [[ -n ${off[$stem]:-} || -n ${seen[$stem]:-} ]] && continue
    seen[$stem]=1
    printf "%s\n" "$f"
  done
}

# Sorted by stem (tab-separated key, then the path).
list=$(all | enabled | awk -F/ '{n=$NF; sub(/\.[^.]*$/,"",n); print n "\t" $0}' | LC_ALL=C sort -f -s -t$'\t' -k1,1 | cut -f2-)
case ${1:-} in
  --active)
    [[ -z $active ]] || awk -F/ -v s="$active" '{n=$NF; sub(/\.[^.]*$/,"",n); if (n==s) {print; exit}}' <<<"$list" ;;
  --first) head -n1 <<<"$list" ;;
  *) [[ -z $list ]] || printf "%s\n" "$list" ;;
esac
