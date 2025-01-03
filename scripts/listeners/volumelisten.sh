function thing {
	amixer sget Master | grep 'Front Left:' | awk -F'[][]' '{print $2}' | awk '{print substr($0, 1, length($0)-1)}'
}

thing
pactl subscribe | grep --line-buffered "change" | while read -r _; do thing; done
