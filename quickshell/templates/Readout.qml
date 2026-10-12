// Telemetry readout: a number in tabular mono digits with its unit set apart
// (smaller, muted, baseline-aligned). Give it `text` as the poll emits it
// ("12.3MiB/s", "512B/s", "42%"): the number rolls to each new sample over
// Motion.std while the unit stays the same, and jumps when the unit changes
// (KiB -> MiB) so it never counts through a meaningless range. Text that
// isn't "number + unit" is shown as-is.

import QtQuick
import "../themes"

Row {
  id: root

  property string text: ""
  property real pixelSize: metrics.fontSmall
  property color color: Theme.colors.textPrimary
  property color unitColor: Theme.colors.textMuted
  property bool bold: false
  property real unitScale: 0.8
  property bool animated: true

  spacing: Math.max(1, Math.round(pixelSize * 0.15))

  property real _v: 0
  property int _dec: 0
  property string _unit: ""
  property bool _ok: false

  function parse() {
    let m = /^\s*(-?\d+(?:\.\d+)?)\s*(.*?)\s*$/.exec(text)
    if (!m) { _ok = false; return }
    let v = parseFloat(m[1])
    let jump = !_ok || m[2] !== _unit || !animated
    _dec = (m[1].split(".")[1] || "").length
    _unit = m[2]
    _ok = true
    tween.stop()
    if (jump) _v = v
    else { tween.to = v; tween.start() }
  }
  onTextChanged: parse()
  Component.onCompleted: parse()

  NumberAnimation { id: tween; target: root; property: "_v"; duration: Motion.std; easing.type: Motion.easeIn }

  Text {
    id: valueText
    text: root._ok ? root._v.toFixed(root._dec) : root.text
    color: root.color
    font.pixelSize: root.pixelSize
    font.bold: root.bold
    font.family: Theme.fonts.mono
    font.features: { "tnum": 1, "lnum": 1 }
  }
  Text {
    visible: root._ok && root._unit !== ""
    anchors.baseline: valueText.baseline
    text: root._unit
    color: root.unitColor
    font.pixelSize: Math.round(root.pixelSize * root.unitScale)
    font.family: Theme.fonts.mono
  }
}
