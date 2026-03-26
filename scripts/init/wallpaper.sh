#!/bin/sh

pkill awww-daemon
awww-daemon
awww img $(cat $HOME/.config/scripts/wallpaper/wpsave.txt)
