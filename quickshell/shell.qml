import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import QtQuick.Effects
import Quickshell
import Quickshell.Services.Pipewire
import Quickshell.Widgets
import Quickshell.Hyprland
import Quickshell.Wayland
import Qt.labs.folderlistmodel
import Qt5Compat.GraphicalEffects
import Quickshell.Io
import "templates"
import "themes"

Scope {
  id: root

  property string home: Quickshell.env("HOME")

  // === SHARED DATA (runs once, not per-screen) ===
  property string tempValue: "0"
  property string batteryPercent: "0"
  property string batteryIcon: ""
  property bool hasBattery: false
  property string cpuLoad: "0"
  // Derive volume/mute state directly from the current default sink so the
  // widget stays correct when the default sink changes (device switch, headphones
  // plugged in, sink ready after startup). Imperative updates went stale on rebind.
  readonly property var sinkAudio: Pipewire.defaultAudioSink?.audio ?? null
  readonly property string volumePercent: Math.round((sinkAudio?.volume ?? 0) * 100).toString()
  readonly property string volumeIcon: (sinkAudio?.muted ?? false) ? "󰖁" : "󰕾"
  property bool hasBrightness: false
  property real brightnessValue: 0    // 0.0 – 1.0
  property int brightnessMax: 1
  property int lowBatteryThreshold: 15
  property bool lowBatteryWarningShown: false
  property int lowBatteryTrigger: 0

  // PipeWire volume tracking (shared). The tracker keeps the node's audio
  // properties live; volumePercent/volumeIcon above bind to them reactively,
  // so they stay correct across default-sink changes without manual updates.
  PwObjectTracker {
    objects: [ Pipewire.defaultAudioSink ]
  }

  // === POLLING PROCESSES (shared) ===
  PollProcess {
    id: tempProc
    command: ["bash", root.home + "/.config/scripts/polls/temppoll.sh"]
    interval: 2000
    onOutput: text => root.tempValue = text
  }

  PollProcess {
    id: batteryPercentProc
    command: ["bash", root.home + "/.config/scripts/polls/batterypoll1.sh"]
    interval: 5000
    onOutput: text => {
      root.hasBattery = text !== "" && !isNaN(parseInt(text))
      if (!root.hasBattery) {
        root.batteryPercent = "0"
        root.lowBatteryWarningShown = false
        return
      }
      root.batteryPercent = text
      let currentPercent = parseInt(text)
      if (currentPercent > root.lowBatteryThreshold + 5) {
        root.lowBatteryWarningShown = false
      }
      if (currentPercent <= root.lowBatteryThreshold && !root.lowBatteryWarningShown) {
        root.lowBatteryWarningShown = true
        root.lowBatteryTrigger++
      }
    }
  }

  PollProcess {
    id: batteryIconProc
    command: ["bash", root.home + "/.config/scripts/polls/batterypoll2.sh"]
    interval: 5000
    onOutput: text => root.batteryIcon = text
  }

  PollProcess {
    id: cpuProc
    command: ["bash", root.home + "/.config/scripts/polls/cpupoll.sh"]
    interval: 2000
    onOutput: text => root.cpuLoad = text
  }

  // Brightness detection + polling
  Process {
    id: brightnessMaxProc
    command: ["cat", "/sys/class/backlight/amdgpu_bl2/max_brightness"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        let val = parseInt(this.text.trim())
        if (val > 0) {
          root.brightnessMax = val
          root.hasBrightness = true
        }
      }
    }
  }

  PollProcess {
    id: brightnessProc
    command: ["cat", "/sys/class/backlight/amdgpu_bl2/brightness"]
    interval: 2000
    poll: root.hasBrightness
    onOutput: text => {
      if (root.hasBrightness) {
        root.brightnessValue = parseInt(text) / root.brightnessMax
      }
    }
  }

  Process {
    id: brightnessSetProc
    command: ["brightnessctl", "set", "0"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: brightnessProc.running = true  // re-read after set
    }
  }

  // === GLOBAL SHORTCUTS (registered once) ===
  property int toggleCounter: 0
  property string toggleTarget: ""
  property string toggleMonitor: ""   // monitor name from IPC, "" = the focused monitor

  GlobalShortcut {
    name: "toggleDashboard"
    onPressed: { root.toggleTarget = "dashboard"; root.toggleMonitor = ""; root.toggleCounter++ }
  }

  // Fullscreen dashboard: opens it full-size if closed, else toggles the size.
  // Per monitor like the other toggles — only the focused monitor's bar reacts.
  property int fullCounter: 0
  property string fullTarget: ""      // monitor name from IPC, "" = the focused monitor
  GlobalShortcut {
    name: "toggleDashboardFullscreen"
    onPressed: { root.fullTarget = ""; root.fullCounter++ }
  }

  GlobalShortcut {
    name: "toggleWallpaperSelector"
    onPressed: { root.toggleTarget = "wallpaper_selector"; root.toggleMonitor = ""; root.toggleCounter++ }
  }

  GlobalShortcut {
    name: "toggleAppSelector"
    onPressed: { root.toggleTarget = "app_selector"; root.toggleMonitor = ""; root.toggleCounter++ }
  }

  GlobalShortcut {
    name: "togglePowerMenu"
    onPressed: { root.toggleTarget = "power_menu"; root.toggleMonitor = ""; root.toggleCounter++ }
  }

  // Nova chat panel (NovaChatWidget.qml): only on machines set up for the voice assistant
  GlobalShortcut {
    name: "toggleNovaChat"
    onPressed: if (root.voiceEnabled) { root.toggleTarget = "nova_chat"; root.toggleMonitor = ""; root.toggleCounter++ }
  }

  // === CONTROL CENTER (ControlCenterWidget.qml in the pocket under the clock) ===
  // ControlCenterService is the notification daemon (org.freedesktop.Notifications),
  // do not disturb and the `controlcenter` IPC. No pop-ups: the panel and the bell's badge only.
  // Commands go to the focused monitor's bar: op "toggle" | "open" | "close", tab = class or "".
  property int ccCounter: 0
  property string ccOp: ""
  property string ccTab: ""
  function ccCommand(op, tab) { ccOp = op; ccTab = tab; ccCounter++ }
  // Monitors whose bar shows the control center (the list then counts as read).
  property var ccOpenOn: []
  function noteControlCenter(monitor, open) {
    let l = ccOpenOn.filter(m => m !== monitor)
    if (open) l.push(monitor)
    ccOpenOn = l
  }

  ControlCenterService {
    id: controlCenter
    lookingAtList: root.ccOpenOn.length > 0 && tab === "notifications"
    onCommand: (op, tab) => root.ccCommand(op, tab)
  }

  GlobalShortcut {
    name: "toggleControlCenter"
    onPressed: root.ccCommand("toggle", "")
  }
  GlobalShortcut {
    name: "toggleNotifications"
    onPressed: root.ccCommand("toggle", "notifications")
  }

  // Dashboard tabs: next/prev/set on the focused monitor (or a named one, from
  // IPC: `qs ipc call dashboard nextTab` etc. in DashboardConfig.qml).
  property int tabCounter: 0
  property string tabOp: ""
  property string tabArg: ""
  property string tabMonitor: ""
  function tabCommand(op, arg, monitor) { tabOp = op; tabArg = arg; tabMonitor = monitor; tabCounter++ }
  // monitor name -> tab name, for getTab
  property var tabNames: ({})
  function noteTab(monitor, name) { let t = Object.assign({}, tabNames); t[monitor] = name; tabNames = t }

  GlobalShortcut {
    name: "dashboardNextTab"
    onPressed: root.tabCommand("next", "", "")
  }
  GlobalShortcut {
    name: "dashboardPrevTab"
    onPressed: root.tabCommand("prev", "", "")
  }

  // === DASHBOARD PRESETS (shared; presets.json + presets.local.json + IPC) ===
  DashboardConfig {
    id: dashboardConfig
  }
  // === VOICE ASSISTANT STATE (written by scripts/nova_voice.py; shown by VoiceBarWidget) ===
  // Off by default: the indicator only exists on a machine that has the
  // assistant's per-device config, ~/.config/nova-voice/env (nova_voice.sh setup).
  readonly property bool voiceEnabled: voiceConf.loaded
  FileView {
    id: voiceConf
    path: (Quickshell.env("XDG_CONFIG_HOME") || (root.home + "/.config")) + "/nova-voice/env"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
  }
  property string voiceState: "idle"
  property string voiceText: ""
  property string voiceReply: ""
  property bool voiceActive: false   // true while a turn is in flight, plus a short linger so the reply stays readable

  FileView {
    id: voiceStateFile
    path: root.voiceEnabled ? Quickshell.env("XDG_RUNTIME_DIR") + "/nova-voice/state.json" : ""
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyVoiceState()
  }
  // The runtime dir is empty after boot, so the watcher may start before the
  // file exists; a slow reload catches its creation.
  Timer { interval: 1500; repeat: true; running: root.voiceEnabled; onTriggered: voiceStateFile.reload() }
  Timer { id: voiceCloseTimer; interval: 1500; onTriggered: root.voiceActive = false }   // no text to read any more, just let the bars settle

  // Voice level feed (mic while listening, sink monitor while speaking), shared by the bar indicator
  // (VoiceBarWidget) and the chat panel header (NovaChatWidget).
  property var voiceLevels: new Array(10).fill(0)
  property real voiceLevel: 0
  readonly property bool voiceLive: voiceState === "listening" || voiceState === "speaking"
  function pushVoiceLevel(v) { voiceLevel = v; let h = voiceLevels.slice(1); h.push(v); voiceLevels = h }
  readonly property string voiceMeterPy: "import sys,struct,math\nb=sys.stdin.buffer\nwhile True:\n d=b.read(1600)\n if not d: break\n n=len(d)//2\n s=struct.unpack('<%dh'%n,d[:n*2])\n r=math.sqrt(sum(x*x for x in s)/max(n,1))/32768.0\n print(min(1.0,r*7))\n"
  // Two fixed meters instead of one that swaps its command: restarting a Process from onVoiceStateChanged ran
  // before `command` re-evaluated, so "speaking" kept metering the mic.
  Process {
    running: root.voiceEnabled && root.voiceState === "listening"
    command: ["bash", "-c", "pw-record --format s16 --rate 16000 --channels 1 --latency 50ms - 2>/dev/null | python3 -u -c \"" + root.voiceMeterPy + "\""]
    stdout: SplitParser { onRead: data => { let v = parseFloat(data); if (!isNaN(v)) root.pushVoiceLevel(v) } }
  }
  Process {
    running: root.voiceEnabled && root.voiceState === "speaking"
    command: ["bash", "-c", "pw-record -P '{ stream.capture.sink = true }' --format s16 --rate 16000 --channels 1 --latency 50ms - 2>/dev/null | python3 -u -c \"" + root.voiceMeterPy + "\""]
    stdout: SplitParser { onRead: data => { let v = parseFloat(data); if (!isNaN(v)) root.pushVoiceLevel(v) } }
  }
  // soft motion while decoding / thinking; decay otherwise
  Timer {
    interval: 80; repeat: true
    running: root.voiceState === "thinking" || root.voiceState === "transcribing"
    onTriggered: root.pushVoiceLevel(0.1 + 0.2 * (0.5 + 0.5 * Math.sin(Date.now() / 240)) + Math.random() * 0.05)
  }
  Timer {
    interval: 80; repeat: true
    running: !root.voiceLive && root.voiceState !== "thinking" && root.voiceState !== "transcribing" && root.voiceLevel > 0.01
    onTriggered: root.pushVoiceLevel(root.voiceLevel * 0.7)
  }

  // Live event feed from every nova_client process (they append to events.jsonl): the chat panel
  // renders transcripts, live partials and replies from it, whichever of SUPER+T / the panel started the turn.
  signal novaEvent(var ev)
  Process {
    running: root.voiceEnabled
    command: ["bash", "-c", "d=\"${XDG_RUNTIME_DIR:-/tmp}/nova-voice\"; mkdir -p \"$d\"; touch \"$d/events.jsonl\"; exec tail -n0 -F \"$d/events.jsonl\" 2>/dev/null"]
    stdout: SplitParser { onRead: data => { let ev; try { ev = JSON.parse(data) } catch (e) { return } root.novaEvent(ev) } }
  }

  function applyVoiceState() {
    let s
    try { s = JSON.parse(voiceStateFile.text()) } catch (e) { return }
    let prev = root.voiceState
    root.voiceText = s.text ?? ""
    root.voiceReply = s.reply ?? ""
    root.voiceState = s.state ?? "idle"
    if (root.voiceState !== "idle") {
      voiceCloseTimer.stop()
      root.voiceActive = true
    } else if (prev !== "idle") {
      voiceCloseTimer.restart()
    }
  }

  // === WALLPAPER SELECTOR SHARED STATE ===
  // The selector can be open on several monitors at once (the toggle acts on the
  // focused monitor). A single compositor grab whitelists every open selector's
  // window — per-window grabs don't work, the newest grab dismisses the others.
  // Arrow keys are broadcast through wallpaperNavCounter so every open carousel
  // steps together no matter which window receives the key events.
  property var selectorWindows: []
  property int wallpaperNavCounter: 0
  property int wallpaperNavDir: 0
  property int selectorCloseCounter: 0
  // Absolute carousel position shared by every open selector. Relative stepping
  // drifts apart as soon as one carousel flaps or swallows a step; publishing
  // the driving instance's index lets the others converge on the same item.
  property int wallpaperSharedIndex: -1

  function setSelectorOpen(window, open) {
    let list = selectorWindows.filter(w => w !== window)
    if (open) list.push(window)
    selectorWindows = list
    // Imperative (not bound) so a compositor-side clear can't wedge the grab.
    selectorGrab.windows = list
    selectorGrab.active = list.length > 0
  }

  function wallpaperNav(dir) {
    wallpaperNavDir = dir
    wallpaperNavCounter++
  }

  function closeWallpaperSelectors() { selectorCloseCounter++ }

  // Cold-starting/stopping a dynamic wallpaper maps/unmaps background layers,
  // and Hyprland's refocus on that hands the keyboard to the window under the
  // cursor past the grab (or ends the grab). The warm globe avoids this (it's
  // shown/hidden without unmapping), so this is only a safety net now. While a live switch is in flight, a
  // lost grab or keyboard focus is taken back; outside that window a lost grab
  // (e.g. clicking another window) is left alone.
  property real selectorFocusGuardUntil: 0
  property var focusedSelectors: []

  function guardSelectorFocus(ms) {
    selectorFocusGuardUntil = Math.max(selectorFocusGuardUntil, Date.now() + ms)
    selectorFocusCheck.restart()
  }

  function setSelectorFocused(window, focused) {
    let list = focusedSelectors.filter(w => w !== window)
    if (focused) list.push(window)
    focusedSelectors = list
    selectorFocusCheck.restart()
  }

  Timer {
    id: selectorFocusCheck
    interval: 20
    property real lastRearm: 0
    onTriggered: {
      if (root.selectorWindows.length === 0 || Date.now() > root.selectorFocusGuardUntil)
        return
      // Rate-limited so a slow keyboard enter can't make it flap.
      if ((!selectorGrab.active || root.focusedSelectors.length === 0) && Date.now() - lastRearm > 300) {
        lastRearm = Date.now()
        // A fresh grab refocuses the keyboard onto a whitelisted window.
        selectorGrab.active = false
        selectorGrab.windows = root.selectorWindows
        selectorGrab.active = true
      }
      // Layers can keep changing until the guard ends; keep watching.
      restart()
    }
  }

  HyprlandFocusGrab {
    id: selectorGrab
    onCleared: selectorFocusCheck.restart()
  }

  // === PER-SCREEN BAR ===
  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: barWindow
      property var modelData
      screen: modelData

      // Map QScreen -> Hyprland monitor by name
      property var hyprMonitor: {
        let monitors = Hyprland.monitors.values
        for (let i = 0; i < monitors.length; i++) {
          if (monitors[i].name === modelData.name) return monitors[i]
        }
        return null
      }
      property int monitorId: hyprMonitor?.id ?? 0
      property bool isFocused: Hyprland.focusedMonitor?.id === monitorId
      // Dashboard filling this screen (the pocket grows to the whole monitor and
      // the grid's rows scale to fit). Forgotten when the dashboard closes.
      property bool dashboardFull: false

      // === PER-MONITOR METRICS (scale + orientation) ===
      // One instance per screen. Reached by every widget via QML dynamic
      // scoping, exactly like `bar` and `root`. Cannot be a Singleton because
      // scale/orientation differ per monitor and both render simultaneously.
      QtObject {
        id: metrics

        // Post-transform logical size of THIS screen.
        readonly property real screenW: barWindow.screen?.width ?? barWindow.width
        readonly property real screenH: barWindow.screen?.height ?? barWindow.height
        readonly property int transform: barWindow.hyprMonitor?.transform ?? 0

        // Orientation — transform 1/3 = rotated 90/270; dimension test is the
        // robust fallback (a portrait monitor is always taller than it is wide).
        readonly property bool isVertical: (transform === 1 || transform === 3) || (screenW < screenH)

        // Scale from the SHORT axis so a rotated (tall) monitor doesn't scale up.
        readonly property real scale: Math.max(0.5, Math.min(1.25, Math.min(screenW, screenH) / 1440))
        function s(px) { return Math.round(px * scale) }

        // Bar geometry. Thickness follows the short axis (was 2.5% of height).
        // Length is the axis the bar runs along; longPct replaces `%parent.width`.
        readonly property real barThickness: Math.round((isVertical ? 0.037 : 0.025) * Math.min(screenW, screenH))
        readonly property real barLength: isVertical ? screenH : screenW
        // long axis = the direction the bar runs; cross axis = its thickness / pocket depth.
        function longPct(p) { return p / 100 * barLength }
        function crossPct(p) { return p / 100 * (isVertical ? screenW : screenH) }

        // Fonts (collapse ~10 literals into 6 tokens).
        readonly property real fontTiny: s(11)     // 10,11
        readonly property real fontSmall: s(12)    // 12,13
        readonly property real fontNormal: s(14)   // 14 (bar default)
        readonly property real fontLarge: s(16)    // 16
        readonly property real fontXL: s(28)       // 28
        readonly property real fontHuge: s(38)     // 36,38,48

        // Spacing / radii. Pill radii (width/2) stay in-place; hairlines unscaled.
        readonly property real spacingTiny: s(4)
        readonly property real spacingSmall: s(6)
        readonly property real spacingNormal: s(10)
        readonly property real spacingLarge: s(15)
        readonly property real radiusSmall: Theme.rs(s(5))
        readonly property real radiusNormal: Theme.rs(s(10))
        readonly property real radiusLarge: Theme.rs(s(15))
        readonly property real radiusXL: Theme.rs(s(20))

        readonly property real marginBar: s(15)
        readonly property real marginEdge: s(20)
        readonly property real widgetPadding: s(20)   // dropdownWidgetPadding

        // Widget boxes.
        readonly property real profilePicSize: s(100)
        readonly property real dashWidgetHeight: s(160)
        readonly property real dataWidgetHeight: s(190)
        readonly property real systemWidgetHeight: s(280)
        readonly property real appCellHeight: s(120)
        readonly property real sliderTrackWidth: s(80)

        // Dashboard reflow: fewer columns on narrow / portrait screens.
        readonly property int dashColumns: isVertical ? 2 : 4

        // Dashboard card scale: how a card's cell compares with the size it was
        // designed for (refW x refH, unscaled px). Shrinks linearly so text keeps
        // fitting, grows damped so a fullscreen cell doesn't get poster-sized text.
        function cardScale(w, h, refW, refH) {
          let raw = Math.min(w / s(refW), h / s(refH))
          return Math.max(0.8, Math.min(1.8, raw > 1 ? Math.pow(raw, 0.6) : raw))
        }
      }

      // === PER-MONITOR DASHBOARD STATE (health, tabs, standby) ===
      // Reached by widgets via dynamic scoping like `metrics`. Cards report a
      // subsystem level with dashState.report(); the worst one is the health
      // word in the tab strip. Tunables: themes/Dash.qml. Levels: themes/Status.qml.
      QtObject {
        id: dashState

        readonly property bool open: bar.state === "dashboard"
        signal ticked()

        // key -> { level, detail, label, type, ttl }; `seen` holds the last report
        // time per key without notifying (staleness is checked each tick).
        property var reports: ({})
        property var seen: ({})
        property int healthLevel: 0
        property string healthDetail: ""

        function report(key, label, type, level, detail, ttl) {
          seen[key] = Date.now()
          let r = reports[key]
          if (r && r.level === level && r.detail === detail && r.label === label) return
          let next = Object.assign({}, reports)
          next[key] = { label: label, type: type, level: level, detail: detail || "", ttl: ttl || 30000 }
          reports = next
          recompute()
        }

        // Worst level over the subsystems whose card is in the active preset (any
        // tab); a feed silent for longer than its ttl counts as an advisory.
        function recompute() {
          let types = { "_shell": true }
          for (let w of (dashboardGrid.preset?.widgets ?? [])) types[w.type] = true
          let now = Date.now(), worst = 0, detail = ""
          for (let k in reports) {
            let r = reports[k]
            if (!types[r.type]) continue
            let stale = now - (seen[k] || 0) > r.ttl
            let agg = stale ? Status.advisory : r.level
            if (agg > worst) { worst = agg; detail = stale ? r.label + " NO DATA" : r.detail }
          }
          healthLevel = worst
          healthDetail = worst > 0 ? detail : ""
        }

        // Standby: settles after Dash.standbyMs without pointer activity.
        property bool standby: false
        function poke() {
          if (standby) standby = false
          if (open && Dash.standbyEnabled) standbyTimer.restart()
        }

        onOpenChanged: {
          standby = false
          if (open) { recompute(); poke() }
        }
      }
      Timer {
        // 1 Hz while open: strip clock, staleness and the shell-level thermal report.
        interval: 1000
        repeat: true
        running: dashState.open
        triggeredOnStart: true
        onTriggered: {
          let t = parseFloat(root.tempValue)
          if (!isNaN(t) && t > 0) dashState.report("therm", "THERM", "_shell", Status.level("temp", t), "CPU " + t.toFixed(0) + "°C", 10000)
          dashState.recompute()
          dashState.ticked()
        }
      }
      Timer {
        id: standbyTimer
        interval: Dash.standbyMs
        onTriggered: if (dashState.open && Dash.standbyEnabled) dashState.standby = true
      }

      // Dashboard tab on this monitor (tabbed presets; 0 = the first tab, the
      // globe). Kept while the shell runs, not across restarts.
      property int dashTab: 0
      property int tabDir: 1
      function setTab(i, dir) {
        if (i === dashTab || i < 0) return
        tabDir = dir || (i > dashTab ? 1 : -1)
        dashTab = i
        dashState.poke()
      }
      onDashTabChanged: root.noteTab(modelData.name, dashboardGrid.tabs[dashboardGrid.tab]?.name ?? "")

      // Handle global shortcut toggles (only on focused monitor)
      Connections {
        target: root
        function onToggleCounterChanged() {
          if (root.toggleMonitor === "" ? barWindow.isFocused : barWindow.modelData.name === root.toggleMonitor) {
            if (bar.state !== root.toggleTarget) {
              bar.state = root.toggleTarget
            } else {
              bar.state = "normal"
            }
          }
        }
        function onCcCounterChanged() {
          if (!barWindow.isFocused) return
          let open = bar.state === "control_center"
          if (root.ccOp === "close") { if (open) bar.state = "normal"; return }
          let name = root.ccTab !== "" ? controlCenter.className(root.ccTab) : ""
          let switching = name !== "" && name !== controlCenter.tab
          if (name !== "") controlCenter.tab = name
          bar.state = (root.ccOp === "toggle" && open && !switching) ? "normal" : "control_center"
        }
        // Tab commands (shortcuts / IPC): on a closed dashboard they just open it
        // ("set" also picks the tab first).
        function onTabCounterChanged() {
          if (!(root.tabMonitor === "" ? barWindow.isFocused : barWindow.modelData.name === root.tabMonitor)) return
          let n = dashboardGrid.tabs.length
          let wasOpen = bar.state === "dashboard"
          if (root.tabOp === "set") {
            barWindow.setTab(dashboardConfig.tabIndex(dashboardGrid.preset, root.tabArg))
          } else if (wasOpen && n > 1) {
            let step = root.tabOp === "prev" ? -1 : 1
            barWindow.setTab((barWindow.dashTab + step + n) % n, step)
          }
          if (!wasOpen) bar.state = "dashboard"
        }
        function onFullCounterChanged() {
          if (root.fullTarget === "" ? !barWindow.isFocused : barWindow.modelData.name !== root.fullTarget) return
          if (bar.state !== "dashboard") { barWindow.dashboardFull = true; bar.state = "dashboard" }
          else barWindow.dashboardFull = !barWindow.dashboardFull
        }
      }

      // Low battery popup trigger (only on focused monitor)
      Connections {
        target: root
        function onLowBatteryTriggerChanged() {
          if (barWindow.isFocused) {
            lowBatteryPopup.show()
          }
        }
      }

      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      // app_selector / power_menu need immediate keyboard (typing / arrow-select), so
      // they grab exclusively. The wallpaper selector is mouse-navigable, so it uses
      // OnDemand — an Exclusive grab is global and blocks clicks on other monitors.
      // Its arrow keys arrive via root's shared HyprlandFocusGrab instead.
      WlrLayershell.keyboardFocus: (bar.state === "app_selector" || bar.state === "power_menu")
            ? WlrKeyboardFocus.Exclusive
            : (bar.state === "wallpaper_selector" || bar.state === "nova_chat")
            ? WlrKeyboardFocus.OnDemand
            : bar.state === "control_center"
            ? WlrKeyboardFocus.OnDemand
            : WlrKeyboardFocus.None

      readonly property bool selectorOpen: bar.state === "wallpaper_selector" || bar.state === "nova_chat"
      onSelectorOpenChanged: root.setSelectorOpen(barWindow, selectorOpen)
      Component.onDestruction: { root.setSelectorOpen(barWindow, false); root.noteControlCenter(modelData.name, false) }

      readonly property bool ccOpen: bar.state === "control_center"
      onCcOpenChanged: root.noteControlCenter(modelData.name, ccOpen)
      // The pocket's place along the bar is picked when a state opens and kept
      // while it closes, so it shrinks back where it was.
      Connections {
        target: bar
        function onStateChanged() { if (bar.state !== "normal") bar.pocketSide = bar.state === "control_center" ? 1 : 0 }
      }

      // Escape/Enter close every open selector, not just the local one.
      Connections {
        target: root
        function onSelectorCloseCounterChanged() {
          if (bar.state === "wallpaper_selector") {
            bar.state = "normal"
          }
        }
      }
      mask: Region {
        item: bar
      }

      anchors {
        top: true
        bottom: true
        left: true
        right: true
      }

      Item {
        id: main
        // Only as big as the bar and its pocket (plus the low-battery popup
        // while it shows), not the whole screen: the MultiEffect below renders
        // this item into an offscreen texture for its shadow, and that texture
        // and the blur cost scale with its area, so the bar strip no longer
        // pays for a 3440x1440 texture on every clock tick or visualizer
        // frame. Everything drawn lives inside the strip + pocket anyway (the
        // effect's auto padding keeps the shadow outside it); the extent is
        // rounded up to 64 px steps so the pocket animation doesn't reallocate
        // the texture every frame, and the spare rows are transparent. (2026-10-10)
        x: 0
        y: 0
        readonly property real contentExtent: Math.max(bar.barCross,
          lowBatteryPopup.visible ? lowBatteryPopup.y + lowBatteryPopup.height : 0)
        readonly property real layerExtent: Math.min(metrics.isVertical ? parent.width : parent.height,
          Math.ceil(contentExtent / 64) * 64)
        width: metrics.isVertical ? layerExtent : parent.width
        height: metrics.isVertical ? parent.height : layerExtent

        // Low battery popup warning
        Rectangle {
          id: lowBatteryPopup
          visible: false
          opacity: 0
          
          width: metrics.s(400)
          height: metrics.s(120)
          radius: metrics.radiusXL
          color: Theme.colors.background
          border.color: Theme.colors.red
          border.width: Theme.bw(2)

          anchors {
            horizontalCenter: parent.horizontalCenter
            top: parent.top
            topMargin: metrics.s(80)
          }
          
          layer.enabled: true
          layer.samples: 4
          
          ColumnLayout {
            anchors.centerIn: parent
            spacing: metrics.spacingNormal

            Text {
              text: ""
              color: Theme.colors.red
              font.pixelSize: metrics.fontHuge
              font.family: Theme.fonts.mono
              Layout.alignment: Qt.AlignHCenter
            }
            
            Text {
              font.family: Theme.fonts.ui
              text: "Low Battery Warning"
              color: Theme.colors.textPrimary
              font.pixelSize: metrics.fontLarge
              font.bold: true
              Layout.alignment: Qt.AlignHCenter
            }
            
            Text {
              font.family: Theme.fonts.ui
              text: "Battery at " + root.batteryPercent + "% — Please plug in charger"
              color: Theme.colors.textSecondary
              font.pixelSize: metrics.fontSmall
              Layout.alignment: Qt.AlignHCenter
            }
          }
          
          Behavior on opacity {
            NumberAnimation { duration: Motion.enter; easing.type: Motion.easeIn }
          }
          
          Timer {
            id: lowBatteryPopupTimer
            interval: 5000
            running: false
            repeat: false
            onTriggered: {
              lowBatteryPopup.opacity = 0
              lowBatteryPopupHideTimer.start()
            }
          }
          
          Timer {
            id: lowBatteryPopupHideTimer
            interval: Motion.enter
            running: false
            repeat: false
            onTriggered: {
              lowBatteryPopup.visible = false
            }
          }
          
          function show() {
            if (!root.hasBattery) {
              return
            }
            lowBatteryPopup.visible = true
            lowBatteryPopup.opacity = 1
            lowBatteryPopupTimer.restart()
          }
        }

        Shape {
          id: bar
          state: "normal"
          onStateChanged: if (state !== "dashboard") barWindow.dashboardFull = false

          // analytic curve AA instead of a 4x MSAA offscreen layer
          preferredRendererType: Shape.CurveRenderer

          property real barThickness: metrics.barThickness

          property int dividerThickness: 1

          // dropdownWidth = pocket length ALONG the bar's long axis.
          // dropdownHeight = pocket protrusion along the CROSS axis (thickness dir).
          property real dropdownWidth: metrics.longPct(30)
          property real dropdownHeight: 10 * parent.height / 100
          property real dropdownFilletRadius: metrics.radiusNormal
          property real dropdownCornerRadius: metrics.s(25)
          property int dropdownWidgetPadding: metrics.widgetPadding

          // Orientation-generalized geometry. The outline is authored once in
          // (a,b) = (along-long-axis, along-cross-axis) space; sx/sy map it to
          // screen coords for a horizontal (top) or vertical (left) bar. Reflecting
          // across the diagonal flips arc handedness, so arcDir swaps when vertical.
          readonly property real barLong: metrics.barLength
          readonly property real barCross: barThickness + dropdownHeight
          // 0 = centred (every other pocket), 1 = at the far end under the clock
          // (control center). Slides only when switching straight from another
          // open pocket; opening from closed starts in place.
          property real pocketSide: 0
          Behavior on pocketSide { enabled: bar.dropdownHeight > 1; NumberAnimation { duration: 100; easing.type: Easing.OutQuint } }
          readonly property real pocketEndInset: metrics.marginBar
          readonly property real pocketCenter: (1 - pocketSide) * barLong / 2
              + pocketSide * (barLong - pocketEndInset - dropdownFilletRadius - dropdownWidth / 2)
          readonly property real pocketLo: pocketCenter - dropdownWidth / 2
          readonly property real pocketHi: pocketLo + dropdownWidth
          function sx(a, b) { return metrics.isVertical ? b : a }
          function sy(a, b) { return metrics.isVertical ? a : b }
          function arcDir(d) {
            if (!metrics.isVertical) return d
            return d === PathArc.Clockwise ? PathArc.Counterclockwise : PathArc.Clockwise
          }

          width: metrics.isVertical ? barCross : parent.width
          height: metrics.isVertical ? parent.height : barCross

          property int appSelectorCellHeightConst: metrics.appCellHeight
          property int appSelectorOffsetFromBar: metrics.s(5)
          property int appSelectorRowsPerPage: 5

          ShapePath {
            fillColor: Theme.colors.panelDeep
            strokeColor: "transparent"

            startX: 0; startY: 0
            PathLine { x: bar.sx(bar.barLong, 0); y: bar.sy(bar.barLong, 0) }
            PathLine { x: bar.sx(bar.barLong, bar.barThickness); y: bar.sy(bar.barLong, bar.barThickness) }
            PathLine { x: bar.sx(bar.pocketHi + bar.dropdownFilletRadius, bar.barThickness); y: bar.sy(bar.pocketHi + bar.dropdownFilletRadius, bar.barThickness) }

            PathArc {
              x: bar.sx(bar.pocketHi, bar.barThickness + bar.dropdownFilletRadius)
              y: bar.sy(bar.pocketHi, bar.barThickness + bar.dropdownFilletRadius)
              radiusX: bar.dropdownFilletRadius
              radiusY: bar.dropdownFilletRadius
              direction: bar.arcDir(PathArc.Counterclockwise)
            }

            PathLine { x: bar.sx(bar.pocketHi, bar.barCross - bar.dropdownCornerRadius); y: bar.sy(bar.pocketHi, bar.barCross - bar.dropdownCornerRadius) }

            PathArc {
              x: bar.sx(bar.pocketHi - bar.dropdownCornerRadius, bar.barCross)
              y: bar.sy(bar.pocketHi - bar.dropdownCornerRadius, bar.barCross)
              radiusX: bar.dropdownCornerRadius
              radiusY: bar.dropdownCornerRadius
              direction: bar.arcDir(PathArc.Clockwise)
            }

            PathLine { x: bar.sx(bar.pocketLo + bar.dropdownCornerRadius, bar.barCross); y: bar.sy(bar.pocketLo + bar.dropdownCornerRadius, bar.barCross) }

            PathArc {
              x: bar.sx(bar.pocketLo, bar.barCross - bar.dropdownCornerRadius)
              y: bar.sy(bar.pocketLo, bar.barCross - bar.dropdownCornerRadius)
              radiusX: bar.dropdownCornerRadius
              radiusY: bar.dropdownCornerRadius
              direction: bar.arcDir(PathArc.Clockwise)
            }

            PathLine { x: bar.sx(bar.pocketLo, bar.barThickness + bar.dropdownFilletRadius); y: bar.sy(bar.pocketLo, bar.barThickness + bar.dropdownFilletRadius) }

            PathArc {
              x: bar.sx(bar.pocketLo - bar.dropdownFilletRadius, bar.barThickness)
              y: bar.sy(bar.pocketLo - bar.dropdownFilletRadius, bar.barThickness)
              radiusX: bar.dropdownFilletRadius
              radiusY: bar.dropdownFilletRadius
              direction: bar.arcDir(PathArc.Counterclockwise)
            }

            PathLine { x: bar.sx(0, bar.barThickness); y: bar.sy(0, bar.barThickness) }
            PathLine { x: 0; y: 0 }
          }

          // dropdownWidth = pocket length along the long axis; dropdownHeight = pocket
          // protrusion along the cross axis. longPct/crossPct reduce to today's
          // parent.width/parent.height percentages when horizontal (byte-identical),
          // and adapt to the tall-narrow pocket when vertical. Content-driven pockets
          // (dashboard/app_selector) use fixed generous extents when vertical to avoid
          // the axis-swap circular sizing.
          states: [
            State {
              name: "normal"
              PropertyChanges { target: bar; dropdownWidth: metrics.longPct(10); dropdownHeight: 0; dropdownFilletRadius: 0; dropdownCornerRadius: 0 }
            },
            State {
              name: "dashboard"
              PropertyChanges {
                target: bar;
                dropdownWidth: barWindow.dashboardFull ? metrics.longPct(100)
                    : metrics.isVertical ? (dashboardGrid.verticalContentHeight + dashboardGrid.topPad + dashboardGrid.bottomPad + bar.dropdownWidgetPadding * 2) : metrics.longPct(dashboardGrid.widthPercent);
                dropdownHeight: barWindow.dashboardFull ? (metrics.crossPct(100) - bar.barThickness)
                    : metrics.isVertical ? metrics.crossPct(72) : (dashboardGrid.implicitHeight + (bar.dropdownWidgetPadding * 2) - bar.barThickness);
                dropdownFilletRadius: barWindow.dashboardFull ? 0 : metrics.radiusXL;
                dropdownCornerRadius: barWindow.dashboardFull ? 0 : metrics.radiusXL
              }
            },
            State {
              name: "wallpaper_selector"
              PropertyChanges {
                target: bar;
                dropdownWidth: metrics.isVertical ? metrics.longPct(70) : metrics.longPct(50);
                dropdownHeight: metrics.isVertical ? metrics.crossPct(36) : metrics.crossPct(10);
                dropdownFilletRadius: metrics.radiusXL;
                dropdownCornerRadius: metrics.radiusXL
              }
            },
            State {
              name: "app_selector"
              PropertyChanges {
                target: bar;
                dropdownWidth: metrics.isVertical ? metrics.longPct(80) : metrics.longPct(30);
                dropdownHeight: metrics.isVertical ? metrics.crossPct(80) : (appSelectorWidget.totalHeight + (bar.dropdownWidgetPadding * 2) - bar.barThickness);
                dropdownFilletRadius: metrics.radiusXL;
                dropdownCornerRadius: metrics.radiusXL;
              }
            },
            State {
              name: "nova_chat"
              PropertyChanges {
                target: bar;
                dropdownWidth: metrics.isVertical ? metrics.longPct(85) : metrics.longPct(34);
                dropdownHeight: metrics.isVertical ? metrics.crossPct(55) : metrics.crossPct(62);
                dropdownFilletRadius: metrics.radiusXL;
                dropdownCornerRadius: metrics.radiusXL;
              }
            },
            State {
              name: "control_center"
              PropertyChanges {
                target: bar;
                dropdownWidth: (metrics.isVertical ? controlCenterWidget.panelHeight : controlCenterWidget.panelWidth) + bar.dropdownWidgetPadding * 2;
                dropdownHeight: controlCenterWidget.topPad + (metrics.isVertical ? controlCenterWidget.panelWidth : controlCenterWidget.panelHeight) + bar.dropdownWidgetPadding;
                dropdownFilletRadius: metrics.radiusXL;
                dropdownCornerRadius: metrics.radiusXL
              }
            },
            State {
              name: "power_menu"
              PropertyChanges {
                target: bar;
                dropdownWidth: metrics.isVertical ? metrics.longPct(45) : metrics.longPct(35);
                dropdownHeight: metrics.isVertical ? metrics.crossPct(65) : metrics.crossPct(12);
                dropdownFilletRadius: metrics.radiusXL;
                dropdownCornerRadius: metrics.radiusXL;
              }
            }
          ]

          transitions: [
            Transition {
              NumberAnimation { target: bar; properties: "dropdownWidth,dropdownHeight,dropdownCornerRadius,dropdownFilletRadius"; duration: Motion.pocket; easing.type: Easing.OutQuint }
            },
          ]
        }

        // Container for all the bar-exclusive widgets. Horizontal: full-width strip
        // of barThickness. Vertical: full-height strip of barThickness down the left.
        Item {
          id: barWidgetsContainer
          width: metrics.isVertical ? bar.barThickness : parent.width
          height: metrics.isVertical ? parent.height : bar.barThickness

          // Workspaces at the START of the long axis (left / top), per-monitor
          Workspaces {
            monitorId: barWindow.monitorId
            isVertical: metrics.isVertical
            anchors {
              left: metrics.isVertical ? undefined : parent.left
              top: metrics.isVertical ? parent.top : undefined
              verticalCenter: metrics.isVertical ? undefined : parent.verticalCenter
              horizontalCenter: metrics.isVertical ? parent.horizontalCenter : undefined
              leftMargin: metrics.isVertical ? 0 : metrics.marginBar
              topMargin: metrics.isVertical ? metrics.marginBar : 0
            }
          }

          // Music/Weather widget centered on the long axis
          MusicWidget {
            isVertical: metrics.isVertical
            anchors {
              horizontalCenter: parent.horizontalCenter
              verticalCenter: parent.verticalCenter
            }
          }

          // Voice assistant indicator takes over the same slot while a voice turn is in flight
          VoiceBarWidget {
            isVertical: metrics.isVertical
            anchors {
              horizontalCenter: parent.horizontalCenter
              verticalCenter: parent.verticalCenter
            }
          }

          // Screen capture buttons (per-monitor), just before the clock
          ScreenCaptureWidget {
            id: screenCapture
            monitorName: barWindow.hyprMonitor?.name ?? ""
            isVertical: metrics.isVertical
            anchors {
              right: metrics.isVertical ? undefined : ccBell.left
              bottom: metrics.isVertical ? ccBell.top : undefined
              verticalCenter: metrics.isVertical ? undefined : parent.verticalCenter
              horizontalCenter: metrics.isVertical ? parent.horizontalCenter : undefined
              rightMargin: metrics.isVertical ? 0 : metrics.marginBar
              bottomMargin: metrics.isVertical ? metrics.marginBar : 0
            }
          }

          // Clock at the far END of the long axis (right / bottom). Vertical bars
          // are too thin for hh:mm:ss, so stack hh over mm there.
          // Control center bell (do-not-disturb glyph when DND is on) with a
          // small badge counting waiting notifications; grey under DND, gone at 0.
          // Click (bell or clock) toggles the panel here; right click toggles DND.
          Item {
            id: ccBell
            width: bellGrid.width
            height: bellGrid.height
            anchors {
              right: metrics.isVertical ? undefined : timeDisplay.left
              bottom: metrics.isVertical ? timeDisplay.top : undefined
              verticalCenter: metrics.isVertical ? undefined : parent.verticalCenter
              horizontalCenter: metrics.isVertical ? parent.horizontalCenter : undefined
              rightMargin: metrics.isVertical ? 0 : metrics.marginBar
              bottomMargin: metrics.isVertical ? metrics.marginBar : 0
            }
            readonly property int waiting: controlCenter.waiting

            Grid {
              id: bellGrid
              columns: metrics.isVertical ? 1 : 2
              spacing: metrics.spacingTiny
              horizontalItemAlignment: Grid.AlignHCenter
              verticalItemAlignment: Grid.AlignVCenter
              Text {
                text: controlCenter.dnd ? "󰂛" : ccBell.waiting > 0 ? "󰂞" : "󰂚"
                color: bar.state === "control_center" ? Theme.colors.textPrimary : Theme.colors.textMuted
                font.pixelSize: metrics.fontNormal
                font.family: Theme.fonts.mono
                font.bold: true
              }
              Rectangle {
                visible: ccBell.waiting > 0
                width: Math.max(height, bellBadge.implicitWidth + metrics.spacingSmall * 1.5)
                height: bellBadge.implicitHeight + metrics.s(2)
                radius: height / 2
                color: controlCenter.dnd ? Theme.colors.inset : Theme.colors.accent
                Text {
                  id: bellBadge
                  anchors.centerIn: parent
                  text: ccBell.waiting > 99 ? "99+" : ccBell.waiting
                  color: controlCenter.dnd ? Theme.colors.textSecondary : Theme.colors.panelDeep
                  font.pixelSize: metrics.fontTiny * 0.9
                  font.family: Theme.fonts.mono
                  font.bold: true
                }
              }
            }
            MouseArea {
              anchors.fill: parent
              anchors.margins: -metrics.spacingSmall
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              cursorShape: Qt.PointingHandCursor
              onClicked: mouse => {
                if (mouse.button === Qt.RightButton) { controlCenter.setDnd(!controlCenter.dnd); return }
                let showing = bar.state === "control_center" && controlCenter.tab === "notifications"
                controlCenter.tab = "notifications"
                bar.state = showing ? "normal" : "control_center"
              }
            }
          }

          Text {
            id: timeDisplay
            horizontalAlignment: Text.AlignHCenter
            anchors {
              right: metrics.isVertical ? undefined : parent.right
              bottom: metrics.isVertical ? parent.bottom : undefined
              verticalCenter: metrics.isVertical ? undefined : parent.verticalCenter
              horizontalCenter: metrics.isVertical ? parent.horizontalCenter : undefined
              rightMargin: metrics.isVertical ? 0 : metrics.marginEdge
              bottomMargin: metrics.isVertical ? metrics.marginEdge : 0
            }

            color: Theme.colors.textPrimary
            font.pixelSize: metrics.isVertical ? metrics.fontSmall : metrics.fontNormal
            font.family: Theme.fonts.display
            font.bold: true
            // Lining, equal-width digits: display fonts like Playfair and Cormorant
            // default to old-style figures, and proportional ones jiggle the bar each second.
            font.features: { "lnum": 1, "tnum": 1 }

            function updateTime() {
              text = Qt.formatDateTime(new Date(), metrics.isVertical ? "hh\nmm" : "hh:mm:ss")
            }

            Component.onCompleted: updateTime()

            MouseArea {
              anchors.fill: parent
              anchors.margins: -metrics.spacingSmall
              cursorShape: Qt.PointingHandCursor
              onClicked: bar.state = bar.state === "control_center" ? "normal" : "control_center"
            }
          }

          Timer {
            interval: 500
            running: true
            repeat: true
            onTriggered: timeDisplay.updateTime()
          }

          // System widgets (brightness, volume, cpu, temp, battery). A row across the
          // top bar; a single stacked column above the clock on a vertical bar. Uses a
          // Grid POSITIONER (not GridLayout) to avoid nested-layout polish loops.
          Grid {
            id: statsCluster
            columns: metrics.isVertical ? 1 : 99
            rowSpacing: metrics.spacingSmall
            columnSpacing: metrics.spacingSmall
            horizontalItemAlignment: Grid.AlignHCenter
            verticalItemAlignment: Grid.AlignVCenter
            anchors {
              right: metrics.isVertical ? undefined : screenCapture.left
              bottom: metrics.isVertical ? screenCapture.top : undefined
              verticalCenter: metrics.isVertical ? undefined : parent.verticalCenter
              horizontalCenter: metrics.isVertical ? parent.horizontalCenter : undefined
              rightMargin: metrics.isVertical ? 0 : metrics.marginBar
              bottomMargin: metrics.isVertical ? metrics.marginBar : 0
            }

            // Brightness widget (only if backlight exists)
            BarSliderWidget {
              visible: root.hasBrightness
              isVertical: metrics.isVertical
              icon: "󰃠"
              value: root.brightnessValue
              displayValue: Math.round(root.brightnessValue * 100) + "%"
              accentColor: Theme.colors.yellow

              onMoved: (newVal) => {
                let raw = Math.round(newVal * root.brightnessMax);
                brightnessSetProc.command = ["brightnessctl", "set", raw.toString()];
                brightnessSetProc.running = true;
              }
            }

            Rectangle {
              visible: root.hasBrightness
              implicitWidth: metrics.isVertical ? bar.barThickness * 0.6 : bar.dividerThickness
              implicitHeight: metrics.isVertical ? bar.dividerThickness : bar.barThickness * 0.6
              Layout.alignment: Qt.AlignCenter
              color: Theme.colors.textMuted
            }

            // Volume widget (hover to expand slider, click to mute)
            BarSliderWidget {
              isVertical: metrics.isVertical
              icon: root.volumeIcon
              value: (Pipewire.defaultAudioSink?.audio.volume ?? 0)
              displayValue: root.volumePercent + "%"
              accentColor: Theme.colors.violet

              onMoved: (newVal) => {
                if (Pipewire.defaultAudioSink?.audio) {
                  Pipewire.defaultAudioSink.audio.volume = newVal;
                }
              }

              onClicked: {
                if (Pipewire.defaultAudioSink?.audio) {
                  Pipewire.defaultAudioSink.audio.muted = !Pipewire.defaultAudioSink.audio.muted;
                }
              }
            }

            Rectangle {
              implicitWidth: metrics.isVertical ? bar.barThickness * 0.6 : bar.dividerThickness
              implicitHeight: metrics.isVertical ? bar.dividerThickness : bar.barThickness * 0.6
              Layout.alignment: Qt.AlignCenter
              color: Theme.colors.textMuted
            }

            Grid {
              columns: metrics.isVertical ? 1 : 99
              rowSpacing: metrics.spacingTiny
              columnSpacing: metrics.spacingTiny
              horizontalItemAlignment: Grid.AlignHCenter
              verticalItemAlignment: Grid.AlignVCenter
              Text {
                text: "󰘚"
                color: Theme.colors.blue
                font.pixelSize: metrics.fontNormal
                font.family: Theme.fonts.mono
                font.bold: true
              }
              Text {
                font.family: Theme.fonts.ui
                font.features: { "tnum": 1, "lnum": 1 }
                text: parseFloat(root.cpuLoad).toFixed(0) + "%"
                color: Theme.colors.blue
                font.pixelSize: metrics.fontNormal
                font.bold: true
              }
            }

            Rectangle {
              implicitWidth: metrics.isVertical ? bar.barThickness * 0.6 : bar.dividerThickness
              implicitHeight: metrics.isVertical ? bar.dividerThickness : bar.barThickness * 0.6
              Layout.alignment: Qt.AlignCenter
              color: Theme.colors.textMuted
            }

            Grid {
              columns: metrics.isVertical ? 1 : 99
              rowSpacing: metrics.spacingTiny
              columnSpacing: metrics.spacingTiny
              horizontalItemAlignment: Grid.AlignHCenter
              verticalItemAlignment: Grid.AlignVCenter
              Text {
                text: "󰔏"
                color: {
                  let temp = parseFloat(root.tempValue);
                  if (temp > 80) return Theme.colors.red;
                  if (temp > 60) return Theme.colors.orange;
                  return Theme.colors.teal;
                }
                font.pixelSize: metrics.fontNormal
                font.family: Theme.fonts.mono
                font.bold: true
              }
              Text {
                font.family: Theme.fonts.ui
                font.features: { "tnum": 1, "lnum": 1 }
                text: parseFloat(root.tempValue).toFixed(0) + "°C"
                color: {
                  let temp = parseFloat(root.tempValue);
                  if (temp > 80) return Theme.colors.red;
                  if (temp > 60) return Theme.colors.orange;
                  return Theme.colors.teal;
                }
                font.pixelSize: metrics.fontNormal
                font.bold: true
              }
            }

            Rectangle {
              visible: root.hasBattery
              implicitWidth: metrics.isVertical ? bar.barThickness * 0.6 : bar.dividerThickness
              implicitHeight: metrics.isVertical ? bar.dividerThickness : bar.barThickness * 0.6
              Layout.alignment: Qt.AlignCenter
              color: Theme.colors.textMuted
            }

            Grid {
              visible: root.hasBattery
              columns: metrics.isVertical ? 1 : 99
              rowSpacing: metrics.spacingTiny
              columnSpacing: metrics.spacingTiny
              horizontalItemAlignment: Grid.AlignHCenter
              verticalItemAlignment: Grid.AlignVCenter
              Text {
                text: root.batteryIcon
                color: {
                  let level = parseInt(root.batteryPercent);
                  if (level > 60) return Theme.colors.green;
                  if (level > 30) return Theme.colors.yellow;
                  return Theme.colors.red;
                }
                font.pixelSize: metrics.fontNormal
                font.family: Theme.fonts.mono
                font.bold: true
              }
              Text {
                font.family: Theme.fonts.ui
                font.features: { "tnum": 1, "lnum": 1 }
                text: root.batteryPercent + "%"
                color: {
                  let level = parseInt(root.batteryPercent);
                  if (level > 60) return Theme.colors.green;
                  if (level > 30) return Theme.colors.yellow;
                  return Theme.colors.red;
                }
                font.pixelSize: metrics.fontNormal
                font.bold: true
              }
            }
          }
        }

        // Container for the 'dynamic island' dropdown widgets. Grows along the long
        // axis (dropdownWidth) and protrudes along the cross axis (dropdownHeight).
        Item {
          id: dynamicWidgetsContainer
          width: metrics.isVertical ? (bar.barThickness + bar.dropdownHeight) : bar.dropdownWidth
          height: metrics.isVertical ? bar.dropdownWidth : (bar.barThickness + bar.dropdownHeight)

          anchors {
            top: metrics.isVertical ? undefined : parent.top
            left: metrics.isVertical ? parent.left : undefined
            horizontalCenter: metrics.isVertical ? undefined : parent.horizontalCenter
            verticalCenter: metrics.isVertical ? parent.verticalCenter : undefined
            horizontalCenterOffset: metrics.isVertical ? 0 : bar.pocketCenter - bar.barLong / 2
            verticalCenterOffset: metrics.isVertical ? bar.pocketCenter - bar.barLong / 2 : 0
          }

          WallpaperSelectorWidget {}

          AppSelectorWidget {
              id: appSelectorWidget
          }

          PowerMenuWidget {}

          ControlCenterWidget {
            id: controlCenterWidget
            service: controlCenter
          }

          NovaChatWidget {}
          
          // Dashboard, built from the active preset (DashboardConfig.qml /
          // presets.json). A preset with "tabs" gets the slim tab strip on top
          // and one DashGrid page per tab (only the current one shows); a plain
          // preset is a single page without the strip. Horizontal: `columns`
          // equal-width columns, content-driven height. Vertical: fills the tall
          // pocket using the preset's portrait block, or an automatic re-pack.
          Item {
            id: dashboardGrid
            visible: bar.state === "dashboard"

            anchors {
              top: metrics.isVertical ? undefined : parent.top
              left: metrics.isVertical ? parent.left : undefined
              topMargin: metrics.isVertical ? 0 : bar.barThickness
              leftMargin: metrics.isVertical ? bar.barThickness : 0
              horizontalCenter: metrics.isVertical ? undefined : parent.horizontalCenter
              verticalCenter: metrics.isVertical ? parent.verticalCenter : undefined
            }

            width: metrics.isVertical
              ? (parent.width - bar.barThickness - bar.dropdownWidgetPadding * 2)
              : (parent.width - (bar.dropdownWidgetPadding * 2))
            height: metrics.isVertical ? (parent.height - bar.dropdownWidgetPadding * 2) : (full ? fullGridHeight : implicitHeight)

            // Fullscreen: the grid gets the whole monitor (minus the bar and the
            // pocket padding) and each page solves its row pitch from that, so a
            // preset's rows fill it; columns already follow the pocket width.
            // Computed from the screen size only — the pocket is sized from the
            // grid in the normal state, so the other direction would loop.
            readonly property bool full: barWindow.dashboardFull
            readonly property real fullGridHeight: metrics.isVertical
              ? metrics.longPct(100) - bar.dropdownWidgetPadding * 2
              : metrics.crossPct(100) - bar.barThickness - bar.dropdownWidgetPadding

            // Pages for this screen's orientation. Re-evaluates when the preset
            // changes (hot reload / IPC) or the monitor rotates.
            readonly property var preset: dashboardConfig.activePreset
            readonly property var tabs: dashboardConfig.tabsOf(preset)
            readonly property bool tabbed: tabs.length > 1
            readonly property int tab: Math.max(0, Math.min(barWindow.dashTab, tabs.length - 1))
            readonly property var layouts: tabs.map((t, i) => dashboardConfig.layoutFor(preset, metrics.isVertical, i))
            readonly property var layout: layouts[tab] ?? ({ columns: 1, rows: 0, widgets: [] })
            // The tallest page sets the pocket; shorter ones stretch their rows to it.
            readonly property real rows: layouts.reduce((m, l) => Math.max(m, l.rows), 0)
            // Pocket length along the bar when horizontal (% of the long axis).
            readonly property real widthPercent: preset?.widthPercent ?? 60

            property real rowSpacing: metrics.spacingNormal
            property real topPad: metrics.s(5)
            property real bottomPad: metrics.spacingNormal
            readonly property real stripH: tabbed ? Math.round(metrics.s(30) * (full ? 1.15 : 1)) : 0
            readonly property real stripGap: tabbed ? metrics.spacingNormal : 0
            function rowH(span) { return span * metrics.dashWidgetHeight + (span - 1) * rowSpacing }

            // Pointer activity anywhere over the dashboard keeps it awake (passive).
            HoverHandler {
              id: dashActivity
              enabled: Dash.standbyEnabled
              onPointChanged: dashState.poke()
              onHoveredChanged: dashState.poke()
            }

            // Natural height of the portrait stack (content-driven pocket).
            property real verticalContentHeight: stripH + stripGap + rowH(rows)

            // Only used to size the horizontal pocket (content-driven).
            implicitHeight: topPad + verticalContentHeight + bottomPad

            DashTabStrip {
              id: tabStrip
              visible: dashboardGrid.tabbed
              y: dashboardGrid.topPad
              width: parent.width
              height: dashboardGrid.stripH
              z: 3
              tabs: dashboardGrid.tabs
              current: dashboardGrid.tab
              fontPx: Math.round(metrics.fontSmall * (dashboardGrid.full ? 1.15 : 1))
              onPicked: index => barWindow.setTab(index)
            }

            Item {
              id: tabBody
              anchors.fill: parent
              anchors.topMargin: dashboardGrid.topPad + dashboardGrid.stripH + dashboardGrid.stripGap
              anchors.bottomMargin: dashboardGrid.bottomPad
              // keeps the sliding pages inside the pocket during a switch
              clip: dashboardGrid.tabbed

              Repeater {
                model: dashboardGrid.tabs.length
                DashGrid {
                  required property int index
                  anchors.fill: parent
                  layout: dashboardGrid.layouts[index]
                  current: index === dashboardGrid.tab
                  dir: barWindow.tabDir
                  rowSpacing: dashboardGrid.rowSpacing
                }
              }
            }

            // Standby veil: a panel-coloured wash over the cards that lowers the
            // contrast after Dash.standbyMs idle; it settles slowly and wakes on
            // the next pointer movement. Never takes input.
            Rectangle {
              visible: Dash.standbyEnabled && opacity > 0.001
              anchors.fill: parent
              anchors.topMargin: dashboardGrid.topPad - metrics.s(2)
              z: 2
              color: Theme.colors.panelDeep
              opacity: dashState.standby ? Dash.standbyVeil : 0
              Behavior on opacity { NumberAnimation { duration: dashState.standby ? Dash.standbyFade : Motion.enter; easing.type: dashState.standby ? Motion.easeAmbient : Motion.easeIn } }
            }
          }
        }
      }

      MultiEffect {
        source: main
        anchors.fill: main
        shadowEnabled: true
      }

      // Exclusion zone (per-screen): reserve the top edge (horizontal) or the
      // left edge (vertical) so windows don't overlap the bar.
      Scope {
        PanelWindow {
          screen: barWindow.modelData
          anchors.top: !metrics.isVertical
          anchors.left: metrics.isVertical
          implicitWidth: metrics.isVertical ? bar.barThickness : 0
          implicitHeight: metrics.isVertical ? 0 : bar.barThickness
        }
      }
    }
  }
}

