#!/bin/bash
# Toggle CPU governor between performance and powersave
current=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
if [ "$current" = "performance" ]; then
  new="powersave"
else
  new="performance"
fi
for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  echo "$new" > "$f"
done
echo "$new"
