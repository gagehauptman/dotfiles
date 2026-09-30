#!/usr/bin/env bash
# nova_voice.sh — conversational voice chat with your openclaw agent from Hyprland.
# Thin wrapper around nova_voice.py; nothing here is machine-specific — all of
# that lives in ~/.config/nova-voice/env (see nova_voice.env.example).
#
#   nova_voice.sh toggle       # keybind (SUPER+T):
#                              #   idle      -> start listening (VAD ends your turn automatically)
#                              #   listening -> send now
#                              #   thinking / speaking -> interrupt and listen again
#   nova_voice.sh cancel       # (SUPER+SHIFT+T) stop everything, go idle
#   nova_voice.sh ask "text"   # skip the mic: send text, speak the reply
#   nova_voice.sh say "text"   # TTS only
#   nova_voice.sh enroll alex  # teach the speaker service this voice from the last clip (no name = list profiles)
#   nova_voice.sh status       # what is running, what is configured, recent timings
#   nova_voice.sh setup        # one-time: venv, Silero VAD model, config file from the example
#
# Engine: NOVA_ENGINE (normally nova_client.py from the nova repo: speech-to-text, the agent and TTS all run on the
#   voice server, which streams the mic into ElevenLabs Scribe Realtime; local whisper was removed 2026-09-29).
# Legacy local pipeline (nova_voice.py, needs a whisper-server it no longer has): pw-record + Silero VAD -> STT
#   -> gateway /v1/chat/completions stream:true -> sentence chunks -> streaming TTS -> pw-play
# Voice id (optional, NOVA_SPEAKER_URL): each turn also goes to nova-speaker /identify, so the agent is told
#   whether it is you, someone else in the house, or a guest (names: ~/.config/nova-voice/speakers.json).
# State for the Quickshell bar indicator: $XDG_RUNTIME_DIR/nova-voice/state.json
# Logs: ~/.local/state/nova-voice/conversation.log (turns + TIMING lines), engine.log (debug)

set -u
export PATH="$HOME/.local/bin:$PATH"

CONF="${NOVA_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/nova-voice/env}"
[ -f "$CONF" ] && { set -a; . "$CONF"; set +a; }
: "${NOVA_NAME:=Nova}"
: "${NOVA_CONVERSE:=1}"
: "${NOVA_SHARE:=${XDG_DATA_HOME:-$HOME/.local/share}/nova-voice}"
: "${NOVA_PY:=$NOVA_SHARE/venv/bin/python}"
: "${NOVA_ENGINE:=$(dirname "$(readlink -f "$0")")/nova_voice.py}"
: "${NOVA_VAD_MODEL:=$NOVA_SHARE/silero_vad.onnx}"
export NOVA_VAD_MODEL

RUN="${XDG_RUNTIME_DIR:-/tmp}/nova-voice"; mkdir -p "$RUN"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/nova-voice"; mkdir -p "$STATE"
PIDF="$RUN/turn.pid"; STATEF="$RUN/state.json"
ELOG="$STATE/engine.log"

need_conf() {
  [ -n "${NOVA_GATEWAY_URL:-}" ] && [ -n "${NOVA_GATEWAY_TOKEN:-}" ] && return 0
  notify-send -r 4242 -a "$NOVA_NAME" -t 5000 "Voice assistant not configured" "run: nova_voice.sh setup, then edit $CONF" 2>/dev/null || true
  echo "NOVA_GATEWAY_URL / NOVA_GATEWAY_TOKEN not set in $CONF (nova_voice.sh setup)" >&2
  return 1
}
engine_pid() { local p; p=$(cat "$PIDF" 2>/dev/null) || return 1; kill -0 "$p" 2>/dev/null && echo "$p"; }

start_engine() {  # background conversational turn
  local flags=(turn --listen); [ "$NOVA_CONVERSE" = 1 ] && flags+=(--converse)
  setsid "$NOVA_PY" "$NOVA_ENGINE" "${flags[@]}" >>"$ELOG" 2>&1 < /dev/null &
  echo $! > "$PIDF"
}

