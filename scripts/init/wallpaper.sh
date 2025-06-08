#!/bin/sh

pkill swww-daemon
swww-daemon
swww img $(cat $HOME/.config/scripts/wallpaper/wpsave.txt)
