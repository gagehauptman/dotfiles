#!/bin/sh

echo 0 > $XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/active_monitor
echo $(hyprctl monitors | head -n 1 | cut -d ' ' -f 2) > $XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/active_monitor_2

function handle {
	case $1 in
		focusedmon*)
			new="${1:12}"
			len=${#new}
			new="${new::length-3}"
			echo $new > $XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/active_monitor_2
			monitor_response=$(hyprctl monitors | grep "r $new")
			len2=${#monitor_response}
			mon_id="${monitor_response:length-3}"
			mon_id="${mon_id::1}"
			echo $mon_id > $XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/active_monitor
			;;
		monitoradded*)
			$HOME/.config/scripts/init/main.sh
			;;
		workspace*)
			case $1 in
				workspacev2*)
				;;
				*)
				new="${1:11}"
				mon="${new:0:1}"
				for i in 0 1 2 3 4 5 6 7 8 9; do
					if [[ $mon$i == $new ]]; then
						eww update workspace$new="active_workspace" &
						eww update workspacewidth$new=22 &
					else
						eww update workspace$mon$i="inactive_workspace" &
						eww update workspacewidth$mon$i=13 &
					fi
				done

				;;
			esac

	esac
}

socat -t 86400 -U - UNIX-CONNECT:$XDG_RUNTIME_DIR/hypr/$(echo $HYPRLAND_INSTANCE_SIGNATURE)/.socket2.sock | while read -r line; do handle "$line"; done
