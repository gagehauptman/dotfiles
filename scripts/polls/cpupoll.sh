#!/bin/bash
# CPU usage percentage for the bar, from /proc/stat.
# Used to be `top -bn1 | grep | sed | awk`, which forks four processes and makes
# top walk every /proc entry each poll (2026-10-10). Now one awk reading
# /proc/stat: usage since the previous poll (the deltas are kept in a state
# file; the first run reports the average since boot). Same number as top's
# "100 - id": everything that isn't pure idle, including iowait, to one decimal.
state="${XDG_RUNTIME_DIR:-/tmp}/qs-cpupoll-$UID.state"
awk -v state="$state" '
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
  }' /proc/stat
