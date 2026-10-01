// One monitor's lock screen: the background (live Bevy scene / still / colour)
// with the clock, date, greeting and password field over it. Placement and text
// style come from screenData (lockgen.py's resolved lock.toml); the palette is
// Catppuccin Mocha by default. Nothing full-screen is blurred or shadowed: the
// live scene is drawn once, the password field is faux glass (translucent fill,
// thin border, top sheen; no blur, so no bleed), and text shadows are stacked
// copies of the glyphs. Every text element takes its own font, weight, size,
// tracking, casing, colour, opacity and shadow, so each wallpaper can differ.
//
// Alignment is by ink, not by Qt's text box: each label's box is its glyphs'
// tight horizontal extent (no side bearings, no trailing letter spacing) by the
// font's cap height (baseline to the top of an "H", descenders ignored), so a
// 150pt clock and a tracked 13pt date line up on the same edge and a stack keeps
// the same rhythm whatever the sizes. Elements can hang off each other
// (`below`/`above` + `gap`) or off the wallpaper's subject (`relative_to =
// "subject"`).
//
// Depth (stills with [depth] masks): planes, bottom to top:
//   background + shade | depth="far" text | midground (not the bg mask)
//   | depth="behind" text | foreground (the subject) | front text + field
// lockgen.py bakes brightness and the shade into the mid/foreground cut-outs so
// they match the background exactly.
import QtQuick
import QtQuick.Effects
import Quickshell

