#!/usr/bin/env bash
set -euo pipefail

selection=${1:?Usage: $0 <wallpaper_path>}

CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
CACHE_HOME=${XDG_CACHE_HOME:-$HOME/.cache}
SAVE_FILE="$CONFIG_HOME/scripts/wallpaper/wpsave.txt"
BIN_ROOT="$CONFIG_HOME/scripts/wallpaper/bins"
STATE_DIR="$CACHE_HOME/wallpaper_select"
PID_FILE="$STATE_DIR/dynamic.pid"
LOG_DIR="$STATE_DIR/logs"

mkdir -p "$(dirname "$SAVE_FILE")" "$LOG_DIR"

exec 9>"$STATE_DIR/lock"
flock -x 9

stem=${selection##*/}
stem=${stem%.*}
bin_dir="$BIN_ROOT/$stem"

alive() {
  [[ ${1:-} =~ ^[0-9]+$ ]] && kill -0 "$1" 2>/dev/null
}

stop_dynamic() {
  local pid
  pid=$(cat "$PID_FILE" 2>/dev/null || true)
  rm -f "$PID_FILE"
  alive "$pid" || return 0

  kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
  sleep 0.15
  alive "$pid" && kill -KILL -- "-$pid" 2>/dev/null || true
}

if [[ -d "$bin_dir" ]]; then
  bin=""

  [[ -x "$bin_dir/run" ]] && bin="$bin_dir/run"
  [[ -z "$bin" && -x "$bin_dir/$stem" ]] && bin="$bin_dir/$stem"

  if [[ -z "$bin" && -f "$bin_dir/Cargo.toml" ]]; then
    release_dir="$bin_dir/target/release"
    package_name=$(grep -m1 '^[[:space:]]*name[[:space:]]*=' "$bin_dir/Cargo.toml" | cut -d= -f2 | tr -d ' "')
    bin="$release_dir/$package_name"

    if [[ ! -x "$bin" ]]; then
      cargo build --release --manifest-path "$bin_dir/Cargo.toml" >&2
      bin=$(find "$release_dir" -maxdepth 1 -type f -perm -111 ! -name '*.d' ! -name '*.rlib' ! -name '*.so' | sort | head -n1)
    fi
  fi

  [[ -n "$bin" ]] || bin=$(find "$bin_dir" -maxdepth 1 -type f -perm -111 | sort | head -n1)
  [[ -n "$bin" ]] || { echo "No launcher for $stem" >&2; exit 1; }

  stop_dynamic
  pkill -x awww-daemon 2>/dev/null || true
  : >"$LOG_DIR/$stem.log"

  (
    exec 9>&-
    cd "$bin_dir"
    export WALLPAPER_PREVIEW="$selection"
    exec setsid "$bin" >>"$LOG_DIR/$stem.log" 2>&1
  ) &

  printf '%s\n' "$!" >"$PID_FILE"
else
  stop_dynamic

  if ! pgrep -x awww-daemon >/dev/null; then
    (exec 9>&-; exec awww-daemon >"$LOG_DIR/awww-daemon.log" 2>&1) &
    sleep 0.2
  fi

  awww img \
    --transition-type outer \
    --transition-pos "0.$((RANDOM % 999)),0.$((RANDOM % 999))" \
    --transition-step 25 \
    --transition-fps 120 \
    --transition-duration 0.15 \
    "$selection" || {
      sleep 0.3
      awww img \
        --transition-type outer \
        --transition-pos "0.$((RANDOM % 999)),0.$((RANDOM % 999))" \
        --transition-step 25 \
        --transition-fps 120 \
        --transition-duration 0.15 \
        "$selection"
    }
fi

printf '%s\n' "$selection" >"$SAVE_FILE"
