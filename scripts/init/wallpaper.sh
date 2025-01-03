#!/bin/sh

pkill swww-daemon
swww init
swww img $(cat /home/victoneux/.config/scripts/wallpaper/wpsave.txt)
