options=("󰤆" "" "󰌾" "󰿅")
selection=$(rofi -dmenu -theme power.rasi <<< $(printf '%s\n' "${options[@]}"))
''
case $selection in

    󰤆)
        systemctl poweroff
        kill -9 $$
        ;;
    )
        systemctl reboot
        kill -9 $$
        ;;
    󰌾)
        ~/.config/scripts/lock.sh
        ;;
    󰿅)
        pkill Hyprland
        kill -9 $$
        ;;
esac

