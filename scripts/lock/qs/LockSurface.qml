// One monitor's lock screen: the background (live Bevy scene / still / colour)
// with the clock, date, greeting and password field over it. Placement and text
// style come from screenData (lockgen.py's resolved meta/*.toml); the palette is
// Catppuccin Mocha by default. Nothing full-screen is blurred or shadowed: the
// live scene is drawn once, the password field is faux glass (translucent fill,
// thin border, top sheen; no blur, so no bleed), and text shadows are stacked
// copies of the glyphs. Every text element takes its own font, weight, size,
// tracking, casing, colour, opacity and shadow, so each wallpaper can differ.
import QtQuick
import QtQuick.Effects
import Quickshell

FocusScope {
  id: surface
  required property var shell
  property var screenData: ({ background: { kind: "color", color: "#ff1e1e2e" }, elements: {} })

  readonly property var bg: screenData.background ?? ({ kind: "color", color: "#ff1e1e2e" })
  readonly property var els: screenData.elements ?? ({})
  focus: true
  Keys.onPressed: e => shell.handleKey(e)

  // Catppuccin Mocha
  readonly property color cText: "#cdd6f4"
  readonly property color cSubtext: "#a6adc8"
  readonly property color cLavender: "#b4befe"
  readonly property color cRed: "#f38ba8"
  readonly property color cYellow: "#f9e2af"
  readonly property color cGreen: "#a6e3a1"
  readonly property color cPeach: "#fab387"
  readonly property color cCrust: "#11111b"

  // ---- helpers
  readonly property var weights: ({ thin: 100, extralight: 200, light: 300, regular: 400, normal: 400, medium: 500,
                                    semibold: 600, bold: 700, extrabold: 800, black: 900 })
  function weight(w) {
    if (w === undefined) return 400
    let n = Number(w)
    return isNaN(n) ? (weights[String(w).toLowerCase()] ?? 400) : Math.max(1, Math.min(1000, n))
  }
  // hyprlock-style anchor + offset (+y up), % of this monitor
  function place(cfg, w, h, axis) {
    let pos = cfg.position ?? [[0, false], [0, false]]
    let p = pos[axis === "x" ? 0 : 1]
    let off = Math.round(p[1] ? p[0] / 100 * (axis === "x" ? surface.width : surface.height) : p[0])
    if (axis === "x") {
      let a = cfg.halign ?? "center"
      return Math.round(a === "left" ? 0 : a === "right" ? surface.width - w : (surface.width - w) / 2) + off
    }
    let a = cfg.valign ?? "center"
    return Math.round(a === "top" ? 0 : a === "bottom" ? surface.height - h : (surface.height - h) / 2) - off
  }

  SystemClock { id: clock; precision: SystemClock.Seconds }

  // Debug (LOCK_FPS=1): frames this surface's window really presents, logged every 2 s.
  property int frames: 0
  Connections {
    target: (Quickshell.env("LOCK_FPS") || "") !== "" ? surface.Window.window : null
    function onFrameSwapped() { surface.frames++ }
  }
  Timer {
    running: (Quickshell.env("LOCK_FPS") || "") !== ""
    interval: 2000; repeat: true
    onTriggered: { console.warn("lock fps " + (surface.screenData.name ?? "?") + ": " + (surface.frames / 2).toFixed(1)); surface.frames = 0 }
  }
  readonly property string period: clock.date.getHours() < 12 ? "morning" : clock.date.getHours() < 18 ? "afternoon" : "evening"

  // ---- background (the only thing that moves every frame)
  Item {
    id: stage
    anchors.fill: parent

    Rectangle { anchors.fill: parent; color: bg.color ?? "#ff1e1e2e" }

    Loader {
      anchors.fill: parent
      active: surface.bg.kind === "live"
      source: "Live.qml"
      onLoaded: {
        item.library = Qt.binding(() => surface.bg.library ?? "")
        item.options = Qt.binding(() => JSON.stringify(surface.bg.options ?? {}))
      }
    }

    Item {
      anchors.fill: parent
      visible: surface.bg.kind === "still"
      Image {
        id: still
        anchors.fill: parent
        source: surface.bg.kind === "still" ? "file://" + surface.bg.image : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        visible: !(surface.bg.blur > 0)
      }
      MultiEffect {
        anchors.fill: parent
        source: still
        visible: surface.bg.blur > 0
        blurEnabled: true
        blurMax: 64
        blur: Math.min(1, (surface.bg.blur ?? 0) / 64)
      }
    }

    // brightness < 1 dims whatever is behind
    Rectangle {
      anchors.fill: parent
      color: "black"
      opacity: 1 - Math.max(0, Math.min(1, surface.bg.brightness ?? 1))
      visible: opacity > 0
    }
  }

  // Soft top/bottom falloff so light scenes keep the text readable. Two flat
  // gradients, no per-frame cost beyond one blend.
  Rectangle {
    anchors { left: parent.left; right: parent.right; top: parent.top }
    height: parent.height * 0.4
    opacity: 0.9 * ui.opacity
    gradient: Gradient {
      GradientStop { position: 0; color: "#5911111b" }
      GradientStop { position: 1; color: "#0011111b" }
    }
  }
  Rectangle {
    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
    height: parent.height * 0.45
    opacity: 0.9 * ui.opacity
    gradient: Gradient {
      GradientStop { position: 0; color: "#0011111b" }
      GradientStop { position: 1; color: "#6611111b" }
    }
  }

  // ---- everything over the scene fades in on start and out on unlock
  Item {
    id: ui
    anchors.fill: parent
    opacity: appear * (1 - leave)
    property real appear: 0
    property real leave: 0
    NumberAnimation on appear { from: 0; to: 1; duration: 900; easing.type: Easing.OutCubic }
    NumberAnimation on leave {
      running: surface.shell.unlocking
      from: 0; to: 1; duration: 330; easing.type: Easing.InCubic
    }
    // a little lift as it appears
    transform: Translate { y: (1 - ui.appear) * 14 }

    // ---- text
    // The label text; stacked translucent copies make a soft shadow.
    component Glyphs: Text {
      required property var lbl
      text: lbl.text
      color: lbl.cfg.color ?? lbl.fallback
      font.family: lbl.cfg.font_family ?? "Inter Display"
      font.weight: surface.weight(lbl.cfg.font_weight)
      font.italic: lbl.cfg.font_style === "italic"
      font.pixelSize: Math.round((lbl.cfg.font_size ?? 20) * 96 / 72)
      font.letterSpacing: lbl.spacing
      font.capitalization: lbl.upper ? Font.AllUppercase : Font.MixedCase
      renderType: Text.NativeRendering
    }
    component Label: Item {
      id: lbl
      required property string element
      required property string text
      property color fallback: surface.cText
      readonly property var cfg: surface.els[element] ?? ({})
      readonly property bool upper: cfg.uppercase ?? false
      readonly property real spacing: cfg.letter_spacing ?? 0
      readonly property real strength: cfg.shadow_strength ?? 1
      readonly property bool shadowOn: (cfg.shadow_passes ?? 0) > 0
      visible: cfg.show !== false && text !== ""
      opacity: cfg.opacity ?? 1
      width: t.implicitWidth
      height: t.implicitHeight
      x: surface.place(cfg, width, height, "x")
      y: surface.place(cfg, width, height, "y")
      Glyphs { lbl: lbl; y: (lbl.cfg.shadow_size ?? 4) * 1.6; color: lbl.cfg.shadow_color ?? "#cc11111b"; opacity: Math.min(1, 0.22 * lbl.strength); visible: lbl.shadowOn }
      Glyphs { lbl: lbl; y: (lbl.cfg.shadow_size ?? 4) * 0.6; color: lbl.cfg.shadow_color ?? "#cc11111b"; opacity: Math.min(1, 0.35 * lbl.strength); visible: lbl.shadowOn }
      Glyphs { id: t; lbl: lbl }
    }

    Label { element: "clock"; text: Qt.formatTime(clock.date, surface.els.clock?.format ?? "HH:mm") }
    Label {
      element: "date"
      fallback: surface.cSubtext
      text: Qt.formatDate(clock.date, surface.els.date?.format ?? "dddd, MMMM d")
    }
    Label {
      element: "greeting"
      fallback: surface.cSubtext
      text: (surface.els.greeting?.text ?? "good {period}, {user}").replace("{period}", surface.period).replace("{user}", surface.shell.user)
    }

    // ---- password field
    Item {
      id: field
      readonly property var cfg: surface.els.input ?? ({})
      readonly property var sz: cfg.size ?? [340, 58]
      readonly property bool failed: shell.status === "failed"
      readonly property bool checking: shell.status === "checking"
      readonly property bool ok: shell.unlocking
      readonly property bool empty: shell.buffer === ""
      visible: cfg.show !== false && !(cfg.fade_on_empty === true && empty && !failed && !checking && !ok)
      width: sz[0]; height: sz[1]
      x: surface.place(cfg, width, height, "x")
      y: surface.place(cfg, width, height, "y")

      readonly property color fontColor: cfg.font_color ?? surface.cText
      readonly property color accent: cfg.accent_color ?? surface.cLavender
      readonly property color ring: ok ? (cfg.success_color ?? surface.cGreen)
                                  : failed ? (cfg.fail_color ?? surface.cRed)
                                  : checking ? (cfg.check_color ?? surface.cYellow)
                                  : !empty ? accent
                                  : (cfg.outer_color ?? "#40cdd6f4")
      readonly property real dot: Math.round(height * (cfg.dots_size ?? 0.22))
      readonly property real gap: dot * (cfg.dots_spacing ?? 0.9)
      readonly property real radius: Math.min(cfg.rounding ?? height / 2, height / 2)
      readonly property bool glass: cfg.glass !== false

      // wrong password: shake
      property real shake: 0
      transform: Translate { x: field.shake }
      SequentialAnimation {
        id: shakeAnim
        NumberAnimation { target: field; property: "shake"; to: -16; duration: 55 }
        NumberAnimation { target: field; property: "shake"; to: 14; duration: 75 }
        NumberAnimation { target: field; property: "shake"; to: -10; duration: 75 }
        NumberAnimation { target: field; property: "shake"; to: 6; duration: 70 }
        NumberAnimation { target: field; property: "shake"; to: -3; duration: 60 }
        NumberAnimation { target: field; property: "shake"; to: 0; duration: 55 }
      }
      onFailedChanged: if (failed) shakeAnim.restart()

      // Faux glass: translucent fill, thin state-coloured border, a soft sheen
      // over the top half. Nothing here samples the scene, so nothing bleeds.
      Rectangle {
        id: box
        anchors.fill: parent
        radius: field.radius
        color: field.cfg.inner_color ?? "#5511111b"
        border.width: field.cfg.outline_thickness ?? 1.5
        border.color: field.ring
        Behavior on border.color { ColorAnimation { duration: 180 } }
      }
      Rectangle {
        anchors.fill: parent
        anchors.margins: 1
        radius: Math.max(0, field.radius - 1)
        visible: field.glass
        gradient: Gradient {
          GradientStop { position: 0; color: field.cfg.highlight_color ?? "#24ffffff" }
          GradientStop { position: 0.55; color: "#00ffffff" }
        }
      }

      Item {
        id: inner
        anchors.fill: parent
        anchors.leftMargin: field.height * 0.6
        anchors.rightMargin: field.height * 0.6
        clip: true

        // Dots. `shown` eases toward the real length, and every dot sits at
        // x0 + i * pitch, so adding or deleting slides the rest smoothly (centred
        // while it fits, newest at the right edge once it does not). Each dot
        // fades and scales in/out by itself; nothing is created or destroyed
        // while visible.
        property real shown: shell.buffer.length
        Behavior on shown { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        readonly property real pitch: field.dot + field.gap
        readonly property real total: Math.max(0, shown * pitch - field.gap)
        readonly property real x0: total <= width ? (width - total) / 2 : width - total
        property int peak: 0
        Connections {
          target: shell
          function onBufferChanged() {
            if (shell.buffer.length > inner.peak) inner.peak = shell.buffer.length
            trim.restart()
          }
        }
        Timer { id: trim; interval: 500; onTriggered: inner.peak = shell.buffer.length }

        Item {
          id: dots
          anchors.fill: parent
          visible: !(field.cfg.hide_input === true)
          opacity: field.ok ? 0 : 1
          Behavior on opacity { NumberAnimation { duration: 200 } }
          // the "checking" pulse lives on its own layer so it never fights the fades
          property real pulse: 1
          SequentialAnimation {
            running: field.checking
            loops: Animation.Infinite
            onRunningChanged: if (!running) dots.pulse = 1
            NumberAnimation { target: dots; property: "pulse"; to: 0.4; duration: 450; easing.type: Easing.InOutSine }
            NumberAnimation { target: dots; property: "pulse"; to: 1; duration: 450; easing.type: Easing.InOutSine }
          }
          Repeater {
            model: inner.peak
            Rectangle {
              id: d
              required property int index
              property bool armed: false
              readonly property bool present: armed && index < shell.buffer.length
              Component.onCompleted: armed = true
              x: inner.x0 + index * inner.pitch
              y: (inner.height - height) / 2
              width: field.dot; height: field.dot; radius: width / 2
              color: field.failed ? (field.cfg.fail_color ?? surface.cRed) : field.fontColor
              opacity: present ? dots.pulse : 0
              scale: present ? 1 : 0.4
              visible: opacity > 0.01
              Behavior on opacity { enabled: !field.checking; NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
              Behavior on scale { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }
              Behavior on color { ColorAnimation { duration: 180 } }
            }
          }
        }
        Text {
          anchors.centerIn: parent
          visible: opacity > 0
          opacity: field.empty && !field.checking && !field.failed && !field.ok && text !== "" ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: field.empty ? 240 : 70 } }
          text: field.cfg.placeholder_text ?? "Password"
          color: Qt.rgba(field.fontColor.r, field.fontColor.g, field.fontColor.b, 0.55)
          font.family: field.cfg.font_family ?? "Inter Display"
          font.weight: surface.weight(field.cfg.font_weight)
          font.pixelSize: Math.round(field.height * 0.3)
          font.letterSpacing: 0.5
          renderType: Text.NativeRendering
        }
      }

      // status line under the field: wrong password / caps lock
      Text {
        id: hint
        anchors { top: parent.bottom; topMargin: field.height * 0.3; horizontalCenter: parent.horizontalCenter }
        readonly property bool caps: shell.capsLock && !field.ok
        text: field.failed ? (field.cfg.fail_text ?? "wrong password") : caps ? "caps lock is on" : ""
        color: field.failed ? (field.cfg.fail_color ?? surface.cRed) : (field.cfg.caps_color ?? surface.cPeach)
        opacity: text !== "" ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 200 } }
        font.family: field.cfg.font_family ?? "Inter Display"
        font.weight: 500
        font.pixelSize: Math.round(field.height * 0.26)
        font.letterSpacing: 0.6
        renderType: Text.NativeRendering
      }
    }
  }
}
