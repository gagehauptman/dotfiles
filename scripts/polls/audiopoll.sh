playerinput=$(playerctl metadata --format '{{xesam:artist}} // {{xesam:title}}')

if [[ $playerinput != "" ]]; then
	echo $info
	eww update show_player=true
else
	echo ""
	eww update show_player=false
fi
