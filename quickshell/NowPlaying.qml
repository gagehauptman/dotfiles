pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Shared now-playing state for the dashboard (tab strip, music tab, lyrics):
// track, album, art and a playback position that advances smoothly between polls.
// Source: scripts/polls/nowplaying.sh (same player choice as the bar's MusicWidget:
// spotifyd, else any MPRIS player; Cider through its local API). Polls once a
// second only while something registered in `users` is showing; `clockUsers`
// (lyrics, progress bars) additionally tick the interpolated position at 10 Hz.
Singleton {
  id: np

  property int users: 0
  property int clockUsers: 0

  property string player: ""
  property string status: ""
  property string artist: ""
  property string title: ""
  property string album: ""
  property string art: ""
  property real length: 0          // seconds, 0 = unknown
  // Colour sampled from the cover by MusicStageWidget ("transparent" = none), so
  // the lyrics card can share the turntable's accent.
  property color artAccent: "transparent"

  readonly property bool playing: status === "Playing"
  readonly property bool hasTrack: title !== "" && (status === "Playing" || status === "Paused")
  readonly property string line: !hasTrack ? "" : artist !== "" ? artist + " — " + title : title
  // Changes exactly when the track does; Lyrics.qml keys its fetches and cache on it.
  readonly property string trackKey: hasTrack ? [artist, title, album, Math.round(length)].join("\u001f") : ""

  // position = last sample + time since it while playing
  property real _pos: 0
  property real _posAt: 0
  property real now: 0
  readonly property real position: {
    if (!hasTrack) return 0
    let p = _pos + (playing ? Math.max(0, now - _posAt) / 1000 : 0)
    return Math.max(0, length > 0 ? Math.min(length, p) : p)
  }
  readonly property real progress: length > 0 ? position / length : 0

  // A poll that says "no track" (or gives no answer) only clears the track after
  // it has held for `graceMs`: Cider's API stalls now and then and players
  // report Stopped/empty for a moment between tracks, which flashed "Nothing playing".
  property int graceMs: 4000
  Timer { id: lost; interval: np.graceMs; onTriggered: np.setTrack({}) }

  function apply(text) {
    let d = null
    try { d = JSON.parse(text) } catch (e) {}
    if (!d || typeof d !== "object") d = null
    let ok = d !== null && (d.title ?? "") !== "" && (d.status === "Playing" || d.status === "Paused")
    if (!ok && np.hasTrack) {
      if (!lost.running) lost.start()
      return
    }
    lost.stop()
    if (d !== null) setTrack(d)
  }

  function setTrack(d) {
    let t = Date.now()
    np.now = t
    // Predicted position before this sample, to tell a seek from poll jitter
    let predicted = np.position
    np.player = d.player ?? ""
    np.artist = d.artist ?? ""
    np.album = d.album ?? ""
    np.art = d.art ?? ""
    np.length = Number(d.length) || 0
    np.status = d.status ?? ""
    let changed = np.title !== (d.title ?? "")
    np.title = d.title ?? ""
    let p = Number(d.position) || 0
    // Small differences are poll timing; snapping to them would make the lyrics stutter backwards.
    if (changed || !np.playing || Math.abs(p - predicted) > 0.6) {
      np._pos = p
      np._posAt = t
    }
  }

  Process {
    id: proc
    command: ["bash", Quickshell.env("HOME") + "/.config/scripts/polls/nowplaying.sh"]
    stdout: StdioCollector { onStreamFinished: np.apply(this.text.trim()) }
  }
  Timer {
    interval: 1000
    repeat: true
    triggeredOnStart: true
    running: np.users > 0
    onTriggered: if (!proc.running) proc.running = true
  }
  Timer {
    interval: 100
    repeat: true
    running: np.clockUsers > 0 && np.playing
    onTriggered: np.now = Date.now()
  }

  // Transport (same commands as the bar widget: Cider's API, else playerctl)
  Process { id: ctl }
  function control(action) {
    if (ctl.running) return
    if (np.player === "Cider") {
      let ep = { toggle: "playpause", next: "next", previous: "previous" }[action]
      ctl.command = ["curl", "-s", "-X", "POST", "http://127.0.0.1:10767/api/v1/playback/" + ep]
    } else {
      let verb = { toggle: "play-pause", next: "next", previous: "previous" }[action]
      ctl.command = ["playerctl", "--player=" + (np.player || "spotifyd,%any"), verb]
    }
    ctl.running = true
    refresh.restart()
  }
  // Re-read soon after a transport command instead of waiting for the next poll
  Timer { id: refresh; interval: 350; onTriggered: if (np.users > 0 && !proc.running) proc.running = true }
}
