// Turntable for the music tab (MusicStageWidget): the album art is the label
// of a spinning record, a tonearm swings onto it on play and creeps inward with
// the track's progress, a thin progress ring runs around the platter and a soft
// glow in the art's accent colour breathes with the bass.
//
// Motion stays cheap: the spin is a RotationAnimator (render thread) that eases
// up on play and coasts to a stop on pause, and every animation stops while the
// card is off screen (`active`) or nothing plays. Grooves are painted once.

import QtQuick
import QtQuick.Shapes
import Quickshell.Widgets
import "themes"

Item {
  id: tt

  property string art: ""
  property bool playing: false
  property bool hasTrack: false
  property bool active: false          // card on screen
  property real progress: 0            // 0..1
  property real level: 0               // bass level 0..1 (glow)
  property color accent: Theme.colors.pink
  // Bumped on every track change: the record dips and settles
  property string trackKey: ""

  readonly property real m: Math.round(height * 0.05)          // room for ring + glow
  readonly property real d: height - 2 * m                     // record diameter
  readonly property real r: d / 2
  readonly property real cx: m + r
  readonly property real cy: m + r
  implicitWidth: height * 1.2

  // ---- glow behind the platter (static gradient; only opacity/scale follow the bass)
  Shape {
    id: glow
    readonly property real gr: tt.r * 1.38
    x: tt.cx - gr; y: tt.cy - gr
    width: gr * 2; height: gr * 2
    preferredRendererType: Shape.CurveRenderer
    opacity: tt.hasTrack ? (tt.playing ? 0.55 + tt.level * 0.45 : 0.35) : 0
    scale: 1 + tt.level * 0.05
    Behavior on opacity { NumberAnimation { duration: Motion.slow; easing.type: Motion.easeAmbient } }
    ShapePath {
      strokeColor: "transparent"
      fillGradient: RadialGradient {
        centerX: glow.gr; centerY: glow.gr; centerRadius: glow.gr
        focalX: glow.gr; focalY: glow.gr
        GradientStop { position: 0.5; color: Qt.rgba(tt.accent.r, tt.accent.g, tt.accent.b, 0.42) }
        GradientStop { position: 0.76; color: Qt.rgba(tt.accent.r, tt.accent.g, tt.accent.b, 0.13) }
        GradientStop { position: 1.0; color: "transparent" }
      }
      PathAngleArc { centerX: glow.gr; centerY: glow.gr; radiusX: glow.gr; radiusY: glow.gr; startAngle: 0; sweepAngle: 360 }
    }
  }

  // ---- progress ring around the platter
  Shape {
    id: ring
    readonly property real rr: tt.r + tt.m * 0.55
    x: tt.cx - rr; y: tt.cy - rr
    width: rr * 2; height: rr * 2
    preferredRendererType: Shape.CurveRenderer
    readonly property real w: Math.max(2, tt.m * 0.22)
    ShapePath {
      fillColor: "transparent"
      strokeColor: Qt.rgba(Theme.colors.border.r, Theme.colors.border.g, Theme.colors.border.b, 0.7)
      strokeWidth: ring.w * 0.5
      PathAngleArc { centerX: ring.rr; centerY: ring.rr; radiusX: ring.rr; radiusY: ring.rr; startAngle: 0; sweepAngle: 360 }
    }
    ShapePath {
      fillColor: "transparent"
      strokeColor: tt.accent
      strokeWidth: ring.w
      capStyle: ShapePath.RoundCap
      PathAngleArc {
        centerX: ring.rr; centerY: ring.rr; radiusX: ring.rr; radiusY: ring.rr
        startAngle: -90
        sweepAngle: tt.hasTrack ? Math.max(0.5, 360 * Math.min(1, tt.progress)) : 0
      }
    }
  }

  // ---- platter
  Rectangle {
    x: tt.cx - width / 2; y: tt.cy - height / 2
    width: tt.d + 2; height: width
    radius: width / 2
    color: Theme.colors.panelDeep
    border.width: Theme.bw(1)
    border.color: Theme.cardFrame
  }

  // ---- the record (everything in here spins)
  Item {
    id: record
    x: tt.m; y: tt.m
    width: tt.d; height: tt.d
    transformOrigin: Item.Center

    // vinyl
    Rectangle {
      anchors.fill: parent
      radius: width / 2
      color: Qt.darker(Theme.colors.panelDeep, 1.5)
    }
    // grooves, painted once per size: fine rings plus a few brighter gaps between "tracks"
    Canvas {
      id: grooves
      anchors.fill: parent
      onWidthChanged: requestPaint()
      onPaint: {
        let c = getContext("2d"), R = width / 2
        c.reset()
        let lo = R * 0.33, hi = R * 0.975
        for (let rad = lo; rad < hi; rad += Math.max(1.5, R / 70)) {
          c.beginPath()
          c.arc(R, R, rad, 0, Math.PI * 2)
          c.lineWidth = 1
          c.strokeStyle = Math.round(rad) % 3 === 0 ? "rgba(255,255,255,0.055)" : "rgba(0,0,0,0.35)"
          c.stroke()
        }
        for (let f of [0.52, 0.68, 0.82]) {
          c.beginPath()
          c.arc(R, R, R * f, 0, Math.PI * 2)
          c.lineWidth = Math.max(1.5, R * 0.012)
          c.strokeStyle = "rgba(255,255,255,0.08)"
          c.stroke()
        }
        // run-out edge
        c.beginPath()
        c.arc(R, R, R * 0.985, 0, Math.PI * 2)
        c.lineWidth = Math.max(1, R * 0.02)
        c.strokeStyle = "rgba(255,255,255,0.06)"
        c.stroke()
      }
    }

    // label: the album art, crossfading to the next cover
    ClippingRectangle {
      id: label
      anchors.centerIn: parent
      width: Math.round(tt.d * 0.58); height: width
      radius: width / 2
      color: Theme.colors.inset
      Image {
        id: under
        anchors.fill: parent
        sourceSize.width: 600; sourceSize.height: 600
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
      }
      Image {
        id: top
        anchors.fill: parent
        sourceSize.width: 600; sourceSize.height: 600
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        opacity: 0
        onStatusChanged: if (status === Image.Ready) { fadeIn.restart() }
        NumberAnimation {
          id: fadeIn
          target: top; property: "opacity"; to: 1
          duration: 520; easing.type: Easing.InOutQuad
          onFinished: under.source = ""
        }
      }
      Text {
        visible: top.status !== Image.Ready && under.status !== Image.Ready
        anchors.centerIn: parent
        text: "󰝚"
        color: Theme.colors.textMuted
        font.pixelSize: Math.round(label.width * 0.32)
        font.family: Theme.fonts.icon
      }
      // inner edge of the label
      Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: "transparent"
        border.width: Math.max(1, tt.d * 0.008)
        border.color: Qt.rgba(0, 0, 0, 0.35)
      }
    }
    // spindle
    Rectangle {
      anchors.centerIn: parent
      width: Math.max(5, tt.d * 0.035); height: width
      radius: width / 2
      color: Theme.colors.panelDeep
      border.width: 1
      border.color: Qt.rgba(1, 1, 1, 0.25)
    }
  }

  // ---- static light reflection over the record (does not spin, which sells the spin)
  Shape {
    x: tt.m; y: tt.m
    width: tt.d; height: tt.d
    preferredRendererType: Shape.CurveRenderer
    ShapePath {
      strokeColor: "transparent"
      fillGradient: ConicalGradient {
        centerX: tt.r; centerY: tt.r; angle: 45
        GradientStop { position: 0.00; color: "transparent" }
        GradientStop { position: 0.06; color: Qt.rgba(1, 1, 1, 0.10) }
        GradientStop { position: 0.14; color: "transparent" }
        GradientStop { position: 0.50; color: "transparent" }
        GradientStop { position: 0.56; color: Qt.rgba(1, 1, 1, 0.07) }
        GradientStop { position: 0.64; color: "transparent" }
        GradientStop { position: 1.00; color: "transparent" }
      }
      PathAngleArc { centerX: tt.r; centerY: tt.r; radiusX: tt.r; radiusY: tt.r; startAngle: 0; sweepAngle: 360 }
    }
  }

  // ---- tonearm. Pivot up and to the right of the record; at rotation 0 the arm
  // hangs straight down beside it, at 16° the stylus sits in the lead-in groove
  // and it travels to 30° (the label edge) over the track.
  readonly property real px: tt.m + tt.r * 2.18
  readonly property real py: tt.m + tt.r * 0.2
  readonly property real armLen: tt.r * 1.25

  // 0 = resting, 1 = on the record; only this animates on play/pause
  property real swing: playing && hasTrack ? 1 : 0
  Behavior on swing {
    NumberAnimation { duration: 900; easing.type: Easing.InOutCubic }
  }

  // pivot base (does not move)
  Rectangle {
    x: tt.px - width / 2; y: tt.py - height / 2
    width: tt.r * 0.32; height: width
    radius: width / 2
    color: Theme.colors.inset
    border.width: Theme.bw(1)
    border.color: Theme.colors.border
    Rectangle {
      anchors.centerIn: parent
      width: parent.width * 0.55; height: width
      radius: width / 2
      color: Theme.colors.panelDeep
      border.width: 1
      border.color: Qt.rgba(1, 1, 1, 0.12)
    }
  }
  // arm rest post
  Rectangle {
    x: tt.px - width / 2; y: tt.py + tt.armLen * 0.8
    width: tt.r * 0.09; height: tt.r * 0.12
    radius: width / 3
    color: Theme.colors.inset
    border.width: 1
    border.color: Theme.colors.border
  }

  Item {
    id: arm
    x: tt.px; y: tt.py
    rotation: tt.swing * (16 + 14 * Math.min(1, tt.progress))
    // lifted a touch while it swings over
    scale: 1 + 0.035 * Math.sin(Math.PI * tt.swing)
    transformOrigin: Item.TopLeft
    readonly property real t: Math.max(2, tt.r * 0.045)
    readonly property color metal: Theme.colors.textSecondary

    // shadow, offset further while the arm is lifted
    Rectangle {
      x: -arm.t / 2 + tt.r * (0.03 + 0.04 * Math.sin(Math.PI * tt.swing)); y: tt.r * 0.05
      width: arm.t; height: tt.armLen * 0.86
      radius: width / 2
      color: "black"
      opacity: 0.35
    }
    // counterweight
    Rectangle {
      x: -width / 2; y: -tt.r * 0.34
      width: tt.r * 0.16; height: tt.r * 0.2
      radius: Math.max(2, width * 0.2)
      color: Theme.colors.inset
      border.width: 1
      border.color: Theme.colors.border
    }
    // tube
    Rectangle {
      x: -arm.t / 2; y: -tt.r * 0.16
      width: arm.t; height: tt.armLen * 0.86 + tt.r * 0.16
      radius: width / 2
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0.0; color: Qt.darker(arm.metal, 1.4) }
        GradientStop { position: 0.45; color: arm.metal }
        GradientStop { position: 1.0; color: Qt.darker(arm.metal, 1.8) }
      }
    }
    // headshell, angled in toward the groove, with a small accent LED
    Item {
      x: 0; y: tt.armLen * 0.86
      rotation: 22
      transformOrigin: Item.TopLeft
      Rectangle {
        x: -width / 2; y: -tt.r * 0.02
        width: tt.r * 0.11; height: tt.r * 0.2
        radius: Math.max(2, width * 0.18)
        color: Theme.colors.inset
        border.width: 1
        border.color: arm.metal
        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          anchors.bottomMargin: parent.height * 0.12
          width: Math.max(3, parent.width * 0.3); height: width
          radius: width / 2
          color: tt.accent
          opacity: 0.25 + 0.75 * tt.swing
        }
      }
    }
  }
  // pivot cap on top of the arm
  Rectangle {
    x: tt.px - width / 2; y: tt.py - height / 2
    width: tt.r * 0.12; height: width
    radius: width / 2
    color: arm.metal
    border.width: 1
    border.color: Qt.darker(arm.metal, 1.6)
  }

  // ---- spin: 33⅓ rpm (1.8 s a turn). Spin-up and coast-down are quadratic
  // ramps whose end/start speed equals the steady speed, so there is no jerk.
  readonly property int turn: 1800
  readonly property bool playState: playing && hasTrack
  RotationAnimator {
    id: spinUp
    target: record
    duration: 900
    easing.type: Easing.InQuad
    onFinished: if (tt.active && tt.playState) tt.loop()
  }
  RotationAnimator {
    id: steady
    target: record
    duration: tt.turn
    loops: Animation.Infinite
  }
  RotationAnimator {
    id: coast
    target: record
    duration: 1400
    easing.type: Easing.OutQuad
  }
  function halt() { spinUp.stop(); steady.stop(); coast.stop(); record.rotation = record.rotation % 360 }
  function loop() {
    halt()
    steady.from = record.rotation; steady.to = record.rotation + 360
    steady.start()
  }
  // play/pause animate; appearing/disappearing (tab, dashboard) just starts or stops
  onPlayStateChanged: {
    if (!active) return
    halt()
    if (playState) {
      // InQuad over 900 ms ends at the steady speed after 90°
      spinUp.from = record.rotation; spinUp.to = record.rotation + 360 * spinUp.duration / (2 * turn)
      spinUp.start()
    } else {
      // OutQuad over 1400 ms starts at the steady speed and covers 140°
      coast.from = record.rotation; coast.to = record.rotation + 360 * coast.duration / (2 * turn)
      coast.start()
    }
  }
  onActiveChanged: if (active && playState) loop(); else halt()
  Component.onCompleted: { top.source = art; if (active && playState) loop() }

  // ---- track change: crossfade the label and let the record dip and settle
  onArtChanged: {
    if (art === top.source.toString()) return
    fadeIn.stop()
    if (top.status === Image.Ready && top.opacity > 0) { under.source = top.source }
    top.opacity = 0
    top.source = art
  }
  onTrackKeyChanged: if (active && trackKey !== "") swap.restart()
  SequentialAnimation {
    id: swap
    NumberAnimation { target: record; property: "scale"; to: 0.94; duration: 160; easing.type: Easing.OutCubic }
    NumberAnimation { target: record; property: "scale"; to: 1; duration: 520; easing.type: Easing.OutBack }
  }
}
