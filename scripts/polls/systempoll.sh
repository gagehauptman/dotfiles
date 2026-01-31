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

echo "$cpu_usage|$ram_used|$ram_total|$ram_percent|$disk_used|$disk_total|$disk_percent"
