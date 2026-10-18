import QtQuick
import Quickshell
import Quickshell.Io
import "themes"
import "NovaMd.js" as Md
import "NovaHl.js" as Hl
import "NovaQuiz.js" as QuizFmt

// Nova chat panel (SUPER+A): type or talk to Nova from the bar, voice and text in one log.
// Backend: nova_client.py from the nova repo (NOVA_CLIENT), talking to the same voice server as nova_voice.py.
// Every client process appends its events to $XDG_RUNTIME_DIR/nova-voice/events.jsonl and shell.qml tails
// that into root.novaEvent, so turns show up here live (your words while you talk, then the reply) whether
// they came from SUPER+T, the mic button or the text box. Voice goes through nova_voice.sh (same engine and
// pid as SUPER+T); typed turns run the client directly. History: ~/.local/state/nova-voice/chat.jsonl.
Item {
  id: chat

  readonly property bool isOpen: bar.state === "nova_chat"
  visible: isOpen

  anchors {
    top: metrics.isVertical ? undefined : parent.top
    left: metrics.isVertical ? parent.left : undefined
    // top edge flush with the bottom of the bar strip, so the bar's voice indicator stays visible above the log
    topMargin: metrics.isVertical ? 0 : bar.barThickness
    leftMargin: metrics.isVertical ? bar.dropdownWidgetPadding : 0
    horizontalCenter: metrics.isVertical ? undefined : parent.horizontalCenter
    verticalCenter: metrics.isVertical ? parent.verticalCenter : undefined
  }
  width: parent.width - (bar.dropdownWidgetPadding * 2)
  height: parent.height - (bar.dropdownWidgetPadding * 2) + (metrics.isVertical ? 0 : bar.dropdownWidgetPadding - bar.barThickness)

  readonly property string python: root.home + "/.local/share/nova-voice/venv/bin/python"
  readonly property string client: Quickshell.env("NOVA_CLIENT") || "/storage/git/nova/desktop/nova_client.py"
  readonly property string historyPath: (Quickshell.env("XDG_STATE_HOME") || (root.home + "/.local/state")) + "/nova-voice/chat.jsonl"
  readonly property string voiceSh: root.home + "/.config/scripts/nova_voice.sh"

  // whose machine this is (profile name), from the local ~/.config/nova-voice/speakers.json: their turns get no name tag
  property string owner: ""
  FileView {
    path: (Quickshell.env("NOVA_SPEAKERS") || (root.home + "/.config/nova-voice/speakers.json"))
    printErrors: false
    onLoaded: { try { chat.owner = (JSON.parse(text()).owner || "").toLowerCase() } catch (e) {} }
  }

  property string status: ""            // listening / thinking / speaking ...
  property string lastTyped: ""
  property int wordPtr: -1              // token index of the word being read aloud in the latest reply

  // ---- background agents (bridge -> nova-inbox.service -> $XDG_RUNTIME_DIR/nova-voice/agents.json)
  property var agents: []
  property bool agentsOpen: false
  property string openAgent: ""         // id of the agent whose task/result is expanded
  property string openRuns: ""          // id of the agent whose earlier runs are listed
  property real now: Date.now()
  // One row per agent session, showing its latest run. A finished agent that gets a follow-up comes back as
  // "queued" (follow-up accepted, not started) then "running" with run > 1; earlier runs sit in a.runs.
  function agentActive(a) { return a.status === "running" || a.status === "queued" }
  // finished agents drop off 30 min after they end; running/queued ones always show
  readonly property var shownAgents: agents.filter(a => agentActive(a) || !a.endedAt || now - a.endedAt < 30 * 60 * 1000)
  readonly property int agentsRunning: shownAgents.filter(a => a.status === "running").length
  readonly property int agentsQueued: shownAgents.filter(a => a.status === "queued").length
  readonly property int agentsFailed: shownAgents.filter(a => !agentActive(a) && a.status !== "done").length
  FileView {
    id: agentsFile
    path: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/nova-voice/agents.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { try { chat.agents = JSON.parse(text()).agents || [] } catch (e) {} }
  }
  Timer { interval: 1000; repeat: true; running: chat.isOpen && chat.agentsRunning + chat.agentsQueued > 0; onTriggered: chat.now = Date.now() }
  Timer { interval: 60000; repeat: true; running: chat.isOpen; triggeredOnStart: true; onTriggered: chat.now = Date.now() }
  function fmtDur(ms) {
    let s = Math.max(0, Math.round(ms / 1000))
    if (s < 60) return s + "s"
    let m = Math.floor(s / 60)
    if (m < 60) return m + "m " + (s % 60) + "s"
    return Math.floor(m / 60) + "h " + (m % 60) + "m"
  }
  function agentModel(a) {
    if (!a.model) return ""
    let m = a.model.replace(/^claude-/, "").replace(/-(\d+)-(\d+)$/, "-$1.$2")
    return m + " · thinking " + (a.thinking || "default")
  }
  function agentWhen(a) {
    if (a.status === "queued") return "queued " + fmtDur(now - (a.startedAt || now))
    if (a.status === "running") return "running " + fmtDur(now - (a.startedAt || now))
    let took = (a.endedAt && a.startedAt) ? "took " + fmtDur(a.endedAt - a.startedAt) : ""
    let ago = a.endedAt ? fmtDur(Date.now() - a.endedAt) + " ago" : ""
    return [took, ago].filter(x => x).join(" · ")
  }
  readonly property bool voiceBusy: root.voiceState !== "idle"      // SUPER+T / mic engine running a turn
  // typed turns run detached (a shell reload must not kill them); typedPending tracks ours until the client exits
  property bool typedPending: false
  readonly property bool busy: typedPending || voiceBusy
  readonly property string mode: typedPending ? "text" : voiceBusy ? "voice" : ""
  // barge-in (2026-10-07): while Nova is thinking or speaking, a typed message cuts that turn off and the bridge hands
  // the cut-off message to the new turn with it (nothing is lost). Not while the mic is listening/transcribing.
  readonly property bool canBargeIn: typedPending || root.voiceState === "thinking" || root.voiceState === "speaking"
  readonly property string staleNote: "\n\n*(cut off: you sent a newer message)*"
  readonly property string typedPid: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/nova-voice/typed.pid"

  readonly property color statusColor: {
    switch (status) {
    case "listening":    return Theme.colors.teal;
    case "transcribing": return Theme.colors.lavender;
    case "thinking":     return Theme.colors.violet;
    case "speaking":     return Theme.colors.blue;
    case "error":        return Theme.colors.red;
    default:             return Theme.colors.textMuted;
    }
  }

  // ---- Nova's lynx (NovaAvatar in the header): the voice engine's status when there is one; a typed turn is
  // thinking until its reply streams in. Idle for a few minutes with the panel open, she dozes off.
  property bool streaming: false        // a reply is arriving (delta events) in the current turn
  property int liveSpoken: -1           // chars of the streaming reply read aloud so far: -1 = all (so far), 0 = chat-only; set by "quiet" events
  property bool drowsy: false
  readonly property string lynxMood: {
    switch (status) {
    case "listening":    return "listening";
    case "transcribing":
    case "thinking":     return "thinking";
    case "speaking":     return "speaking";
    }
    if (busy) return streaming ? "speaking" : "thinking";
    return drowsy ? "sleepy" : "idle";
  }
  readonly property color lynxTint: {
    if (status === "error") return Theme.colors.red;
    switch (lynxMood) {
    case "listening": return Theme.colors.teal;
    case "thinking":  return Theme.colors.violet;
    case "speaking":  return Theme.colors.blue;
    case "sleepy":    return Theme.colors.textMuted;
    default:          return Theme.colors.lavender;
    }
  }
  readonly property string lynxLabel: status === "error" ? "something went wrong"
    : ({ listening: "listening", thinking: status === "transcribing" ? "transcribing" : "thinking",
         speaking: "speaking", sleepy: "dozing", idle: "here" })[lynxMood]
  Timer { interval: 5 * 60 * 1000; running: chat.isOpen && !chat.busy && chat.status === "" && !chat.drowsy; onTriggered: chat.drowsy = true }
  onBusyChanged: if (busy) drowsy = false
  onStatusChanged: if (status !== "") drowsy = false

  ListModel { id: messages }   // role: user | nova | error; text; speaker; pending

  onIsOpenChanged: {
    if (isOpen) {
      drowsy = false
      if (!busy) loadHistory()
      input.forceActiveFocus()
    }
  }

  // ---- history (chat.jsonl, newest last)
  FileView {
    id: historyFile
    path: chat.historyPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: if (!chat.busy) chat.loadHistory()
  }

  function loadHistory() {
    let lines = (historyFile.text() || "").split("\n").filter(l => l.trim() !== "").slice(-80)
    messages.clear()
    for (let l of lines) {
      try {
        let e = JSON.parse(l)
        messages.append({ role: e.role, text: e.text + (e.stale ? staleNote : ""), speaker: e.speaker || "", pending: false, hl: -1,
                          spoken: e.stale ? 0 : (typeof e.spoken === "number") ? e.spoken : -1, imgs: (e.images || []).join("\n") })
        if (e.role === "user") quizSent(e.text)
      } catch (err) {}
    }
    scrollDown(true)
  }

  // follow new messages only while the log is at the bottom; reading back up isn't interrupted
  property bool follow: true
  readonly property real gutter: metrics.s(12)            // room on the right for the scrollbar
  function scrollDown(force) {
    if (force) follow = true
    if (follow) Qt.callLater(() => log.positionViewAtEnd())
  }

  function liveUser() {
    for (let i = messages.count - 1; i >= 0 && i >= messages.count - 3; i--)
      if (messages.get(i).role === "user" && messages.get(i).pending) return i
    return -1
  }
  function dropLiveUser() { let i = liveUser(); if (i >= 0) messages.remove(i) }

  function lastNova() {
    let n = messages.count
    return n > 0 && messages.get(n - 1).role === "nova" && messages.get(n - 1).pending ? n - 1 : -1
  }

  // ---- assistant replies: NovaMd.js renders them (markdown, fenced code, LaTeX, voice-marker cleanup; see its header)
  // into NovaMdView blocks. MEDIA:<path> lines become inline images (the path lives on the gateway host, so the file
  // is scp'd once into mediaDir; a path that exists locally is used as is).
  readonly property string mediaDir: (Quickshell.env("XDG_CACHE_HOME") || (root.home + "/.cache")) + "/nova-chat-media"
  readonly property string mediaHost: Quickshell.env("NOVA_GATEWAY_SSH") || "vic-server"
  // colours for the rendered HTML, from the live theme; settled 250 ms after a wallpaper change so the fade doesn't
  // re-render every reply per frame. Inline code, links and quote text are fitted to 4.5:1 (Hl.fit keeps the hue) on
  // what they sit on: the inset chip, the panel.
  property var mdColors: mdColorsNow()
  function mdColorsNow() {
    let c = Theme.colors, h = x => "" + x, bg = Hl.blend(c.panel, c.panel, 1)
    return { text: h(c.textSecondary), strong: h(c.textPrimary), muted: Hl.fit(c.textMuted, bg, 4.5), code: Hl.fit(c.orange, c.inset, 4.5),
             codeBg: h(c.inset), link: Hl.fit(c.blue, bg, 4.5), border: h(c.border), th: h(c.inset), quote: h(c.violet) }
  }
  readonly property string mdKey: "" + Theme.colors.textSecondary + Theme.colors.textPrimary + Theme.colors.textMuted + Theme.colors.orange
                                  + Theme.colors.inset + Theme.colors.blue + Theme.colors.border + Theme.colors.violet + Theme.colors.panel
  onMdKeyChanged: mdTimer.restart()
  Timer { id: mdTimer; interval: 250; onTriggered: chat.mdColors = chat.mdColorsNow() }
  function mediaPaths(s) {
    let out = []
    let re = /^[ \t]*MEDIA:[ \t]*(\S.*?)[ \t]*$/gm, m
    while ((m = re.exec(s)) !== null) out.push(m[1])
    return out
  }
  function mediaLocal(p) { return mediaDir + "/" + p.replace(/[^A-Za-z0-9._-]/g, "_") }
  property var mediaState: ({})      // remote path -> "loading" | "ok" | "fail"
  property var mediaQueue: []
  property string mediaCurrent: ""
  function mediaFetch(p) {
    if (mediaState[p] !== undefined) return
    mediaState[p] = "loading"; mediaState = Object.assign({}, mediaState)
    mediaQueue = mediaQueue.concat([p])
    mediaNext()
  }
  function mediaNext() {
    if (mediaProc.running || mediaQueue.length === 0) return
    mediaCurrent = mediaQueue[0]; mediaQueue = mediaQueue.slice(1)
    mediaProc.running = true
  }
  // One chat panel per monitor, each fetching the same file at once: a per-process temp name keeps them from
  // clobbering each other, and the file being there afterwards counts as success, whoever finished first.
  Process {
    id: mediaProc
    command: ["bash", "-c", "p=\"$1\"; d=\"$2\"; f=\"$3\"; mkdir -p \"$d\"; [ -s \"$f\" ] && exit 0; " +
              "t=\"$f.part.$$\"; if [ -s \"$p\" ]; then cp \"$p\" \"$t\"; else scp -q -o BatchMode=yes -o ConnectTimeout=8 \"$4:$p\" \"$t\"; fi " +
              "&& mv -f \"$t\" \"$f\"; rm -f \"$t\"; [ -s \"$f\" ]",
              "bash", chat.mediaCurrent, chat.mediaDir, chat.mediaLocal(chat.mediaCurrent), chat.mediaHost]
    onExited: (code, st) => {
      chat.mediaState[chat.mediaCurrent] = code === 0 ? "ok" : "fail"
      chat.mediaState = Object.assign({}, chat.mediaState)
      chat.mediaNext()
    }
  }

  // ---- one turn = one client process
  // ---- images: Ctrl+V from the clipboard (wl-paste) or dropped files, sent with the next message
  property var attachments: []
  function attach(path) { if (path && attachments.length < 8) attachments = attachments.concat([path]) }
  function unattach(i) { let a = attachments.slice(); a.splice(i, 1); attachments = a }
  Process {
    id: pasteProc
    property bool gotImage: false
    command: ["bash", "-c", "d=\"$HOME/.local/state/nova-voice/images\"; mkdir -p \"$d\"; " +
              "t=$(wl-paste -l 2>/dev/null | grep -m1 '^image/'); [ -n \"$t\" ] || exit 0; " +
              "f=\"$d/paste-$(date +%s%3N).${t#image/}\"; wl-paste -t \"$t\" > \"$f\" && echo \"$f\""]
    stdout: SplitParser { onRead: data => { if (data.trim()) { pasteProc.gotImage = true; chat.attach(data.trim()) } } }
    onExited: (code, st) => { if (!gotImage) input.paste() }   // no image on the clipboard: normal text paste
  }
  function pasteImage() { pasteProc.gotImage = false; pasteProc.running = true }
  DropArea {
    anchors.fill: parent
    keys: ["text/uri-list"]
    onDropped: drop => {
      for (let u of drop.urls) {
        let p = decodeURIComponent(u.toString().replace(/^file:\/\//, ""))
        if (/\.(png|jpe?g|webp|gif)$/i.test(p)) chat.attach(p)
      }
    }
  }

  function send() {
    let t = input.text.trim()
    if ((t === "" && attachments.length === 0) || (busy && !canBargeIn)) return
    lastTyped = t
    input.text = ""
    sendTurn(t, true)
  }
  function sendTurn(t, withImages) {
    follow = true
    let cmd = [python, client, "turn", "--json", "--text", t]   // Nova decides whether to say it out loud
    if (withImages) { for (let a of attachments) cmd.push("--image", a); attachments = [] }
    typedPending = true
    Quickshell.execDetached(cmd)
  }

  // ---- quizzes: ```quiz blocks in Nova's replies (NovaQuiz.js / NovaQuiz.qml). Submit sends the answers as a
  // normal typed turn; a sent answers message (live or in the history) locks its quiz, matched by the block's key.
  property var quizDrafts: ({})         // quiz key -> {question id: answer} while being filled in
  property var quizDone: ({})           // quiz key -> the answers message that was sent
  function quizSent(text) {
    let k = QuizFmt.keyOf(text || "")
    if (k && quizDone[k] !== text) { let d = Object.assign({}, quizDone); d[k] = text; quizDone = d }
  }
  function submitQuiz(key, message) {
    if (busy) return
    quizSent(message)
    sendTurn(message, false)
  }

  // same as SUPER+T: starts listening, or while a voice turn runs: send now / interrupt and listen again.
  // A typed turn or an agent report that is talking gets cut off too (nova_voice.sh hush_others).
  function micPressed() { Quickshell.execDetached([voiceSh, "toggle"]) }

  // ---- speech recognition language: "auto" or an ISO 639-1 code, sent with every turn (nova_client.py `lang`,
  // ~/.local/state/nova-voice/stt_lang.json). The chip beside the mic sets it; Nova switches it with a [lang:xx]
  // reply marker (the client writes the same file, the "lang" event updates the chip at once). A set language
  // goes back to auto after idle_s (NOVA_STT_LANG_IDLE_MIN, default 30 min) without a turn.
  readonly property string langPath: (Quickshell.env("XDG_STATE_HOME") || (root.home + "/.local/state")) + "/nova-voice/stt_lang.json"
  property var langState: ({ lang: "auto", by: "", ts: 0, used: 0, idle_s: 1800 })
  property bool langOpen: false
  readonly property string sttLang: {
    let s = langState, l = (s.lang || "auto").toLowerCase()
    if (l !== "auto" && now - Math.max(s.ts || 0, s.used || 0) * 1000 > (s.idle_s || 1800) * 1000) return "auto"
    return l
  }
  readonly property var langChoices: [
    { code: "en", label: "English" },    { code: "de", label: "Deutsch" },
    { code: "ru", label: "Русский" },    { code: "uk", label: "Українська" },
    { code: "es", label: "Español" },    { code: "fr", label: "Français" },
    { code: "it", label: "Italiano" },   { code: "pt", label: "Português" },
    { code: "pl", label: "Polski" },     { code: "cs", label: "Čeština" },
    { code: "nl", label: "Nederlands" }, { code: "sv", label: "Svenska" },
    { code: "ja", label: "日本語" },      { code: "zh", label: "中文" },
    { code: "ko", label: "한국어" },      { code: "tr", label: "Türkçe" }
  ]
  FileView {
    id: langFile
    path: chat.langPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { try { chat.langState = JSON.parse(text()) } catch (e) {} }
  }
  function applyLang(code, by) {
    let t = Date.now() / 1000
    langState = { lang: code, by: by, ts: t, used: t, idle_s: langState.idle_s || 1800 }
    now = Date.now()
    if (by === "nova") langFlash.restart()
  }
  function setLang(code) {
    langOpen = false
    applyLang(code, "vic")
    Quickshell.execDetached([python, client, "lang", code])
  }

  function stop() {
    if (typedPending) Quickshell.execDetached(["bash", "-c", "kill -TERM $(cat '" + typedPid + "') 2>/dev/null"])
    if (voiceBusy) Quickshell.execDetached([voiceSh, "cancel"])
  }

  Connections {
    target: root
    function onNovaEvent(ev) { chat.onEvent(ev) }
    function onVoiceStateChanged() {
      if (root.voiceState === "idle") { chat.typedPending = false; chat.settle() }
    }
  }

  function settle() {
    status = ""
    streaming = false
    liveSpoken = -1
    dropLiveUser()
    for (let i = 0; i < messages.count; i++) if (messages.get(i).pending) messages.setProperty(i, "pending", false)
    historyFile.reload()
  }

  function onEvent(ev) {
    switch (ev.type) {
    case "state":
      status = ev.state === "idle" ? "" : ev.state
      if (ev.state === "listening") dropLiveUser()      // new listen round: nothing heard yet
      break
    case "speech_start":                 // live bubble for what you're saying, filled in by partials
      status = "listening"
      if (liveUser() < 0) messages.append({ role: "user", text: "…", speaker: "", pending: true, hl: -1, spoken: -1, imgs: "" })
      break
    case "partial": {
      let i = liveUser()
      if (i < 0) messages.append({ role: "user", text: ev.text, speaker: "", pending: true, hl: -1, spoken: -1, imgs: "" })
      else messages.setProperty(i, "text", ev.text)
      break
    }
    case "transcript": {
      let i = ev.via === "voice" ? liveUser() : -1
      if (i >= 0) {
        messages.setProperty(i, "text", ev.text)
        messages.setProperty(i, "speaker", ev.speaker || "")
        messages.setProperty(i, "pending", false)
      } else {
        messages.append({ role: "user", text: ev.text, speaker: ev.speaker || "", pending: false, hl: -1, spoken: -1,
                          imgs: (ev.images || []).join("\n") })
      }
      quizSent(ev.text)
      break
    }
    case "word": {                       // nova_client: the word being spoken right now (-1 = done reading)
      let m = -1
      for (let k = messages.count - 1; k >= 0 && k >= messages.count - 4; k--)
        if (messages.get(k).role === "nova") { m = k; break }
      if (m < 0) break
      if (ev.i < 0) { messages.setProperty(m, "hl", -1); wordPtr = -1; break }
      let norm = w => (w || "").toLowerCase().replace(/[^a-z0-9']/g, "")
      let toks = messages.get(m).text.split(/\s+/).filter(t => t !== "")
      let want = norm(ev.w), hit = -1
      for (let k = wordPtr + 1; k < toks.length && k <= wordPtr + 8; k++)
        if (norm(toks[k]) === want) { hit = k; break }
      if (hit < 0) hit = Math.min(wordPtr + 1, toks.length - 1)   // no exact match (numbers, contractions): step on
      wordPtr = hit
      messages.setProperty(m, "hl", hit)
      break
    }
    case "delta": {
      let i = lastNova()
      if (i < 0) { messages.append({ role: "nova", text: ev.text, speaker: "", pending: true, hl: -1, spoken: liveSpoken, imgs: "" }); wordPtr = -1 }
      else messages.setProperty(i, "text", messages.get(i).text + ev.text)
      break
    }
    case "quiet":                        // the rest of the reply is chat-only: dim it from `at` on while it still streams
      if (typeof ev.at === "number") {
        liveSpoken = ev.at
        let i = lastNova()
        if (i >= 0) messages.setProperty(i, "spoken", ev.at)
      }
      break
    case "done": {
      liveSpoken = -1
      let i = lastNova()
      if (i >= 0 && !ev.reply && /^NO_REPLY\.?$/.test(messages.get(i).text.trim())) {
        messages.remove(i)                 // gateway's silent-turn token streamed in: nothing to show
        break
      }
      // ev.reply is the bridge's speech-flattened text (no code blocks): keep the markdown that streamed in (Md.finalText)
      if (i >= 0) {
        let fin = Md.finalText(messages.get(i).text, ev)
        messages.setProperty(i, "text", fin.text)
        messages.setProperty(i, "pending", false)
        messages.setProperty(i, "spoken", fin.spoken)
      } else if (ev.reply || ev.md) {
        let fin = Md.finalText("", ev)
        messages.append({ role: "nova", text: fin.text, speaker: "", pending: false, hl: -1, spoken: -1, imgs: "" })
      }
      break
    }
    case "report": {                     // a background agent finished (nova-inbox.service)
      let fin = Md.finalText("", ev)      // ev.md: the report's markdown (newer bridge); ev.text is flattened for speech
      messages.append({ role: "nova", text: fin.text, speaker: "", pending: false, hl: -1, spoken: fin.spoken, imgs: "" })
      break
    }
    case "lang":                         // Nova's [lang:xx] marker, or the server dropping a refused language
      applyLang((ev.lang || "auto").toLowerCase(), ev.by || "nova")
      if (ev.error)
        messages.append({ role: "error", text: "Speech language back to auto: " + ev.error, speaker: "", pending: false, hl: -1, spoken: -1, imgs: "" })
      break
    case "error":
      liveSpoken = -1
      dropLiveUser()
      messages.append({ role: "error", text: ev.message || "error", speaker: "", pending: false, hl: -1, spoken: -1, imgs: "" })
      break
    case "interrupted": {                // a newer message cut this reply off: grey it out and say so
      for (let k = messages.count - 1; k >= 0 && k >= messages.count - 4; k--) {
        let m = messages.get(k)
        if (m.role === "nova" && m.pending) {
          messages.setProperty(k, "pending", false)
          if (ev.stale) { messages.setProperty(k, "text", m.text + staleNote); messages.setProperty(k, "spoken", 0) }
          break
        }
      }
      break
    }
    case "exit":
      if (ev.superseded) break           // the turn that cut it off is still running
      liveSpoken = -1
      typedPending = false
      if (!voiceBusy) dropLiveUser()
      break
    }
    streaming = lastNova() >= 0
    scrollDown()
  }

  // ---- layout
  Rectangle {
    anchors.fill: parent
    color: Theme.colors.panel
    radius: metrics.radiusLarge
  }

  // header: Nova's lynx on the left; beside it her name, what she's doing (with the live voice level while
  // listening / speaking) and the background-agents toggle, whose list drops open under the whole header
  Item {
    id: header
    x: metrics.marginBar
    y: metrics.marginBar
    width: parent.width - metrics.marginBar * 2
    height: Math.max(avatar.height, side.height) + metrics.spacingSmall

    NovaAvatar {
      id: avatar
      x: metrics.s(4)
      anchors.verticalCenter: parent.verticalCenter
      disc: metrics.s(104)
      mood: chat.lynxMood
      tint: chat.lynxTint
      level: root.voiceLevel
      active: chat.isOpen
    }
    Column {
      id: side
      x: avatar.x + avatar.width + metrics.spacingLarge + metrics.s(4)
      width: parent.width - x
      anchors.verticalCenter: parent.verticalCenter
      spacing: metrics.spacingNormal
      Column {
        leftPadding: metrics.s(12)
        spacing: metrics.s(3)
        Text {
          id: title
          text: "Nova"
          color: Theme.colors.textPrimary
          font.pixelSize: metrics.fontLarge
          font.family: Theme.fonts.mono
          font.weight: Font.DemiBold
        }
        Row {
          spacing: metrics.spacingSmall
          height: statusText.implicitHeight
          Text {
            id: statusText
            text: chat.lynxLabel
            color: chat.lynxTint
            font.pixelSize: metrics.fontSmall
            font.family: Theme.fonts.mono
            Behavior on color { enabled: !Theme.fading; ColorAnimation { duration: Motion.slow; easing.type: Motion.easeIn } }
          }
          // live level: the shared voice meter history, newest on the right
          Row {
            id: wave
            anchors.verticalCenter: parent.verticalCenter
            spacing: metrics.s(2)
            opacity: avatar.live ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: Motion.enter; easing.type: Motion.easeIn } }
            Repeater {
              model: root.voiceLevels.length
              Rectangle {
                required property int index
                anchors.verticalCenter: parent.verticalCenter
                width: metrics.s(3)
                height: metrics.s(3) + Math.min(1, root.voiceLevels[index] || 0) * metrics.s(11)
                radius: width / 2
                color: chat.lynxTint
                opacity: 0.45 + 0.55 * index / Math.max(1, root.voiceLevels.length - 1)
                Behavior on height { NumberAnimation { duration: 80 } }
              }
            }
          }
          // thinking: three dots taking turns
          Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: metrics.s(3)
            visible: chat.lynxMood === "thinking"
            Repeater {
              model: 3
              Rectangle {
                id: tdot
                required property int index
                width: metrics.s(4); height: width; radius: width / 2
                color: chat.lynxTint
                opacity: 0.3
                SequentialAnimation on opacity {
                  running: chat.isOpen && chat.lynxMood === "thinking"
                  loops: Animation.Infinite
                  PauseAnimation { duration: tdot.index * 180 }
                  NumberAnimation { to: 1; duration: 320; easing.type: Motion.easeAmbient }
                  NumberAnimation { to: 0.3; duration: 320; easing.type: Motion.easeAmbient }
                  PauseAnimation { duration: (2 - tdot.index) * 180 }
                }
              }
            }
          }
        }
      }

      // background agents toggle (agents from the last day; "none" when empty)
      Rectangle {
        width: parent.width
        height: metrics.s(30)
        radius: metrics.radiusNormal
        color: Theme.colors.inset
        Text {
          x: metrics.s(12)
          width: parent.width - x - metrics.s(36)
          anchors.verticalCenter: parent.verticalCenter
          elide: Text.ElideRight
          text: "󰚩  Agents" + (chat.shownAgents.length === 0 ? "  ·  none" : "")
                + (chat.agentsRunning ? "  ·  " + chat.agentsRunning + " running" : "")
                + (chat.agentsQueued ? "  ·  " + chat.agentsQueued + " queued" : "")
                + ((chat.shownAgents.length - chat.agentsRunning - chat.agentsQueued - chat.agentsFailed) ? "  ·  " + (chat.shownAgents.length - chat.agentsRunning - chat.agentsQueued - chat.agentsFailed) + " done" : "")
                + (chat.agentsFailed ? "  ·  " + chat.agentsFailed + " failed" : "")
          color: chat.agentsRunning ? Theme.colors.teal : chat.agentsQueued ? Theme.colors.yellow
                 : chat.shownAgents.length ? Theme.colors.textSecondary : Theme.colors.textMuted
          font.pixelSize: metrics.fontSmall
          font.family: Theme.fonts.mono
        }
        Text {
          anchors.right: parent.right
          anchors.rightMargin: metrics.s(12)
          anchors.verticalCenter: parent.verticalCenter
          text: chat.agentsOpen ? "󰅀" : "󰅂"
          color: Theme.colors.textMuted
          font.pixelSize: metrics.fontSmall
          font.family: Theme.fonts.mono
        }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: chat.agentsOpen = !chat.agentsOpen }
      }
    }
  }

  // background agents: the list the header's toggle opens, full width under the header
  Column {
    id: agentsBox
    visible: chat.agentsOpen
    x: metrics.marginBar
    y: header.y + header.height + metrics.spacingSmall
    width: parent.width - metrics.marginBar * 2

    Flickable {
      width: parent.width
      height: Math.min(agentList.implicitHeight, chat.height * 0.4)
      contentHeight: agentList.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      Column {
        id: agentList
        width: parent.width
        spacing: metrics.s(4)
        Text {
          visible: chat.shownAgents.length === 0
          width: parent.width
          wrapMode: Text.Wrap
          text: "Nothing running. When you ask for something long, Nova hands it to a background agent and it shows up here."
          color: Theme.colors.textMuted
          font.pixelSize: metrics.fontSmall
          font.family: Theme.fonts.mono
        }
        Repeater {
          model: chat.shownAgents
          Rectangle {
            id: arow
            required property var modelData
            readonly property bool open: chat.openAgent === modelData.id
            readonly property color tint: modelData.status === "running" ? Theme.colors.teal
                                          : modelData.status === "queued" ? Theme.colors.yellow
                                          : modelData.status === "done" ? Theme.colors.green : Theme.colors.red
            readonly property int run: modelData.run || 1
            readonly property var earlier: modelData.runs || []
            width: agentList.width
            height: arowCol.implicitHeight + metrics.s(12)
            radius: metrics.radiusNormal
            color: arow.open ? Theme.colors.panelDeep : "transparent"
            border.width: Theme.bw(1)
            border.color: Theme.colors.border
            Column {
              id: arowCol
              x: metrics.s(10); y: metrics.s(6)
              width: parent.width - metrics.s(20)
              spacing: metrics.s(4)
              Item {
                width: parent.width
                height: metrics.s(20)
                Text {
                  id: aicon
                  anchors.verticalCenter: parent.verticalCenter
                  text: arow.modelData.status === "running" ? "󰑮" : arow.modelData.status === "queued" ? "󰔟"
                        : arow.modelData.status === "done" ? "󰄬" : "󰅖"
                  color: arow.tint
                  font.pixelSize: metrics.fontNormal
                  font.family: Theme.fonts.mono
                  SequentialAnimation on opacity {
                    running: arow.modelData.status === "running" && chat.isOpen
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.35; duration: 700 }
                    NumberAnimation { to: 1.0; duration: 700 }
                  }
                }
                Text {
                  id: alabel
                  x: aicon.width + metrics.spacingSmall
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.min(implicitWidth, parent.width - x - awhen.width - abadges.width - metrics.spacingNormal * 2)
                  elide: Text.ElideRight
                  text: arow.modelData.label
                  color: Theme.colors.textPrimary
                  font.pixelSize: metrics.fontSmall
                  font.family: Theme.fonts.mono
                }
                Row {                      // resumed agents: which run this is, and follow-ups waiting behind it
                  id: abadges
                  x: alabel.x + alabel.width + metrics.spacingSmall
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: metrics.s(4)
                  Repeater {
                    model: [arow.run > 1 ? "↻ run " + arow.run : "",
                            arow.modelData.pending ? "+" + arow.modelData.pending + " queued" : ""].filter(x => x)
                    Rectangle {
                      required property string modelData
                      width: abadge.implicitWidth + metrics.s(10)
                      height: abadge.implicitHeight + metrics.s(2)
                      radius: height / 2
                      color: "transparent"
                      border.width: Theme.bw(1)
                      border.color: modelData.startsWith("+") ? Theme.colors.yellow : arow.tint
                      Text {
                        id: abadge
                        anchors.centerIn: parent
                        text: parent.modelData
                        color: parent.border.color
                        font.pixelSize: metrics.fontTiny
                        font.family: Theme.fonts.mono
                      }
                    }
                  }
                }
                MouseArea {                // title line toggles the details; the text below stays selectable
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: chat.openAgent = arow.open ? "" : arow.modelData.id
                }
                Text {
                  id: awhen
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: chat.agentWhen(arow.modelData)
                  color: Theme.colors.textMuted
                  font.pixelSize: metrics.fontTiny
                  font.family: Theme.fonts.mono
                }
              }
              Text {                       // model and thinking level this agent runs on
                visible: text !== ""
                x: aicon.width + metrics.spacingSmall
                width: parent.width - x
                elide: Text.ElideRight
                text: chat.agentModel(arow.modelData)
                color: Theme.colors.textMuted
                font.pixelSize: metrics.fontTiny
                font.family: Theme.fonts.mono
              }
              TextEdit {
                visible: arow.open && arow.modelData.task !== ""
                width: parent.width
                text: "Task: " + arow.modelData.task
                readOnly: true; selectByMouse: true; textFormat: TextEdit.PlainText
                wrapMode: TextEdit.Wrap
                color: Theme.colors.textMuted
                font.pixelSize: metrics.fontTiny
                font.family: Theme.fonts.mono
              }
              TextEdit {                   // what this run was asked (a resumed agent's follow-up message)
                visible: arow.open && !!arow.modelData.followup
                width: parent.width
                text: "Follow-up (run " + arow.run + "): " + (arow.modelData.followup || "")
                readOnly: true; selectByMouse: true; textFormat: TextEdit.PlainText
                wrapMode: TextEdit.Wrap
                color: Theme.colors.textMuted
                font.pixelSize: metrics.fontTiny
                font.family: Theme.fonts.mono
              }
              TextEdit {
                visible: arow.open
                width: parent.width
                text: arow.modelData.result ? (arow.run > 1 ? "Run " + arow.run + ": " : "") + arow.modelData.result
                      : arow.modelData.status === "running" ? (arow.run > 1 ? "Run " + arow.run + " still working…" : "Still working…")
                      : arow.modelData.status === "queued" ? "Follow-up accepted, run " + arow.run + " hasn't started yet."
                      : "(no result text)"
                readOnly: true; selectByMouse: true; textFormat: TextEdit.PlainText
                wrapMode: TextEdit.Wrap
                color: Theme.colors.textSecondary
                font.pixelSize: metrics.fontSmall
                font.family: Theme.fonts.mono
              }
              Text {                       // earlier runs of a resumed agent, collapsed so they don't read as the current one
                visible: arow.open && arow.earlier.length > 0
                text: (chat.openRuns === arow.modelData.id ? "󰅀 " : "󰅂 ") + "Earlier runs (" + arow.earlier.length + ")"
                color: Theme.colors.textMuted
                font.pixelSize: metrics.fontTiny
                font.family: Theme.fonts.mono
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: chat.openRuns = chat.openRuns === arow.modelData.id ? "" : arow.modelData.id
                }
              }
              Repeater {
                model: arow.open && chat.openRuns === arow.modelData.id ? arow.earlier.slice().reverse() : []
                TextEdit {
                  required property var modelData
                  width: arowCol.width
                  leftPadding: metrics.s(10)
                  text: "Run " + modelData.run + " · " + modelData.status
                        + (modelData.endedAt && modelData.startedAt ? " · took " + chat.fmtDur(modelData.endedAt - modelData.startedAt) : "")
                        + (modelData.endedAt ? " · " + chat.fmtDur(chat.now - modelData.endedAt) + " ago" : "")
                        + (modelData.task ? "\nFollow-up: " + modelData.task : "")
                        + "\n" + (modelData.result || "(no result text)")
                  readOnly: true; selectByMouse: true; textFormat: TextEdit.PlainText
                  wrapMode: TextEdit.Wrap
                  color: Theme.colors.textMuted
                  font.pixelSize: metrics.fontTiny
                  font.family: Theme.fonts.mono
                }
              }
            }
          }
        }
      }
    }
  }

  // conversation
  ListView {
    id: log
    x: metrics.marginBar
    y: (agentsBox.visible ? agentsBox.y + agentsBox.height : header.y + header.height) + metrics.spacingNormal
    width: parent.width - metrics.marginBar * 2
    height: (attachRow.visible ? attachRow.y : inputBar.y) - y - metrics.spacingNormal
    clip: true
    spacing: metrics.spacingSmall
    model: messages
    boundsBehavior: Flickable.StopAtBounds
    onMovementEnded: chat.follow = atYEnd
    onContentHeightChanged: if (chat.follow) Qt.callLater(positionViewAtEnd)   // bubbles size in after the jump; streaming replies grow

    delegate: Item {
      id: row
      required property string role
      required property string text
      required property string speaker
      required property bool pending
      required property int hl
      required property int spoken      // chars of text that were read aloud; -1 = not a spoken turn (or all spoken)
      required property string imgs
      readonly property bool mine: role === "user"
      readonly property bool md: role === "nova"      // assistant replies render as markdown; yours and errors stay plain
      // Spoken turns: whatever wasn't read aloud (after [quiet], a late answer, a long pause) is shown dimmed behind a
      // muted-speaker glyph, so it's clear what you heard vs what only landed here. (The word-by-word highlight of
      // the reply being read aloud is gone: it can't be done inside markdown.)
      // ```quiz blocks render as NovaQuiz below the text (wherever they sit, usually after [quiet]); never as text
      readonly property var quizzes: row.md && row.text.indexOf("quiz") >= 0 ? QuizFmt.find(row.text) : []
      // the cut never splits a quiz block or a fenced code block
      readonly property int cut: (row.md && row.spoken >= 0 && row.spoken < row.text.length) ? Md.safeCut(row.text, QuizFmt.safeCut(row.text, row.spoken)) : -1
      readonly property string mainRaw: row.md ? QuizFmt.strip(row.cut >= 0 ? row.text.slice(0, row.cut) : row.text) : ""
      readonly property string dimRaw: row.cut >= 0 ? QuizFmt.strip(row.text.slice(row.cut)) : ""
      readonly property var mainR: row.md ? Md.render(row.mainRaw, { c: chat.mdColors, px: metrics.fontNormal, pending: row.pending && row.dimRaw.trim() === "" })
                                          : ({ blocks: [], plain: "", wide: false })
      readonly property var dimR: row.dimRaw !== "" ? Md.render(row.dimRaw, { c: chat.mdColors, px: metrics.fontNormal, pending: row.pending })
                                                    : ({ blocks: [], plain: "", wide: false })
      function plainRich() {
        let e = row.text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/\n/g, "<br>")
        return e + (row.pending ? " ▍" : "")
      }
      readonly property var pics: {
        let l = row.imgs ? row.imgs.split("\n") : []
        if (row.md) for (let p of chat.mediaPaths(row.text)) l.push(p)
        return l
      }
      readonly property real maxW: (log.width - chat.gutter) * 0.82
      readonly property real gap: metrics.s(4)
      width: log.width - chat.gutter
      height: (who.visible ? who.height : 0) + (picRow.visible ? picRow.height + gap : 0)
              + (bubble.visible ? bubble.height : 0)

      Flow {
        id: picRow
        visible: row.pics.length > 0
        y: row.md ? (bubble.visible ? bubble.y + bubble.height + row.gap : 0) : (who.visible ? who.height : 0)
        anchors.right: row.mine ? parent.right : undefined
        width: row.maxW
        spacing: metrics.s(4)
        layoutDirection: row.mine ? Qt.RightToLeft : Qt.LeftToRight
        Repeater {
          model: row.pics
          Rectangle {
            id: pic
            required property string modelData
            // pasted images are local files; MEDIA paths come from the gateway host and are cached by mediaFetch
            readonly property bool remote: row.md && !row.imgs.split("\n").includes(modelData)
            readonly property string st: !remote ? "ok" : (chat.mediaState[modelData] || "")
            readonly property string src: !remote ? modelData : chat.mediaLocal(modelData)
            Component.onCompleted: if (remote && !row.pending) chat.mediaFetch(modelData)
            Connections { target: row; function onPendingChanged() { if (pic.remote && !row.pending) chat.mediaFetch(pic.modelData) } }
            height: metrics.s(st === "fail" ? 28 : 200)
            width: st === "ok" ? Math.max(metrics.s(40), Math.min(img.implicitWidth * (height / Math.max(1, img.implicitHeight)), row.maxW))
                   : Math.min(metrics.s(220), row.maxW)
            radius: metrics.radiusNormal
            color: Theme.colors.inset
            clip: true
            Image {
              id: img
              anchors.fill: parent
              visible: pic.st === "ok"
              source: pic.st === "ok" ? "file://" + pic.src : ""
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              sourceSize.height: metrics.s(480)
            }
            Text {
              anchors.centerIn: parent
              visible: pic.st !== "ok"
              text: pic.st === "fail" ? "󰋩  image unavailable" : "󰋩  loading…"
              color: pic.st === "fail" ? Theme.colors.red : Theme.colors.textMuted
              font.pixelSize: metrics.fontSmall
              font.family: Theme.fonts.mono
            }
            MouseArea {
              anchors.fill: parent
              enabled: pic.st === "ok"
              cursorShape: Qt.PointingHandCursor
              onClicked: Quickshell.execDetached(["xdg-open", pic.src])
            }
          }
        }
      }

      Text {
        id: who
        visible: row.mine && row.speaker !== "" && row.speaker.toLowerCase() !== chat.owner
        anchors.right: parent.right
        text: row.speaker.charAt(0).toUpperCase() + row.speaker.slice(1)
        color: Theme.colors.textMuted
        font.pixelSize: metrics.fontTiny
        font.family: Theme.fonts.mono
      }
      // short one-paragraph replies get a bubble that fits them; anything with structure takes the full width
      TextMetrics { id: tm; font: body.font; text: row.md ? row.mainR.plain + row.dimR.plain + (row.dimR.blocks.length ? "xx" : "") + (row.pending ? "xx" : "") : row.text }
      Rectangle {
        id: bubble
        visible: row.md ? (row.mainR.blocks.length > 0 || row.dimR.blocks.length > 0 || row.pending || row.quizzes.length > 0) : row.text !== ""
        y: (who.visible ? who.height : 0) + (picRow.visible && !row.md ? picRow.height + row.gap : 0)
        anchors.right: row.mine ? parent.right : undefined
        anchors.left: row.mine ? undefined : parent.left
        width: row.md && (row.mainR.wide || row.dimR.wide || row.quizzes.length > 0) ? row.maxW : Math.min(tm.advanceWidth + metrics.s(24), row.maxW)
        height: bodyCol.implicitHeight + metrics.s(14)
        radius: metrics.radiusNormal
        color: row.role === "error" ? Qt.rgba(Theme.colors.red.r, Theme.colors.red.g, Theme.colors.red.b, 0.15)
             : row.mine ? Theme.colors.inset : Theme.colors.panelDeep
        border.width: row.mine ? 0 : 1
        border.color: row.role === "error" ? Theme.colors.red : Theme.colors.border
        Column {
          id: bodyCol
          x: metrics.s(12)
          y: metrics.s(7)
          width: parent.width - metrics.s(24)
          spacing: metrics.s(4)
          // your turns and errors: plain text
          TextEdit {
            id: body
            visible: !row.md
            width: parent.width
            text: row.md ? "" : row.plainRich()
            readOnly: true
            selectByMouse: true
            wrapMode: TextEdit.Wrap
            textFormat: TextEdit.RichText
            color: row.role === "error" ? Theme.colors.red : row.mine ? Theme.colors.textPrimary : Theme.colors.textSecondary
            selectionColor: Theme.colors.blue
            font.pixelSize: metrics.fontNormal
            font.family: Theme.fonts.mono
          }
          // Nova: what was read aloud, then (dimmed, behind a muted-speaker glyph) what only landed here
          NovaMdView {
            visible: row.md && (row.mainR.blocks.length > 0 || (row.pending && row.dimRaw.trim() === ""))
            width: parent.width
            blocks: row.mainR.blocks
            pending: row.pending && row.dimRaw.trim() === ""
          }
          NovaMdView {
            visible: row.dimR.blocks.length > 0
            width: parent.width
            blocks: row.dimR.blocks
            pending: row.pending
            lead: "󰖁 "
            textColor: Theme.colors.textMuted
            opacity: 0.85
          }
          Repeater {
            model: row.quizzes
            Loader {
              id: qload
              required property var modelData
              width: bodyCol.width
              sourceComponent: modelData.quiz ? quizComp : modelData.pending ? quizWait : quizBad
              Component {
                id: quizComp
                NovaQuiz {
                  width: qload.width
                  entry: qload.modelData
                  submitted: !!chat.quizDone[qload.modelData.key]
                  canSubmit: !chat.busy
                  draft: chat.quizDone[qload.modelData.key] ? QuizFmt.parseAnswers(qload.modelData, chat.quizDone[qload.modelData.key])
                         : (chat.quizDrafts[qload.modelData.key] || {})
                  onEdited: d => { chat.quizDrafts[qload.modelData.key] = d }
                  onSubmit: message => chat.submitQuiz(qload.modelData.key, message)
                }
              }
              Component {
                id: quizWait
                Text { text: "󰠗  quiz loading…"; color: Theme.colors.textMuted; font.pixelSize: metrics.fontSmall; font.family: Theme.fonts.mono }
              }
              Component {
                id: quizBad
                TextEdit {
                  width: qload.width
                  text: "󰠗  couldn't read this quiz (" + (qload.modelData.error || "?") + "):\n" + (qload.modelData.raw || "")
                  readOnly: true; selectByMouse: true
                  wrapMode: TextEdit.Wrap
                  color: Theme.colors.red
                  font.pixelSize: metrics.fontSmall
                  font.family: Theme.fonts.mono
                }
              }
            }
          }
        }
      }
    }

    Text {
      anchors.centerIn: parent
      visible: messages.count === 0
      text: "Type below, or press 󰍬 (or SUPER+T) to talk."
      color: Theme.colors.textMuted
      font.pixelSize: metrics.fontNormal
      font.family: Theme.fonts.mono
    }
  }

  // log scrollbar: drag the handle or click the track to jump; hidden when everything fits
  Item {
    id: scrollTrack
    visible: log.contentHeight > log.height + 1
    x: log.x + log.width - width
    y: log.y
    width: metrics.s(6)
    height: log.height
    Rectangle { anchors.fill: parent; radius: width / 2; color: Theme.colors.inset; opacity: 0.6 }
    Rectangle {
      id: handle
      width: parent.width
      radius: width / 2
      height: Math.max(metrics.s(28), log.visibleArea.heightRatio * scrollTrack.height)
      y: Math.min(scrollTrack.height - height, Math.max(0, log.visibleArea.yPosition * scrollTrack.height))
      color: dragArea.pressed || dragArea.containsMouse ? Theme.colors.textSecondary : Theme.colors.textMuted
    }
    MouseArea {
      id: dragArea
      anchors.fill: parent
      anchors.leftMargin: -metrics.s(6)                     // easier to grab
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      property real grab: 0
      function scrollTo(my) {
        let span = scrollTrack.height - handle.height
        let f = span > 0 ? Math.min(1, Math.max(0, (my - grab) / span)) : 0
        log.contentY = log.originY + f * Math.max(0, log.contentHeight - log.height)
        chat.follow = f >= 0.999
      }
      onPressed: mouse => {
        let onHandle = mouse.y >= handle.y && mouse.y <= handle.y + handle.height
        grab = onHandle ? mouse.y - handle.y : handle.height / 2
        scrollTo(mouse.y)
      }
      onPositionChanged: mouse => { if (pressed) scrollTo(mouse.y) }
    }
  }

  // jump back to the latest message when scrolled up
  Rectangle {
    visible: scrollTrack.visible && !log.atYEnd
    width: metrics.s(30); height: width; radius: width / 2
    x: log.x + log.width - chat.gutter - width - metrics.spacingSmall
    y: log.y + log.height - height - metrics.spacingSmall
    color: Theme.colors.inset
    border.width: Theme.bw(1)
    border.color: Theme.colors.border
    Text { anchors.centerIn: parent; text: "󰁅"; color: Theme.colors.blue; font.pixelSize: metrics.fontNormal; font.family: Theme.fonts.mono }
    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: chat.scrollDown(true) }
  }

  // pending attachments (Ctrl+V / drop): thumbnails with a remove button, sent with the next message
  Row {
    id: attachRow
    visible: chat.attachments.length > 0
    x: metrics.marginBar
    y: inputBar.y - height - metrics.spacingSmall
    spacing: metrics.spacingSmall
    Repeater {
      model: chat.attachments
      Rectangle {
        required property string modelData
        required property int index
        width: metrics.s(64); height: metrics.s(64)
        radius: metrics.radiusNormal
        color: Theme.colors.inset
        clip: true
        Image {
          anchors.fill: parent; anchors.margins: metrics.s(3)
          source: "file://" + parent.modelData
          fillMode: Image.PreserveAspectCrop
          sourceSize.height: metrics.s(128)
          asynchronous: true
        }
        Rectangle {
          anchors.right: parent.right; anchors.top: parent.top; anchors.margins: metrics.s(2)
          width: metrics.s(18); height: width; radius: width / 2
          color: Theme.colors.panelDeep
          Text { anchors.centerIn: parent; text: "󰅖"; color: Theme.colors.red; font.pixelSize: metrics.fontTiny; font.family: Theme.fonts.mono }
          MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: chat.unattach(parent.parent.index) }
        }
      }
    }
  }

  // input row: text box, mic, stop/send
  Item {
    id: inputBar
    x: metrics.marginBar
    width: parent.width - metrics.marginBar * 2
    height: metrics.s(36)
    y: parent.height - height - metrics.marginBar

    Rectangle {
      id: box
      anchors.left: parent.left
      anchors.right: langBtn.left
      anchors.rightMargin: metrics.spacingSmall
      height: parent.height
      radius: metrics.radiusNormal
      color: Theme.colors.inset

      Text {
        x: metrics.s(12)
        anchors.verticalCenter: parent.verticalCenter
        text: chat.busy ? (chat.canBargeIn ? "Nova is answering… (Enter cuts in)" : "Nova is listening…") : "Message Nova…"
        color: Theme.colors.textMuted
        font.pixelSize: metrics.fontNormal
        font.family: Theme.fonts.mono
        visible: !input.text
      }
      TextInput {
        id: input
        x: metrics.s(12)
        width: parent.width - metrics.s(24)
        anchors.verticalCenter: parent.verticalCenter
        color: Theme.colors.textPrimary
        font.pixelSize: metrics.fontNormal
        font.family: Theme.fonts.mono
        clip: true
        focus: true
        Keys.onPressed: event => {
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            chat.send(); event.accepted = true
          } else if (event.key === Qt.Key_L && (event.modifiers & Qt.ControlModifier)) {
            chat.langOpen = !chat.langOpen; event.accepted = true
          } else if (event.key === Qt.Key_Escape) {
            if (chat.langOpen) chat.langOpen = false
            else if (chat.busy) chat.stop(); else bar.state = "normal"
            event.accepted = true
          } else if (event.key === Qt.Key_V && (event.modifiers & Qt.ControlModifier)) {
            chat.pasteImage(); event.accepted = true      // image if the clipboard has one, else plain text
          } else if (event.key === Qt.Key_Up && input.text === "") {
            input.text = chat.lastTyped; event.accepted = true
          } else if (event.key === Qt.Key_Space && (event.modifiers & Qt.ControlModifier)) {
            chat.micPressed(); event.accepted = true
          }
        }
      }
    }

    // speech language chip: AUTO / RU / DE ...; click (or Ctrl+L) opens the list above it
    Rectangle {
      id: langBtn
      anchors.right: micBtn.left
      anchors.rightMargin: metrics.spacingSmall
      width: Math.max(parent.height, langText.implicitWidth + metrics.s(16)); height: parent.height
      radius: metrics.radiusNormal
      color: chat.langOpen || langMouse.containsMouse ? Theme.colors.panelDeep : Theme.colors.inset
      border.width: chat.sttLang !== "auto" ? Theme.bw(1) : 0
      border.color: Theme.colors.teal
      Rectangle {                        // flash when Nova switches it
        id: langGlow
        anchors.fill: parent
        radius: parent.radius
        color: Theme.colors.teal
        opacity: 0
        NumberAnimation on opacity { id: langFlash; running: false; from: 0.55; to: 0; duration: 900; easing.type: Easing.OutCubic }
      }
      Text {
        id: langText
        anchors.centerIn: parent
        text: chat.sttLang.toUpperCase()
        color: chat.sttLang !== "auto" ? Theme.colors.teal : Theme.colors.textMuted
        font.pixelSize: metrics.fontSmall
        font.family: Theme.fonts.mono
        font.weight: Font.DemiBold
      }
      MouseArea {
        id: langMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: chat.langOpen = !chat.langOpen
      }
    }

    Rectangle {
      id: micBtn
      anchors.right: actBtn.left
      anchors.rightMargin: metrics.spacingSmall
      width: parent.height; height: parent.height
      radius: metrics.radiusNormal
      color: chat.mode === "voice" ? chat.statusColor : Theme.colors.inset
      opacity: chat.busy && chat.mode === "text" ? 0.4 : 1
      Text {
        anchors.centerIn: parent
        text: "󰍬"
        color: chat.mode === "voice" ? Theme.colors.background : Theme.colors.teal
        font.pixelSize: metrics.fontLarge
        font.family: Theme.fonts.mono
      }
      MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: chat.micPressed() }
    }

    Rectangle {
      id: actBtn
      anchors.right: parent.right
      width: parent.height; height: parent.height
      radius: metrics.radiusNormal
      color: Theme.colors.inset
      Text {
        anchors.centerIn: parent
        text: chat.busy ? "󰓛" : "󰒊"
        color: chat.busy ? Theme.colors.red : Theme.colors.blue
        font.pixelSize: metrics.fontLarge
        font.family: Theme.fonts.mono
      }
      MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: chat.busy ? chat.stop() : chat.send() }
    }
  }

  // speech language list (the chip's popup): Auto on top, then two columns of languages; a click anywhere else closes it
  MouseArea {
    anchors.fill: parent
    visible: chat.langOpen
    onClicked: chat.langOpen = false
  }
  Rectangle {
    id: langPop
    visible: chat.langOpen
    width: Math.min(metrics.s(340), inputBar.width)
    height: langCol.implicitHeight + metrics.s(16)
    x: Math.max(metrics.marginBar, inputBar.x + langBtn.x + langBtn.width - width)
    y: inputBar.y - height - metrics.spacingSmall
    radius: metrics.radiusNormal
    color: Theme.colors.panelDeep
    border.width: Theme.bw(1)
    border.color: Theme.colors.border
    MouseArea { anchors.fill: parent }  // clicks between rows don't fall through and close it
    Column {
      id: langCol
      x: metrics.s(8); y: metrics.s(8)
      width: parent.width - metrics.s(16)
      spacing: metrics.s(4)
      Text {
        leftPadding: metrics.s(4)
        text: "speech language"
        color: Theme.colors.textMuted
        font.pixelSize: metrics.fontTiny
        font.family: Theme.fonts.mono
      }
      Flow {
        width: parent.width
        spacing: metrics.s(3)
        Repeater {
          model: [{ code: "auto", label: "automatic detection" }].concat(chat.langChoices)
          Rectangle {
            id: lrow
            required property var modelData
            readonly property bool current: chat.sttLang === modelData.code
            width: modelData.code === "auto" ? langCol.width : (langCol.width - metrics.s(3)) / 2
            height: metrics.s(26)
            radius: metrics.radiusNormal
            color: current ? Theme.colors.inset : lmouse.containsMouse ? Qt.rgba(Theme.colors.inset.r, Theme.colors.inset.g, Theme.colors.inset.b, 0.6) : "transparent"
            border.width: current ? Theme.bw(1) : 0
            border.color: Theme.colors.teal
            Text {
              id: lcode
              x: metrics.s(8)
              width: metrics.s(48)
              anchors.verticalCenter: parent.verticalCenter
              text: lrow.modelData.code.toUpperCase()
              color: lrow.current ? Theme.colors.teal : Theme.colors.textSecondary
              font.pixelSize: metrics.fontSmall
              font.family: Theme.fonts.mono
              font.weight: Font.DemiBold
            }
            Text {
              anchors.left: lcode.right
              anchors.right: parent.right
              anchors.rightMargin: metrics.s(6)
              anchors.verticalCenter: parent.verticalCenter
              text: lrow.modelData.label
              elide: Text.ElideRight
              color: lrow.current ? Theme.colors.textPrimary : Theme.colors.textSecondary
              font.pixelSize: metrics.fontSmall
              font.family: Theme.fonts.mono
            }
            MouseArea { id: lmouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: chat.setLang(lrow.modelData.code) }
          }
        }
      }
      Text {
        leftPadding: metrics.s(4)
        width: parent.width
        wrapMode: Text.WordWrap
        text: "Nova can switch it too · back to auto after " + Math.round((chat.langState.idle_s || 1800) / 60) + " min idle"
        color: Theme.colors.textMuted
        font.pixelSize: metrics.fontTiny
        font.family: Theme.fonts.mono
      }
    }
  }
}
