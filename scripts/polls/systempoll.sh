#!/bin/bash
# System resources for the dashboard card (SystemStatsWidget.qml), one line:
#   cpu_usage|ram_used_gb|ram_total_gb|ram_percent|disk_used|disk_total|disk_percent
#
# 2026-10-10: trimmed from ~12 forks a poll (top, grep, sed, 3x free, 3x df,
# 7x awk) to four (awk, free, df, awk) with the same output: the CPU figure is
# read from /proc/stat like cpupoll.sh (usage since the previous poll, to one
# decimal, iowait counted as busy like top's "100 - id"), RAM from one
# `free -m` and disk from one `df -h /`.

# CPU usage (since the last poll; own state file so it doesn't share deltas with cpupoll.sh)
state="${XDG_RUNTIME_DIR:-/tmp}/qs-systempoll-$UID.state"
cpu_usage=$(awk -v state="$state" '
  /^cpu / {
    idle = $5; total = 0
    for (i = 2; i <= NF; i++) total += $i
    pt = 0; pi = 0
    if ((getline line < state) > 0) { split(line, p, " "); pt = p[1]; pi = p[2] }
    close(state)
    printf "%d %d\n", total, idle > state
    dt = total - pt; di = idle - pi
    if (dt <= 0) { print 0; exit }
    id = sprintf("%.1f", 100 * di / dt) + 0
    print 100 - id
    exit
  }' /proc/stat)

# RAM usage: used GB, total GB (one decimal), used percent (rounded)
read -r ram_used ram_total ram_percent < <(free -m | awk 'NR==2{printf "%.1f %.1f %.0f\n", $3/1024, $2/1024, $3*100/$2}')

# Disk usage (root partition)
read -r disk_used disk_total disk_percent < <(df -h / | awk 'NR==2{sub("%", "", $5); print $3, $2, $5}')

echo "$cpu_usage|$ram_used|$ram_total|$ram_percent|$disk_used|$disk_total|$disk_percent"
