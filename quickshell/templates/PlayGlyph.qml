// Transport glyph drawn as shapes in a fixed square slot (font glyphs fall back
// to fonts with different metrics and shift the text next to them), same
// drawing as the bar's MusicWidget. kind: "play" | "pause" | "next" | "previous".

import QtQuick
import QtQuick.Shapes

Item {
  id: glyph

  property string kind: "play"
  property real size: 12
  property color color: "white"

  implicitWidth: size
  implicitHeight: size

  Shape {
    anchors.centerIn: parent
    width: glyph.size
    height: glyph.size
    visible: glyph.kind !== "pause"
    // "next"/"previous" are the play triangle plus a bar, mirrored for previous
    transform: Scale { origin.x: glyph.size / 2; xScale: glyph.kind === "previous" ? -1 : 1 }
    ShapePath {
      fillColor: glyph.color
      strokeColor: "transparent"
      startX: glyph.size * 0.1; startY: 0
      PathLine { x: glyph.size * 0.1 + (glyph.kind === "play" ? glyph.size * 0.9 : glyph.size * 0.62); y: glyph.size / 2 }
      PathLine { x: glyph.size * 0.1; y: glyph.size }
      PathLine { x: glyph.size * 0.1; y: 0 }
    }
    Rectangle {
      visible: glyph.kind === "next" || glyph.kind === "previous"
      x: glyph.size * 0.76; y: 0
      width: Math.max(2, Math.round(glyph.size * 0.18)); height: glyph.size
      color: glyph.color
    }
  }
  Row {
    anchors.centerIn: parent
    spacing: Math.max(2, Math.round(glyph.size * 0.2))
    visible: glyph.kind === "pause"
    Rectangle { width: Math.max(2, Math.round(glyph.size * 0.3)); height: glyph.size; color: glyph.color }
    Rectangle { width: Math.max(2, Math.round(glyph.size * 0.3)); height: glyph.size; color: glyph.color }
  }
}
