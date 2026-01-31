#!/bin/bash
# Simple weather fetch using wttr.in
curl -s "wttr.in/?format=%c+%t" 2>/dev/null | head -1 || echo "Weather unavailable"
