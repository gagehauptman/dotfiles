#!/usr/bin/env bash
# Lock the screen: an ext-session-lock client (qs/shell.qml, Quickshell's
# WlSessionLock) that draws the current wallpaper's live Bevy scene itself, so
# no workspace switching or see-through tricks. lockgen.py resolves
# meta/*.toml into JSON for it; PAM (the hyprlock service) checks the password.
# If it dies at startup this falls back to the static hyprlock config, so it
# always locks.
#
#   lock.sh                 lock (Super+L, power menu)
#   lock.sh --test [SECS]   SAFE: same screens as overlay windows, NOT a lock,
#                           gone after SECS (default 15). PAM uses a fixture
#                           that accepts only the password "letmein".
#   lock.sh --try [SECS]    real lock that unlocks itself after SECS (default 10)
#   lock.sh --preview [DIR] SAFEST: render every monitor's lock screen offscreen
#                           to DIR/<monitor>.png (default $XDG_RUNTIME_DIR/
#                           lockscreen/preview); nothing shows on screen.
#                           LOCK_WALLPAPER=path previews another wallpaper.
#   lock.sh --unlock        unlock a running lock (from a TTY: Ctrl+Alt+F3)
#   lock.sh --recover       lock client died and left the screen on the red
#                           "lock died" screen: start a 3s lock to clear it
LOCK_T0=$(( ${EPOCHREALTIME/./} / 1000 )); export LOCK_T0      # startup timing in lock.log (ms)
dir=$(dirname "$(realpath "$0")")
run=${XDG_RUNTIME_DIR:-/run/user/$UID}
state=$run/lockscreen
mkdir -p "$state"

export XDG_RUNTIME_DIR=$run
[[ -z $WAYLAND_DISPLAY ]] && WAYLAND_DISPLAY=$(cd "$run" && ls -d wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1) && export WAYLAND_DISPLAY
if [[ -z $HYPRLAND_INSTANCE_SIGNATURE ]]; then
  HYPRLAND_INSTANCE_SIGNATURE=$(ls -t "$run/hypr" 2>/dev/null | head -1)
  export HYPRLAND_INSTANCE_SIGNATURE
fi

qs() { quickshell -p "$dir/qs" "$@"; }

case $1 in
  --unlock)  exec quickshell -p "$dir/qs" ipc call lock unlock ;;
  --preview)
    out=${2:-$state/preview}
    mkdir -p "$out"
    wall=(); [[ -n $LOCK_WALLPAPER ]] && wall=(--wallpaper "$LOCK_WALLPAPER")
    python3 "$dir/lockgen.py" "${wall[@]}" --out "$out/lock.json" --check || exit 1
    QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software QML2_IMPORT_PATH=$HOME/.config/quickshell/modules \
      LOCK_CONFIG=$out/lock.json LOCK_PREVIEW_OUT=$out \
      timeout 60 quickshell -p "$dir/qs/preview.qml" >"$out/preview.log" 2>&1
    ls "$out"/*.png
    exit ;;
  --recover)
    hyprctl eval 'hl.config({misc={allow_session_lock_restore=true}})' >/dev/null
    "$0" --try 3
    hyprctl eval 'hl.config({misc={allow_session_lock_restore=false}})' >/dev/null
    exit ;;
esac

mode=lock secs=0
case $1 in
  --test) mode=test secs=${2:-15} ;;
  --try)  secs=${2:-10} ;;
  "") ;;
  *) echo "usage: lock.sh [--test [SECS] | --try [SECS] | --unlock | --recover]" >&2; exit 2 ;;
esac

# One lock at a time (a second Super+L must not start another client).
pgrep -ax quickshell | grep -qE -- "-p $dir/qs( |$)" && exit 0      # not qs/preview.qml
pgrep -xu "$UID" hyprlock >/dev/null && exit 0

conf=$state/lock.json
wall=(); [[ $mode == test && -n $LOCK_WALLPAPER ]] && wall=(--wallpaper "$LOCK_WALLPAPER")   # test only: preview another wallpaper's look
python3 "$dir/lockgen.py" "${wall[@]}" --out "$conf" 2>"$state/lockgen.log" || echo '{"screens":[]}' >"$conf"

export QSG_RHI_BACKEND=vulkan QML2_IMPORT_PATH=$HOME/.config/quickshell/modules
LOCK_CAPS_LEDS=$(printf "%s|" /sys/class/leds/*capslock/brightness 2>/dev/null); export LOCK_CAPS_LEDS
export LOCK_MODE=$mode LOCK_SECONDS=$secs LOCK_CONFIG=$conf LOCK_DIR=$dir
if [[ $mode == test ]]; then
  export LOCK_PAM_DIR=$dir/pam LOCK_PAM_CONFIG=test
  [[ -n $LOCK_TEST_PASSWORD ]] && export LOCK_TEST_PASSWORD
fi

# Watchdog for --try: if the timer inside the lock somehow doesn't fire, ask again over IPC.
if [[ $mode == lock && $secs -gt 0 ]]; then
  ( sleep $((secs + 6)); quickshell -p "$dir/qs" ipc call lock unlock >/dev/null 2>&1 ) &
fi

start=$SECONDS
qs 2>>"$state/lock.log"; rc=$?
[[ $mode == test || $secs -gt 0 ]] && exit $rc
(( rc == 0 || rc == 3 )) && exit 0
# It died. Fall back only if it never got going; a later death is a kill from a
# TTY, don't lock again.
(( SECONDS - start >= 3 )) && exit "$rc"
exec hyprlock
