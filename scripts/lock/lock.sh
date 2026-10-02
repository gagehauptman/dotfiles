#!/usr/bin/env bash
# Lock the screen: an ext-session-lock client (qs/shell.qml, Quickshell's
# WlSessionLock) that draws the current wallpaper's live Bevy scene itself, so
# no workspace switching or see-through tricks. lockgen.py resolves
# meta/*.toml into JSON for it; PAM (the hyprlock service) checks the password.
# If it dies at startup this falls back to the static hyprlock config, so it
# always locks.
#
#   lock.sh                 lock (Super+L, power menu): shows the resident
#                           lock if one is running, else starts a fresh one
#   lock.sh --warm          make the caches and start the resident lock hidden
#                           (login), or have it re-read its settings (wallpaper
#                           change). Hidden = not locked, see qs/shell.qml.
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
conf=$state/lock.json
pidfile=$state/resident.pid

# The resident (warm, hidden) lock's pid, if it is alive.
resident_pid() {
  local pid
  pid=$(cat "$pidfile" 2>/dev/null) && [[ $pid =~ ^[0-9]+$ ]] || return 1
  tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -qE -- "^quickshell -p $dir/qs ?$" || return 1
  grep -qzx LOCK_RESIDENT=1 "/proc/$pid/environ" 2>/dev/null || return 1     # not a fresh lock that got the pid
  echo "$pid"
}
lock_env() {   # MODE SECS
  export QSG_RHI_BACKEND=vulkan QML2_IMPORT_PATH=$HOME/.config/quickshell/modules
  LOCK_CAPS_LEDS=$(printf "%s|" /sys/class/leds/*capslock/brightness 2>/dev/null); export LOCK_CAPS_LEDS
  export LOCK_MODE=$1 LOCK_SECONDS=$2 LOCK_CONFIG=$conf LOCK_DIR=$dir
}
# Live scenes: Hyprland draws the desktop under the lock (session_lock_xray)
# while the lock's own scene starts (~0.7 s; LockSurface `bridging` keeps the
# background see-through until then), so the running wallpaper stays on screen
# instead of a stale poster frame. Off again 5 s later, the lock is opaque by then.
xray_bridge() {
  grep -qE '"kind": ?"live"' "$conf" || return 0
  hyprctl eval 'hl.config({misc={session_lock_xray=true}})' >/dev/null
  setsid -f sh -c "sleep 5; hyprctl eval 'hl.config({misc={session_lock_xray=false}})'" </dev/null >/dev/null 2>&1
}
lockgen() { python3 "$dir/lockgen.py" "$@" --out "$conf" 2>"$state/lockgen.log" || echo '{"screens":[]}' >"$conf"; }

case $1 in
  --unlock)
    for pid in $(pgrep -ax quickshell | grep -E -- "-p $dir/qs( |$)" | cut -d' ' -f1); do
      quickshell ipc --pid "$pid" call lock unlock
    done
    exit ;;
  --warm)
    lockgen
    if pid=$(resident_pid); then
      timeout 2 quickshell ipc --pid "$pid" call lock reload >/dev/null 2>&1
      exit 0
    fi
    # Niced (wallpaper_select.sh --warm runs at nice 19): only the caches; the
    # lock itself must not run at idle priority. Login and the first lock start it.
    (( $(nice) > 0 )) && exit 0
    lock_env lock 0
    LOCK_RESIDENT=1 setsid quickshell -p "$dir/qs" </dev/null >/dev/null 2>>"$state/lock.log" &
    echo $! >"$pidfile"
    exit 0 ;;
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
    hyprctl eval 'hl.config({misc={session_lock_xray=false}})' >/dev/null
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
  *) echo "usage: lock.sh [--warm | --test [SECS] | --try [SECS] | --unlock | --recover]" >&2; exit 2 ;;
esac

pgrep -xu "$UID" hyprlock >/dev/null && exit 0

# The resident lock: lock only counts once the compositor confirms it
# ("secure"). No answer, an error or no confirmation within ~3 s: kill it and
# start a fresh lock below (which falls back to hyprlock if it dies at once).
rpid=$(resident_pid)
if [[ $mode == lock && $secs == 0 && -n $rpid ]]; then
  lockgen
  xray_bridge
  case $(timeout 2 quickshell ipc --pid "$rpid" call lock engage 2>/dev/null) in
    ok|shown)
      for _ in {1..40}; do
        if [[ $(timeout 1 quickshell ipc --pid "$rpid" call lock state 2>/dev/null) == secure ]]; then
          echo "lock.sh: resident lock secure $(( ${EPOCHREALTIME/./} / 1000 - LOCK_T0 )) ms after the key" >>"$state/lock.log"
          exit 0
        fi
        kill -0 "$rpid" 2>/dev/null || break
        sleep 0.05
      done ;;
  esac
  echo "lock.sh: the resident lock ($rpid) did not lock; starting a fresh one" >>"$state/lock.log"
  kill -9 "$rpid" 2>/dev/null
  rm -f "$pidfile"
  sleep 0.3
fi

# One lock at a time (a second Super+L must not start another client).
pgrep -ax quickshell | grep -E -- "-p $dir/qs( |$)" | grep -qv "^${rpid:-none} " && exit 0      # not qs/preview.qml

wall=(); [[ $mode == test && -n $LOCK_WALLPAPER ]] && wall=(--wallpaper "$LOCK_WALLPAPER")   # test only: preview another wallpaper's look
lockgen "${wall[@]}"

lock_env "$mode" "$secs"
[[ $mode == lock ]] && xray_bridge
if [[ $mode == test ]]; then
  export LOCK_PAM_DIR=$dir/pam LOCK_PAM_CONFIG=test
  [[ -n $LOCK_TEST_PASSWORD ]] && export LOCK_TEST_PASSWORD
fi

# Watchdog for --try: if the timer inside the lock somehow doesn't fire, ask again over IPC.
if [[ $mode == lock && $secs -gt 0 ]]; then
  ( sleep $((secs + 6)); "$0" --unlock >/dev/null 2>&1 ) &
fi

start=$SECONDS
qs 2>>"$state/lock.log"; rc=$?
[[ $mode == test || $secs -gt 0 ]] && exit $rc
# Unlocked normally: keep a resident lock for next time.
(( rc == 0 )) && exec "$0" --warm
(( rc == 3 )) && exit 0
# It died. Fall back only if it never got going; a later death is a kill from a
# TTY, don't lock again.
(( SECONDS - start >= 3 )) && exit "$rc"
exec hyprlock