FocusScope {
  id: surface
  required property var shell
  property var screenData: ({ background: { kind: "color", color: "#ff1e1e2e" }, elements: {} })
  property bool preview: false      // qs/preview.qml: no fade-in, render at once

  readonly property var bg: screenData.background ?? ({ kind: "color", color: "#ff1e1e2e" })
  readonly property var els: screenData.elements ?? ({})
  readonly property var depth: screenData.depth ?? ({})
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

  // Layouts are designed on 1440px-tall screens; sizes, gaps and px offsets
  // scale with the screen (logical px) so a laptop keeps the same composition.
  readonly property real s: screenData.ui_scale > 0 ? screenData.ui_scale
                            : Math.max(0.6, Math.min(1.5, Math.min(height / 1440, width / 2560)))

  // ---- helpers
  readonly property var weights: ({ thin: 100, extralight: 200, light: 300, regular: 400, normal: 400, medium: 500,
                                    semibold: 600, bold: 700, extrabold: 800, black: 900 })
  function weight(w) {
    if (w === undefined) return 400
    let n = Number(w)
    return isNaN(n) ? (weights[String(w).toLowerCase()] ?? 400) : Math.max(1, Math.min(1000, n))
  }
  // font_size: points (96 dpi, scaled) or "N%" of the screen height
  function fontPx(v) {
    if (typeof v === "string" && v.trim().endsWith("%")) return Math.max(1, Math.round(parseFloat(v) / 100 * height))
    return Math.round((Number(v ?? 20)) * 96 / 72 * s)
  }
  // a length: px (scaled) or "N%" of `whole`
  function len(v, whole) {
    if (typeof v === "string" && v.trim().endsWith("%")) return parseFloat(v) / 100 * whole
    return Number(v ?? 0) * s
  }
  // [[value, isPercent], [value, isPercent]] (lockgen's parse_pos) -> px
  function off(p, axis) {
    let whole = axis === "x" ? width : height
    let v = p ? p[axis === "x" ? 0 : 1] : [0, false]
    return v[1] ? v[0] / 100 * whole : v[0] * s
  }
  readonly property var subjectRect: {
    let r = surface.depth.subject
    return r ? Qt.rect(r[0] * width, r[1] * height, r[2] * width, r[3] * height) : Qt.rect(0, 0, width, height)
  }
  readonly property var items: ({ clock: clockLabel, date: dateLabel, greeting: greetingLabel, input: field })

  // Top-left of an element's box (bw x bh), hyprlock-style anchor + offset
  // (+y up). Attached elements (`below`/`above` another) sit `gap` under/over it,
  // aligned to its edge by their own halign.
  function boxPos(cfg, bw, bh, axis) {
    let refName = cfg.below || cfg.above || ""
    let ref = refName ? items[refName] : null
    let a = axis === "x" ? (cfg.halign ?? "center") : (cfg.valign ?? "center")
    if (ref && ref.boxW !== undefined) {
      let o = cfg.offset
      if (axis === "x") {
        let x = a === "left" ? ref.boxX : a === "right" ? ref.boxX + ref.boxW - bw : ref.boxX + (ref.boxW - bw) / 2
        return Math.round(x + off(o, "x"))
      }
      let gap = len(cfg.gap ?? 20, height)
      let y = cfg.below ? ref.boxY + ref.boxH + gap : ref.boxY - gap - bh
      return Math.round(y - off(o, "y"))
    }
    let f = cfg.relative_to === "subject" ? subjectRect : Qt.rect(0, 0, width, height)
    let p = cfg.position ?? [[0, false], [0, false]]
    if (axis === "x")
      return Math.round((a === "left" ? f.x : a === "right" ? f.x + f.width - bw : f.x + (f.width - bw) / 2) + off(p, "x"))
    return Math.round((a === "top" ? f.y : a === "bottom" ? f.y + f.height - bh : f.y + (f.height - bh) / 2) - off(p, "y"))
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
  // Startup timing (shell.t0 = when it was asked to show, epoch ms): logs this
  // screen's first frame and the live scene's first frame.
  readonly property real t0: surface.shell.t0 || 0
  function since() { return surface.t0 > 0 ? (Date.now() - surface.t0) + " ms" : "?" }
  Connections {
    id: firstFrame
    target: surface.t0 > 0 && !surface.preview ? surface.Window.window : null
    function onFrameSwapped() { console.warn("lock: first frame " + (surface.screenData.name ?? "?") + " at " + surface.since()); firstFrame.target = null }
  }
  readonly property string period: clock.date.getHours() < 12 ? "morning" : clock.date.getHours() < 18 ? "afternoon" : "evening"

  // ---- background (the only thing that moves every frame)
  Item {
    id: stage
    anchors.fill: parent

    Rectangle { anchors.fill: parent; color: bg.color ?? "#ff1e1e2e" }

    // Live: a frame of the scene (lockgen's `poster`) from the first frame on;
    // the scene fades in over it once it draws (Live.qml).
    Image {
      anchors.fill: parent
      visible: source != ""
      source: surface.bg.kind === "live" && surface.bg.poster ? "file://" + surface.bg.poster : ""
      fillMode: Image.PreserveAspectCrop
    }

    Loader {
      id: live
      anchors.fill: parent
      active: surface.bg.kind === "live"
      source: "Live.qml"
      onLoaded: {
        item.library = Qt.binding(() => surface.bg.library ?? "")
        item.options = Qt.binding(() => JSON.stringify(surface.bg.options ?? {}))
      }
    }
    Connections {
      target: live.item
      function onFrameReadyChanged() {
        if (surface.t0 > 0) console.warn("lock: live scene up " + (surface.screenData.name ?? "?") + " at " + surface.since())
        if (surface.bg.poster_out) posterGrab.start()
      }
    }
    // No poster yet (or the app changed): save one once the scene has run a little.
    Timer {
      id: posterGrab
      interval: 3000
      onTriggered: {
        const out = surface.bg.poster_out
        if (out && live.item && !surface.shell.unlocking)
          live.item.grabToImage(r => { if (!r.saveToFile(out)) console.warn("lock: could not save the poster " + out) })
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
        // Images load synchronously (screen-sized, cached by lockgen): the first
        // frame already has them, no black frame, no cut-out arriving late.
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
  // gradients, no per-frame cost beyond one blend. With depth cut-outs it stays
  // put (lockgen bakes the same shade into them, which cannot fade).
  readonly property bool baked: !!(depth.foreground || depth.midground)
  Rectangle {
    anchors { left: parent.left; right: parent.right; top: parent.top }
    height: parent.height * 0.4
    opacity: 0.9 * (surface.baked ? 1 : fade.opacity)
    gradient: Gradient {
      GradientStop { position: 0; color: "#5911111b" }
      GradientStop { position: 1; color: "#0011111b" }
    }
  }
  Rectangle {
    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
    height: parent.height * 0.45
    opacity: 0.9 * (surface.baked ? 1 : fade.opacity)
    gradient: Gradient {
      GradientStop { position: 0; color: "#0011111b" }
      GradientStop { position: 1; color: "#6611111b" }
    }
  }

  // ---- everything over the scene fades in on start and out on unlock
  Item {
    id: fade
    opacity: appear * (1 - leave)
    property real appear: surface.preview ? 1 : 0
    property real leave: 0
    NumberAnimation on appear { running: !surface.preview; from: 0; to: 1; duration: 250; easing.type: Easing.OutCubic }
    NumberAnimation on leave {
      running: surface.shell.unlocking
      from: 0; to: 1; duration: 330; easing.type: Easing.InCubic
    }
    // a little lift as it appears
    property real lift: (1 - appear) * 8
  }
  component Plane: Item {
    anchors.fill: parent
    opacity: fade.opacity
    transform: Translate { y: fade.lift }
  }
  // A cut-out of the (dimmed, shaded) background: the image where its mask is white.
  component Cutout: Image {
    anchors.fill: parent
    fillMode: Image.PreserveAspectCrop
    visible: source != ""
  }

  Plane { id: farPlane }
  Cutout { source: surface.depth.midground ? "file://" + surface.depth.midground : "" }
  Plane { id: behindPlane }
  Cutout { source: surface.depth.foreground ? "file://" + surface.depth.foreground : "" }
  Plane { id: ui }

  function planeFor(d) {
    if (d === "far" && surface.depth.midground) return farPlane
    if ((d === "behind" || d === "far") && surface.depth.foreground) return behindPlane
    if (d === "far" || d === "behind") return surface.depth.midground ? farPlane : ui
    return ui
  }

  // ---- text
  // The label text; stacked translucent copies make a soft shadow.
  component Glyphs: Text {
    required property var lbl
    text: lbl.shown
    color: lbl.cfg.color ?? lbl.fallback
    font: lbl.font
    renderType: Text.NativeRendering
  }
  component Label: Item {
    id: lbl
    required property string element
    required property string text
    property color fallback: surface.cText
    readonly property var cfg: surface.els[element] ?? ({})
    readonly property string shown: (cfg.uppercase ?? false) ? text.toUpperCase() : text
    readonly property real strength: cfg.shadow_strength ?? 1
    readonly property bool shadowOn: (cfg.shadow_passes ?? 0) > 0 && strength > 0
    readonly property font font: Qt.font({
      family: cfg.font_family ?? "Inter Display",
      weight: surface.weight(cfg.font_weight),
      italic: cfg.font_style === "italic",
      pixelSize: surface.fontPx(cfg.font_size),
      letterSpacing: (cfg.letter_spacing ?? 0) * surface.s,
      hintingPreference: Font.PreferNoHinting
    })
    FontMetrics { id: fm; font: lbl.font }
    // ink box: tight horizontal extent x cap height, in surface coordinates
    // (reading fm.height makes these re-run when the font changes; a method
    // call alone has no change signal)
    readonly property rect ink: fm.height > 0 ? fm.tightBoundingRect(shown) : Qt.rect(0, 0, 0, 0)
    readonly property real capH: fm.height > 0 ? Math.max(1, -fm.tightBoundingRect("H").y) : 1
    readonly property real boxW: ink.width
    readonly property real boxH: capH
    readonly property real boxX: surface.boxPos(cfg, boxW, boxH, "x")
    readonly property real boxY: surface.boxPos(cfg, boxW, boxH, "y")

    parent: surface.planeFor(cfg.depth)
    visible: cfg.show !== false && text !== ""
    opacity: cfg.opacity ?? 1
    width: t.implicitWidth
    height: t.implicitHeight
    x: boxX - ink.x
    y: boxY + capH - t.baselineOffset
    readonly property real sh: (cfg.shadow_size ?? 4) * surface.s
    Glyphs { lbl: lbl; y: lbl.sh * 1.6; color: lbl.cfg.shadow_color ?? "#cc11111b"; opacity: Math.min(1, 0.22 * lbl.strength); visible: lbl.shadowOn }
    Glyphs { lbl: lbl; y: lbl.sh * 0.6; color: lbl.cfg.shadow_color ?? "#cc11111b"; opacity: Math.min(1, 0.35 * lbl.strength); visible: lbl.shadowOn }
    Glyphs { id: t; lbl: lbl }
    // LOCK_PREVIEW_BOXES=1: outline the box each label is aligned by
    Rectangle {
      visible: surface.preview && (Quickshell.env("LOCK_PREVIEW_BOXES") || "") !== ""
      x: lbl.ink.x; y: t.baselineOffset - lbl.capH; width: lbl.boxW; height: lbl.boxH
      color: "transparent"; border.color: "#f38ba8"; border.width: 1
    }
  }

  Label { id: clockLabel; element: "clock"; text: Qt.formatTime(clock.date, surface.els.clock?.format ?? "HH:mm") }
  Label {
    id: dateLabel
    element: "date"
    fallback: surface.cSubtext
    text: Qt.formatDate(clock.date, surface.els.date?.format ?? "dddd, MMMM d")
  }
  Label {
    id: greetingLabel
    element: "greeting"
    fallback: surface.cSubtext
    text: (surface.els.greeting?.text ?? "good {period}, {user}").replace("{period}", surface.period).replace("{user}", surface.shell.user)
  }

  Item {
    parent: ui
    anchors.fill: parent
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
      width: Math.round(sz[0] * surface.s); height: Math.round(sz[1] * surface.s)
      readonly property real boxW: width
      readonly property real boxH: height
      readonly property real boxX: surface.boxPos(cfg, width, height, "x")
      readonly property real boxY: surface.boxPos(cfg, width, height, "y")
      x: boxX
      y: boxY

      readonly property color fontColor: cfg.font_color ?? surface.cText
      readonly property color accent: cfg.accent_color ?? surface.cLavender
      readonly property color ring: ok ? okColor
                                  : failed ? failColor
                                  : checking ? checkColor
                                  : !empty ? accent
                                  : (cfg.outer_color ?? "#40cdd6f4")
      readonly property color failColor: cfg.fail_color ?? surface.cRed
      readonly property color okColor: cfg.success_color ?? surface.cGreen
      readonly property color checkColor: cfg.check_color ?? surface.cYellow
      function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
      readonly property real radius: Math.min(cfg.rounding !== undefined ? cfg.rounding * surface.s : height / 2, height / 2)
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
      onFailedChanged: if (failed) { shakeAnim.restart(); failWash.restart() }

      // Faux glass: translucent fill, thin state-coloured border, a soft sheen
      // over the top half. Nothing here samples the scene, so nothing bleeds.
      Rectangle {
        id: box
        anchors.fill: parent
        radius: field.radius
        color: field.cfg.inner_color ?? "#5511111b"
        border.width: Math.max(1, (field.cfg.outline_thickness ?? 1.5) * surface.s)
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

      // wrong password: a red wash over the fill that fades with the shake
      Rectangle {
        anchors.fill: parent
        radius: field.radius
        color: field.failColor
        opacity: 0
        visible: opacity > 0
        SequentialAnimation on opacity {
          id: failWash
          running: false
          NumberAnimation { to: 0.22; duration: 70 }
          NumberAnimation { to: 0; duration: 650; easing.type: Easing.OutCubic }
        }
      }

      Item {
        id: inner
        anchors.fill: parent
        anchors.leftMargin: field.height * 0.6
        anchors.rightMargin: field.height * 0.6

        // The typed text as a fixed track of short dashes, like a redacted word:
        // it only says "something is typed", never how much. Each keystroke
        // lights the next dash (a tall lit tick that sinks back, with a faint
        // trail); the first one starts at a random dash, so the lit position
        // says nothing either. Backspace dims the tick and steps it back.
        // Empty -> typed: the track opens out from the centre; cleared (escape,
        // a wrong password, unlock): it closes back in, in the state's colour.
        // Checking: a soft wave of the check colour runs along it.
        readonly property int count: Math.max(3, Math.min(24, field.cfg.marks ?? 9))
        readonly property real pitch: width * Math.max(0.2, Math.min(1, field.cfg.marks_width ?? 0.86)) / count
        readonly property real markW: Math.max(2, Math.round(pitch * 0.46))
        readonly property real markH: Math.max(2, Math.round(field.height * (field.cfg.marks_thickness ?? 0.05)))
        property int head: 0
        property int prevLen: 0
        property real spread: field.empty ? 0 : 1
        Behavior on spread {
          NumberAnimation { duration: field.empty ? (field.checking || field.failed ? 420 : 260) : 300; easing.type: field.empty ? Easing.InCubic : Easing.OutCubic }
        }
        function mark(i) { return marks.itemAt(((i % count) + count) % count) }
        Connections {
          target: shell
          function onBufferChanged() {
            const n = shell.buffer.length
            if (n > inner.prevLen) {
              inner.head = inner.prevLen === 0 ? Math.floor(Math.random() * inner.count) : (inner.head + 1) % inner.count
              inner.mark(inner.head - 1)?.hit(0.35)
              inner.mark(inner.head)?.hit(1)
            } else if (n < inner.prevLen && n > 0) {
              inner.mark(inner.head)?.hit(-1)
              inner.head = (inner.head - 1 + inner.count) % inner.count
            }
            inner.prevLen = n
          }
        }

        // checking: a wave position along the track, 0..1, looping
        property real sweep: 0
        NumberAnimation on sweep {
          running: field.checking
          loops: Animation.Infinite
          from: 0; to: 1; duration: 1100; easing.type: Easing.InOutSine
        }

        Item {
          id: track
          anchors.fill: parent
          visible: !(field.cfg.hide_input === true) && inner.spread > 0.001
          Repeater {
            id: marks
            model: inner.count
            Rectangle {
              id: m
              required property int index
              // keystroke pulse: 1 = just typed, -1 = just deleted, eases to 0
              property real heat: 0
              NumberAnimation { id: cool; target: m; property: "heat"; to: 0; duration: 700; easing.type: Easing.OutQuad }
              function hit(v) { cool.stop(); m.heat = v; cool.start() }
              readonly property real glow: field.checking ? Math.max(0, 1 - Math.abs(inner.sweep * (inner.count + 3) - 1.5 - index) / 1.6) : 0
              readonly property real lit: Math.min(1, Math.max(0, heat) + glow * 0.6)
              readonly property real rel: (index - (inner.count - 1) / 2) / ((inner.count - 1) / 2)    // -1..1
              readonly property real off: rel * (inner.count - 1) / 2 * inner.pitch * inner.spread
              readonly property real taper: 1 - 0.55 * rel * rel                             // fainter towards the ends
              readonly property color tint: field.ok ? field.okColor
                                          : field.failed ? field.failColor
                                          : field.checking ? Qt.tint(field.fontColor, field.alpha(field.checkColor, 0.35 + 0.65 * glow))
                                          : Qt.tint(field.fontColor, field.alpha(field.accent, Math.max(0, heat)))

              width: inner.markW
              height: inner.markH
              radius: height / 2
              x: Math.round(inner.width / 2 + off - width / 2)
              y: Math.round((inner.height - height) / 2)
              color: field.alpha(tint, 1 - 0.9 * lit)       // the dash gives way to the caret
              opacity: inner.spread * Math.max(0.12, Math.min(1, 0.7 * taper + 0.6 * heat + 0.5 * glow))
              // lit: a thin caret stands up through the dash and sinks back
              Rectangle {
                anchors.centerIn: parent
                width: Math.max(2, inner.markH)
                height: Math.round(field.height * 0.46 * (0.45 + 0.55 * m.lit))
                radius: width / 2
                color: m.tint
                opacity: m.lit * m.lit
                visible: opacity > 0.01
              }
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

        // unlock: a check mark where the track closed
        Text {
          id: okMark
          anchors.centerIn: parent
          opacity: field.ok ? 1 : 0
          visible: opacity > 0
          scale: 0.7 + 0.3 * opacity
          Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
          text: visible ? String.fromCodePoint(0xF012C) : ""      // nf-md-check
          color: field.okColor
          font.family: "JetBrainsMono Nerd Font"
          font.pixelSize: Math.round(field.height * 0.42)
          renderType: Text.NativeRendering
        }
      }

      // caps lock: a key glyph at the right end of the field (plus the hint)
      Text {
        anchors { right: parent.right; rightMargin: field.height * 0.3; verticalCenter: parent.verticalCenter }
        opacity: shell.capsLock && !field.ok ? 0.9 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 180 } }
        text: visible ? String.fromCodePoint(0xF0632) : ""      // nf-md-apple_keyboard_caps
        color: field.cfg.caps_color ?? surface.cPeach
        font.family: "JetBrainsMono Nerd Font"
        font.pixelSize: Math.round(field.height * 0.34)
        renderType: Text.NativeRendering
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
