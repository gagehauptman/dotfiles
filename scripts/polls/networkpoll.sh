#!/bin/bash

# Get primary network interface (exclude lo)
interface=$(ip route | grep default | awk '{print $5}' | head -1)

if [ -z "$interface" ]; then
  echo "N/A|0|0|0|0"
  exit 0
fi

# Get current stats
rx_bytes=$(cat /sys/class/net/$interface/statistics/rx_bytes 2>/dev/null || echo 0)
tx_bytes=$(cat /sys/class/net/$interface/statistics/tx_bytes 2>/dev/null || echo 0)

# Store in temp file for delta calculation
temp_file="/tmp/networkpoll_${interface}.tmp"

if [ -f "$temp_file" ]; then
  read old_rx old_tx old_time < "$temp_file"
  current_time=$(date +%s)
  time_diff=$((current_time - old_time))
  
  if [ $time_diff -gt 0 ]; then
    rx_rate=$(( (rx_bytes - old_rx) / time_diff ))
    tx_rate=$(( (tx_bytes - old_tx) / time_diff ))
  else
    rx_rate=0
    tx_rate=0
  fi
else
  rx_rate=0
  tx_rate=0
fi

# Save current values
echo "$rx_bytes $tx_bytes $(date +%s)" > "$temp_file"

# Convert to human-readable
rx_total=$(numfmt --to=iec-i --suffix=B $rx_bytes 2>/dev/null || echo "0B")
tx_total=$(numfmt --to=iec-i --suffix=B $tx_bytes 2>/dev/null || echo "0B")

# Convert rates to human-readable
rx_rate_human=$(numfmt --to=iec-i --suffix=B/s $rx_rate 2>/dev/null || echo "0B/s")
tx_rate_human=$(numfmt --to=iec-i --suffix=B/s $tx_rate 2>/dev/null || echo "0B/s")

echo "$interface|$rx_total|$tx_total|$rx_rate_human|$tx_rate_human"
