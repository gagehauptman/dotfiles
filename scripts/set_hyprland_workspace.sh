current_mon=$(cat $XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/active_monitor)
hyprctl dispatch workspace $(($current_mon+1))$1
