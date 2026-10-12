#!/usr/bin/env bash
# Wi-Fi state for the control center's Quick settings page (quickshell/QuickSettings.qml),
# polled only while that page is showing. Tab-separated lines:
#   radio <enabled|disabled|missing>
#   net   <in use 0/1> <signal 0-100> <saved profile 0/1> <security or --> <ssid>
# From the last scan (--rescan no): cheap, and NetworkManager rescans on its own.

command -v nmcli >/dev/null 2>&1 || { printf 'radio\tmissing\n'; exit 0; }

printf 'radio\t%s\n' "$(nmcli radio wifi 2>/dev/null)"

declare -A known seen
while IFS= read -r line; do
  [[ $line == *:802-11-wireless ]] && known["${line%:802-11-wireless}"]=1
done < <(nmcli -t -e no -f NAME,TYPE connection show 2>/dev/null)

# SSID last: with escaping off, `read` hands it every remaining colon intact.
# Sorted so each SSID's first line is the access point in use, else the strongest.
while IFS=: read -r inuse signal security ssid; do
  [[ -z $ssid || -n ${seen[$ssid]} ]] && continue   # hidden networks, extra access points of one SSID
  seen[$ssid]=1
  [[ $inuse == '*' ]] && inuse=1 || inuse=0
  printf 'net\t%s\t%s\t%s\t%s\t%s\n' "$inuse" "$signal" "${known[$ssid]:-0}" "${security:---}" "$ssid"
done < <(nmcli -t -e no -f IN-USE,SIGNAL,SECURITY,SSID device wifi list --rescan no 2>/dev/null | sort -t: -k1,1r -k2,2nr)
