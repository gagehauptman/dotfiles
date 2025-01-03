status=$(cat /sys/class/power_supply/BAT0/status)
percent=$(acpi | grep "Battery 0" | grep -o "[0-9]*%")

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
