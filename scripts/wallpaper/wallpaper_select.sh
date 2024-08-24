selection=$(ls $HOME/.config/wallpapers | while read A ; do  echo -en "$A\x00icon\x1f/$HOME/.config/wallpapers/$A\n";  done | rofi -dmenu -theme select.rasi )

swww img --transition-type outer --transition-pos 0.$((RANDOM % 999)),0.$((RANDOM % 999)) --transition-step 255 --transition-fps 120 $HOME/.config/wallpapers/$selection

if [ -n "$selection" ]; then
    echo $HOME/.config/wallpapers/$selection > $HOME/.config/scripts/wallpaper/wpsave.txt
fi

