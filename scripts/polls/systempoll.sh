#!/bin/bash

# CPU usage
cpu_usage=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')

# RAM usage
ram_used=$(free -m | awk 'NR==2{printf "%.1f", $3/1024}')
ram_total=$(free -m | awk 'NR==2{printf "%.1f", $2/1024}')
ram_percent=$(free | awk 'NR==2{printf "%.0f", $3*100/$2}')

# Disk usage (root partition)
disk_used=$(df -h / | awk 'NR==2{print $3}')
disk_total=$(df -h / | awk 'NR==2{print $2}')
disk_percent=$(df / | awk 'NR==2{print $5}' | sed 's/%//')

# CPU governor
governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)

# GPU power profile (card1 = 6500M dGPU)
gpu_profile_idx=$(grep '\*' /sys/class/drm/card1/device/pp_power_profile_mode 2>/dev/null | awk '{print $1}')
gpu_profile_name=$(grep '\*' /sys/class/drm/card1/device/pp_power_profile_mode 2>/dev/null | sed 's/^[[:space:]]*[0-9]*//' | sed 's/\*.*//' | xargs)
[ -z "$gpu_profile_idx" ] && gpu_profile_idx="0" && gpu_profile_name="BOOTUP_DEFAULT"

echo "$cpu_usage|$ram_used|$ram_total|$ram_percent|$disk_used|$disk_total|$disk_percent|$governor|$gpu_profile_idx|$gpu_profile_name"
