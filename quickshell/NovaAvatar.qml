import QtQuick
import QtQuick.Effects
import "themes"

// Nova's lynx in the chat panel header (NovaChatWidget): one looping animated WebP per mood in
// assets/nova-lynx/ (rendered from the lynx SVGs with transparency; Qt doesn't run SVG animations),
// crossfaded on change, sitting in a ring + soft glow that reacts to the mood:
// idle breathes, listening ripples with the mic level, thinking orbits, speaking swells with the voice.
// Only the visible image plays, and nothing animates while `active` is false (panel closed).
Item {
  id: av

  property string mood: "idle"          // idle | listening | thinking | speaking | sleepy
  property real level: 0                // live voice level 0..1 (mic while listening, speaker while speaking)
  property bool active: true
  property color tint: Theme.colors.lavender
  property real disc: 52                // diameter of the lynx's circle; the ring sits just outside it
  readonly property real ringGap: Math.round(disc * 0.09)
  readonly property real ringD: disc + ringGap * 2

  width: ringD
  height: ringD

  // the art's circle: centre (0.4999, 0.5356), radius 0.4482 of the square canvas; ears and tufts poke out above it
  readonly property real art: disc / (2 * 0.44817)

  readonly property bool live: mood === "listening" || mood === "speaking"
  property real lvl: active && live ? Math.min(1, level) : 0
  Behavior on lvl { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }

  // slow ambient 0..1 shared by the glow and ring
  property real breath: 0
  SequentialAnimation on breath {
    running: av.active
    loops: Animation.Infinite
    NumberAnimation { to: 1; duration: av.mood === "sleepy" ? 2600 : 1800; easing.type: Motion.easeAmbient }
    NumberAnimation { to: 0; duration: av.mood === "sleepy" ? 2600 : 1800; easing.type: Motion.easeAmbient }
  }

  Behavior on tint { enabled: !Theme.fading; ColorAnimation { duration: Motion.slow; easing.type: Motion.easeIn } }

  // ---- glow: a blurred disc in the mood colour; only its opacity/scale move, so the blur renders once per colour
  Rectangle {
    id: glowSrc
    anchors.centerIn: parent
    width: av.disc; height: width; radius: width / 2
    color: av.tint
    visible: false
    layer.enabled: true
  }
  MultiEffect {
    anchors.fill: glowSrc
    source: glowSrc
    autoPaddingEnabled: true
    blurEnabled: true
    blur: 1.0
    blurMax: 48
    blurMultiplier: 0.6
    scale: 1.02 + 0.10 * av.lvl
    opacity: {
      switch (av.mood) {
      case "sleepy":    return 0.10 + 0.08 * av.breath
      case "listening": return 0.32 + 0.50 * av.lvl
      case "thinking":  return 0.30 + 0.14 * av.breath
      case "speaking":  return 0.30 + 0.55 * av.lvl
      default:          return 0.26 + 0.20 * av.breath
      }
    }
  }

  // ---- listening: two ripples rolling out of the ring
  Repeater {
    model: 2
    Rectangle {
      id: ripple
      required property int index
      anchors.centerIn: parent
      width: av.ringD; height: width; radius: width / 2
      color: "transparent"
      border.width: Math.max(1, Math.round(av.disc / 40))
      border.color: av.tint
      opacity: 0
      visible: running
      readonly property bool running: av.active && av.mood === "listening"
      SequentialAnimation {
        running: ripple.running
        loops: Animation.Infinite
        PauseAnimation { duration: ripple.index * 900 }
        ParallelAnimation {
          NumberAnimation { target: ripple; property: "scale"; from: 1.0; to: 1.24; duration: 1800; easing.type: Easing.OutCubic }
          NumberAnimation { target: ripple; property: "opacity"; from: 0.55; to: 0; duration: 1800; easing.type: Easing.OutQuad }
        }
        PauseAnimation { duration: (1 - ripple.index) * 900 }
        onStopped: { ripple.opacity = 0; ripple.scale = 1 }
      }
    }
  }

  // ---- ring
  Rectangle {
    anchors.centerIn: parent
    width: av.ringD; height: width; radius: width / 2
    color: "transparent"
    border.width: Math.max(1, Math.round(av.disc / 30))
    border.color: av.tint
    scale: 1 + 0.06 * av.lvl
    opacity: av.mood === "sleepy" ? 0.25 + 0.10 * av.breath
           : av.mood === "idle" ? 0.40 + 0.20 * av.breath : 0.85
    Behavior on opacity { NumberAnimation { duration: Motion.enter; easing.type: Motion.easeIn } }
  }

  // ---- thinking: three dots chasing round the ring
  Item {
    id: orbit
    anchors.fill: parent
    opacity: av.mood === "thinking" ? 1 : 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: Motion.enter; easing.type: Motion.easeIn } }
    RotationAnimator on rotation {
      from: 0; to: 360
      duration: 2200
      loops: Animation.Infinite
      running: av.active && orbit.visible
    }
    Repeater {
      model: 3
      Rectangle {
        required property int index
        readonly property real a: -Math.PI / 2 - index * 0.38
        readonly property real d: Math.max(3, Math.round(av.disc * (0.11 - index * 0.025)))
        width: d; height: d; radius: d / 2
        x: av.ringD / 2 + Math.cos(a) * av.ringD / 2 - d / 2
        y: av.ringD / 2 + Math.sin(a) * av.ringD / 2 - d / 2
        color: av.tint
        opacity: 1 - index * 0.3
      }
    }
  }

  // ---- the lynx: one AnimatedImage per mood. The incoming one fades in on top while the outgoing one
  // holds underneath and only then fades out, so the swap never dips through to the glow.
  Repeater {
    model: ["idle", "listening", "thinking", "speaking", "sleepy"]
    AnimatedImage {
      id: lynx
      required property string modelData
      readonly property bool current: av.mood === modelData
      x: av.ringD / 2 - 0.49989 * av.art
      y: av.ringD / 2 - 0.53559 * av.art
      width: av.art; height: av.art
      z: current ? 2 : 1
      source: Qt.resolvedUrl("assets/nova-lynx/nova-lynx-" + modelData + ".webp")
      fillMode: Image.PreserveAspectFit
      smooth: true
      mipmap: true
      opacity: 0
      visible: opacity > 0
      playing: av.active && visible
      Component.onCompleted: opacity = current ? 1 : 0
      onCurrentChanged: {
        if (current) { fadeOut.stop(); fadeIn.restart() } else { fadeIn.stop(); fadeOut.restart() }
      }
      NumberAnimation { id: fadeIn; target: lynx; property: "opacity"; to: 1; duration: 420; easing.type: Easing.OutCubic }
      SequentialAnimation {
        id: fadeOut
        PauseAnimation { duration: 380 }
        NumberAnimation { target: lynx; property: "opacity"; to: 0; duration: 200; easing.type: Easing.InQuad }
      }
    }
  }
}
