pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Lyrics for the track in NowPlaying, for the music tab's LyricsWidget. Fetched
// by scripts/listeners/lyrics.py when the track changes (Apple Music's own lyrics
// through Cider's local API when Cider plays the track, else LRCLIB; async
// Process; the script also keeps a file cache under ~/.cache/quickshell/lyrics),
// remembered here per track for the session. Synced lyrics (Apple's timed lines,
// or LRC) become timed lines; indexAt(seconds) gives the line being sung.
// Instrumental breaks become empty "gap" lines (intro, and any pause of a few
// seconds where the end of the sung line is known) that the widget draws as dots.
//   status: idle (nothing playing) | loading | synced | plain | instrumental | none | error
//   source: "apple" (Apple Music via Cider) | "get" or "search" (LRCLIB) | "" (nothing found)
Singleton {
  id: ly

  // Something showing lyrics; fetches only happen while > 0.
  property int users: 0

  readonly property string key: NowPlaying.trackKey
  property string status: "idle"
  property var lines: []            // [{ t: start, e: end (-1 unknown), text, gap }] (seconds)
  property string plain: ""
  property string source: ""
  property var cache: ({})          // trackKey -> parsed result (errors are not cached)

  property string fetchingKey: ""
  property string _out: ""
  property bool _gotOut: false
  property bool _exited: false
  property int _retries: 0

  onKeyChanged: { ly._retries = 0; retry.stop(); load() }
  // A track that changed while nothing showed lyrics is fetched once something does.
  onUsersChanged: if (users > 0 && status === "loading" && !proc.running) start()

  function load() {
    if (key === "") { show({ status: "idle", lines: [], plain: "", source: "" }); return }
    let c = cache[key]
    if (c) { show(c); return }
    show({ status: "loading", lines: [], plain: "", source: "" })
    if (users > 0 && !proc.running) start()
  }

  function show(r) {
    status = r.status
    lines = r.lines
    plain = r.plain
    source = r.source
  }

  function start() {
    fetchingKey = key
    _out = ""; _gotOut = false; _exited = false
    proc.command = ["python3", Quickshell.env("HOME") + "/.config/scripts/listeners/lyrics.py",
                    NowPlaying.artist, NowPlaying.title, NowPlaying.album, String(Math.round(NowPlaying.length))]
    proc.running = true
  }

  // Both the output and the exit have to be in before the process can be reused.
  function settle() {
    if (!_gotOut || !_exited) return
    let r = parse(_out)
    if (r.status !== "error") {
      let c = Object.assign({}, cache)
      c[fetchingKey] = r
      cache = c
    }
    if (fetchingKey === key) {
      show(r)
      if (r.status === "error" && _retries < 3) { _retries++; retry.restart() }
    } else if (key !== "" && !cache[key] && users > 0) {
      start()          // the track changed while this one was being fetched
    }
  }

  function parse(text) {
    let d
    try { d = JSON.parse(text) } catch (e) { d = { status: "error" } }
    let r = { status: d.status || "error", lines: [], plain: d.plain || "", source: d.source || "" }
    if (r.status === "synced") {
      r.lines = Array.isArray(d.lines) && d.lines.length > 0
          ? d.lines.map(l => ({ t: Number(l.t) || 0, e: Number(l.e) || -1, text: String(l.text || "") }))
          : parseLrc(d.synced || "")
      if (r.lines.length === 0) r.status = r.plain !== "" ? "plain" : "none"
      else r.lines = withGaps(r.lines)
    }
    if (r.status === "plain" && r.plain.trim() === "") r.status = "none"
    return r
  }

  // "[mm:ss.xx]text" lines; several leading stamps share the text; [offset:+ms] shifts them all.
  function parseLrc(s) {
    let out = [], offset = 0
    for (let raw of s.split(/\r?\n/)) {
      let m, stamps = [], rest = raw
      while ((m = /^\s*\[(\d+):(\d+(?:[.:]\d+)?)\]/.exec(rest)) !== null) {
        stamps.push(parseInt(m[1]) * 60 + parseFloat(m[2].replace(":", ".")))
        rest = rest.slice(m[0].length)
      }
      if (stamps.length === 0) {
        let o = /^\s*\[offset:\s*([+-]?\d+)\s*\]/i.exec(raw)
        if (o) offset = parseInt(o[1]) / 1000
        continue
      }
      let text = rest.trim()
      for (let t of stamps) out.push({ t: Math.max(0, t - offset), text: text })
    }
    out.sort((a, b) => a.t - b.t)
    return out
  }

  // Mark empty lines as gaps (they last until the next line) and add gaps for an
  // intro of 3 s+ and for pauses of 4 s+ after a line whose end is known.
  function withGaps(a) {
    let out = []
    if (a[0].t >= 3) out.push({ t: 0, e: a[0].t, text: "", gap: true })
    for (let i = 0; i < a.length; i++) {
      let l = a[i], next = i + 1 < a.length ? a[i + 1].t : -1
      if (l.text === "") { out.push({ t: l.t, e: next, text: "", gap: true }); continue }
      out.push({ t: l.t, e: l.e, text: l.text, gap: false })
      if (l.e > 0 && next > 0 && next - l.e >= 4 && a[i + 1].text !== "")
        out.push({ t: l.e, e: next, text: "", gap: true })
    }
    return out
  }

  // Index of the line sung at `pos` seconds; -1 before the first one.
  function indexAt(pos) {
    let a = lines, lo = 0, hi = a.length - 1, ans = -1
    while (lo <= hi) {
      let mid = (lo + hi) >> 1
      if (a[mid].t <= pos) { ans = mid; lo = mid + 1 } else hi = mid - 1
    }
    return ans
  }

  Process {
    id: proc
    stdout: StdioCollector {
      onStreamFinished: { ly._out = this.text; ly._gotOut = true; ly.settle() }
    }
    onExited: { ly._exited = true; ly.settle() }
  }
  // LRCLIB was busy or unreachable: try the same track again a little later.
  Timer {
    id: retry
    interval: 20000
    onTriggered: if (ly.status === "error" && ly.key !== "" && !proc.running) { ly.show({ status: "loading", lines: [], plain: "", source: "" }); ly.start() }
  }
}
