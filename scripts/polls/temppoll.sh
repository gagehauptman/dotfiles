#!/bin/bash

# Get the last line of the first 3 lines from 'sensors' command
input=$(sensors | head -n 3 | tail -n 1)

# Extract the current temperature (number after '+' before '°C')
current=$(echo "$input" | grep -oP '\+\K\d+\.\d+' | head -1)

echo $current
