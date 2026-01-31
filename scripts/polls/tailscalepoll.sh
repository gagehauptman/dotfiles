#!/bin/bash

# Get tailscale status in JSON format and parse it
tailscale status --json | jq -r '.Peer | to_entries[] | .value | "\(.DNSName)|\(.Online)|\(.TailscaleIPs[0])"' | while IFS='|' read -r dnsname online ip; do
  # Extract hostname from DNSName (strip domain suffix)
  hostname=$(echo "$dnsname" | cut -d'.' -f1)
  
  # Determine status
  if [ "$online" = "true" ]; then
    status="online"
    # Try to get ping time if online
    ping_result=$(timeout 1 tailscale ping "$ip" 2>/dev/null | grep -oP 'pong from.*\K[0-9.]+ms' | head -1)
    if [ -n "$ping_result" ]; then
      echo "$hostname|$status|$ping_result"
    else
      echo "$hostname|$status|N/A"
    fi
  else
    echo "$hostname|offline|N/A"
  fi
done
