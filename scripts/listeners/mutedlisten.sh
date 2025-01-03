function thing {
	output=$(amixer sget Master | grep 'Front Left:' | awk -F ' ' '{print $6}')
}

thing
if [[ $output == "[on]" ]]; then toshow="󰕾"; else toshow=""; fi && echo $toshow
pactl subscribe | grep --line-buffered "change" | while read -r _; do thing; if [[ $output == "[on]" ]]; then toshow="󰕾"; else toshow=""; fi && echo $toshow; done
