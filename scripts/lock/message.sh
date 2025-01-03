#!/bin/sh

#!/bin/bash

current_hour=$(date +%H)

if (( current_hour >= 0 && current_hour < 12 )); then
    echo "good morning, $USER"
elif (( current_hour >= 12 && current_hour < 18 )); then
    echo "good afternoon, $USER"
else
    echo "good evening, $USER"
fi

