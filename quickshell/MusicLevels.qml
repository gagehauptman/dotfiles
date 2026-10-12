pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Shared spectrum feed for MusicVisualizer (bar) and MusicStageWidget (dashboard
// music tab): one analyzer process for all of them, running only while at least
// one visualizer is showing. `values` has barCount bands, `wide` wideCount.
// Source: scripts/listeners/music_levels.py (pw-record of the sink monitor + numpy FFT).
Singleton {
  id: levels

  readonly property int barCount: 6
  readonly property int wideCount: 24
  property var values: new Array(barCount).fill(0)
  property var wide: new Array(wideCount).fill(0)
  // visualizers add/remove themselves here (see MusicVisualizer.active)
  property int users: 0

  // When the last frame arrived; all-zero levels need no decay.
  property double lastAt: 0
  property bool idle: true

  function same(a, b) {
    if (!b || a.length !== b.length) return false
    for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
    return true
  }

  function parse(group, n) {
    let v = group.trim().split(" ").map(parseFloat)
    return v.length === n && !v.some(isNaN) ? v : null
  }

  Process {
    id: proc
    running: levels.users > 0
    command: ["python3", Quickshell.env("HOME") + "/.config/scripts/listeners/music_levels.py", levels.barCount + "," + levels.wideCount]
    stdout: SplitParser {
      onRead: data => {
        let g = data.split("|")
        if (g.length !== 2) return
        let a = levels.parse(g[0], levels.barCount), b = levels.parse(g[1], levels.wideCount)
        // an unchanged frame (silence, or a held note at the same levels) re-publishes
        // nothing: every bar is bound to these arrays, and a new array object would
        // re-evaluate all of them even with the same numbers (2026-10-10)
        if (a && !levels.same(a, levels.values)) levels.values = a
        if (b && !levels.same(b, levels.wide)) levels.wide = b
        levels.lastAt = Date.now()
        levels.idle = levels.values.every(x => x === 0) && levels.wide.every(x => x === 0)
      }
    }
    // no zeroing on stop: the stale-data decay below lets the bars fall instead of snapping
    // the binding above won't restart it after a crash; retry while still wanted
    onExited: if (levels.users > 0) restartTimer.start()
  }
  Timer { id: restartTimer; interval: 3000; onTriggered: proc.running = levels.users > 0 }

  // Paused, stopped, analyzer gone or the sink went quiet (pw-record then delivers
  // nothing, so no frame ever says "zero"): with no fresh frame for 300 ms the
  // last levels fall away to zero instead of freezing.
  Timer {
    interval: 50
    repeat: true
    running: !levels.idle
    onTriggered: {
      if (Date.now() - levels.lastAt < 300) return
      let fall = x => x < 0.02 ? 0 : x * 0.7
      levels.values = levels.values.map(fall)
      levels.wide = levels.wide.map(fall)
      levels.idle = levels.values.every(x => x === 0) && levels.wide.every(x => x === 0)
    }
  }
}
