output=$(cat $XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/active_monitor_2) && time=$(date +"%Y-%m-%d_%H.%M:%S") && grim -o $output "$HOME/screenshots/$time.png" && grim -o $output - | wl-copy
