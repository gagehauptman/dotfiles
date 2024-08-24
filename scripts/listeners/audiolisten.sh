function handle {
    if [[ $1 != "" ]]; then
        eww update show_player=true
    else
        eww update show_player=false
    fi
    echo $1
}

playerctl --follow metadata --player=spotify --format '{{xesam:artist}} // {{xesam:title}}' | while read -r line; do handle "$line"; done