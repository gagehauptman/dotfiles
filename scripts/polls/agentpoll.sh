#!/bin/bash
# OpenClaw agents for the bar: one line per agent, "agent|model|thinking", most recently active agent first.
# Uses each agent's latest interactive session (subagent and cron runs are skipped).
# The gateway may be another machine: NOVA_GATEWAY_SSH / NOVA_GATEWAY_CLI come from
# ~/.config/nova-voice/env (the same file the voice assistant reads); without them, openclaw runs locally.
# Prints nothing if the gateway is not reachable.
[ -f "$HOME/.config/nova-voice/env" ] && . "$HOME/.config/nova-voice/env"
cli=${NOVA_GATEWAY_CLI:-openclaw}
cmd="$cli sessions --all-agents --active 1440 --json"
if [ -n "$NOVA_GATEWAY_SSH" ]; then
  json=$(ssh -o BatchMode=yes -o ConnectTimeout=3 "$NOVA_GATEWAY_SSH" "$cmd" 2>/dev/null) || exit 0
else
  json=$($cmd 2>/dev/null) || exit 0
fi
echo "$json" | sed -n '/^{/,$p' | jq -r '
  def short: sub("^claude-"; "") | sub("-(?<a>[0-9]+)-(?<b>[0-9]+)$"; "-\(.a).\(.b)");
  [.sessions[] | select(.key | test(":(subagent|cron):") | not)]
  | group_by(.agentId) | map(max_by(.updatedAt))
  | sort_by(-.updatedAt)[]
  | "\(.agentId)|\((.model // "?") | short)|\(.thinkingLevel // "default")"'
