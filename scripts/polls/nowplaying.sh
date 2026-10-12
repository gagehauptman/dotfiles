#!/bin/bash
# Now-playing snapshot for the dashboard (quickshell/NowPlaying.qml), one JSON line:
#   {"player","status","artist","title","album","length","position","art"}   (length/position in seconds)
# {} when nothing is playing, or nothing at all when Cider's API did not answer.
# Same player choice as the bar (MusicWidget): spotifyd first, else any MPRIS player;
# Cider (Electron, MPRIS "chromium" with empty metadata) is read from its local API instead.
fmt='{{playerName}}	{{status}}	{{xesam:artist}}	{{xesam:title}}	{{xesam:album}}	{{mpris:length}}	{{position}}	{{mpris:artUrl}}'
line=$(playerctl --player=spotifyd,%any metadata --format "$fmt" 2>/dev/null | head -n1)
player=${line%%$'\t'*}

if [[ -z $line || $player == chromium* || $player == Cider ]]; then
  api=http://127.0.0.1:10767/api/v1/playback
  if np=$(curl -sf -m2 "$api/now-playing") && ip=$(curl -sf -m2 "$api/is-playing"); then
    jq -nc --argjson np "$np" --argjson ip "$ip" '
      ($np.info // {}) as $i
      | if ($i.name // "") == "" then {} else {
          player: "Cider",
          status: (if $ip.is_playing then "Playing" else "Paused" end),
          artist: ($i.artistName // ""), title: $i.name, album: ($i.albumName // ""),
          length: (($i.durationInMillis // 0) / 1000), position: ($i.currentPlaybackTime // 0),
          art: (($i.artwork.url // "") | gsub("\\{w\\}"; "600") | gsub("\\{h\\}"; "600"))
        } end'
    exit 0
  fi
  [[ -z $line ]] && { echo '{}'; exit 0; }
  # Cider is there but its API stalled (it does, every minute or so): print nothing
  # ("don't know"; NowPlaying keeps the last track) rather than a "chromium" MPRIS line.
  exit 0
fi

printf '%s\n' "$line" | jq -Rc 'split("\t") | {
  player: .[0], status: .[1], artist: .[2], title: .[3], album: .[4],
  length: (((.[5] // "") | tonumber? // 0) / 1e6), position: (((.[6] // "") | tonumber? // 0) / 1e6),
  art: (.[7] // "")
}'