setup() {
  mkdir -p "$NOVA_SHARE" "$(dirname "$CONF")"
  if [ ! -x "$NOVA_PY" ]; then
    echo "creating venv at $NOVA_SHARE/venv"
    if command -v uv >/dev/null; then
      uv venv --python 3.12 "$NOVA_SHARE/venv" && uv pip install --python "$NOVA_PY" onnxruntime numpy requests
    else
      python3 -m venv "$NOVA_SHARE/venv" && "$NOVA_PY" -m pip install --quiet onnxruntime numpy requests
    fi
  fi
  if [ ! -f "$NOVA_VAD_MODEL" ]; then
    echo "fetching Silero VAD model"
    curl -fsSL -o "$NOVA_VAD_MODEL" https://github.com/snakers4/silero-vad/raw/master/src/silero_vad/data/silero_vad.onnx
  fi
  if [ ! -f "$CONF" ]; then
    cp "$(dirname "$(readlink -f "$0")")/nova_voice.env.example" "$CONF"
    echo "wrote $CONF — set NOVA_GATEWAY_URL and NOVA_GATEWAY_TOKEN"
  fi
  echo "also needed on this machine: pw-record/pw-play (pipewire), ffmpeg, notify-send; optional: piper + a voice for offline TTS. See: nova_voice.sh status"
}

status() {
  if p=$(engine_pid); then echo "engine running (pid $p)"; else echo "engine idle"; fi
  [ -f "$STATEF" ] && { cat "$STATEF"; echo; }
  echo "config: $CONF $([ -f "$CONF" ] && echo present || echo MISSING)"
  echo "gateway: ${NOVA_GATEWAY_URL:-MISSING (NOVA_GATEWAY_URL)} token=$([ -n "${NOVA_GATEWAY_TOKEN:-}" ] && echo set || echo MISSING)"
  echo "venv: $NOVA_PY $([ -x "$NOVA_PY" ] && echo ok || echo MISSING — nova_voice.sh setup)"
  echo "vad model: $NOVA_VAD_MODEL $([ -f "$NOVA_VAD_MODEL" ] && echo ok || echo MISSING — nova_voice.sh setup)"
  local tts="${NOVA_TTS:-auto}"; local chain=""
  [ -n "${NOVA_ELEVENLABS_API_KEY:-}" ] && [ -n "${NOVA_ELEVENLABS_VOICE:-}" ] && chain="$chain elevenlabs"
  [ -n "${NOVA_GATEWAY_SSH:-}" ] && chain="$chain gateway(${NOVA_GATEWAY_SSH})"
  command -v "${NOVA_PIPER_BIN:-piper}" >/dev/null && chain="$chain piper" || chain="$chain (piper missing)"
  echo "tts: $tts —$chain"
  grep TIMING "$STATE/conversation.log" 2>/dev/null | tail -3
}

case "${1:-toggle}" in
  toggle)
    if p=$(engine_pid); then kill -USR1 "$p"; else need_conf && start_engine; fi ;;
  cancel)
    if p=$(engine_pid); then kill -TERM "$p"; fi
    rm -f "$PIDF"
    notify-send -r 4242 -a "$NOVA_NAME" -t 1500 "Cancelled" 2>/dev/null || true ;;
  ask)  shift; [ -n "${*:-}" ] || { echo "usage: $0 ask <text>"; exit 2; }
        need_conf && exec "$NOVA_PY" "$NOVA_ENGINE" turn --text "$*" ;;
  say)  shift; [ -n "${*:-}" ] || { echo "usage: $0 say <text>"; exit 2; }
        exec "$NOVA_PY" "$NOVA_ENGINE" say "$*" ;;
  enroll) shift; exec "$NOVA_PY" "$NOVA_ENGINE" enroll "$@" ;;
  status) status ;;
  setup)  shift; setup "${1:-}" ;;
  *) echo "usage: $0 {toggle|cancel|ask <text>|say <text>|enroll [name] [--last N]|status|setup}"; exit 2 ;;
esac
