mon_count_str=$(cat $XDG_RUNTIME_DIR//hypr/$HYPRLAND_INSTANCE_SIGNATURE/mon_count)
mon_count=$(($mon_count_str))

for ((i=0; i<mon_count; i++))
do
    eww open --toggle "bar$i"
done

