battery=""

for supply in /sys/class/power_supply/*; do
  [ -e "$supply/type" ] || continue
  [ "$(cat "$supply/type")" = "Battery" ] || continue
  battery="$supply"
  break
done

if [ -z "$battery" ] || [ ! -r "$battery/status" ]; then
  exit 0
fi

status=$(cat "$battery/status")

case $status in
    "Full")
        echo "󱟢"
        ;;
    "Charging")
        echo "󰂄"
        ;;
    "Discharging")
        echo "󱟤"
        ;;
    "Not charging")
        echo "󰁿"
        ;;
esac
