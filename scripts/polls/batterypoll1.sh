battery=""

for supply in /sys/class/power_supply/*; do
  [ -e "$supply/type" ] || continue
  [ "$(cat "$supply/type")" = "Battery" ] || continue
  battery="$supply"
  break
done

if [ -n "$battery" ] && [ -r "$battery/capacity" ]; then
  cat "$battery/capacity"
  exit 0
fi

if command -v acpi >/dev/null 2>&1; then
  percent=$(acpi -b 2>/dev/null | head -n 1 | grep -o "[0-9]*%")
  [ -n "$percent" ] && echo "${percent/%?/}"
fi

exit 0
