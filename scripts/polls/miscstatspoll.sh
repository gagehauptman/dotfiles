#!/bin/bash

# Uptime
uptime_val=$(uptime -p | sed 's/up //')

# Load average
load_avg=$(uptime | awk -F'load average:' '{print $2}' | xargs)

# Process count
process_count=$(ps aux | wc -l)

# Kernel version
kernel=$(uname -r)

# User count
user_count=$(who | wc -l)

echo "$uptime_val|$load_avg|$process_count|$kernel|$user_count"
