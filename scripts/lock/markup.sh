#!/bin/bash
# Wrap stdin in pango markup for a hyprlock label (hyprlock has no weight or
# style option, and markup only renders from cmd[] output).
# usage: markup.sh <weight> [normal|italic]
w=${1:-normal} s=${2:-normal}
t=$(sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
printf "<span weight='%s' style='%s'>%s</span>\n" "$w" "$s" "$t"
