// Labeled stat row + graduated gauge. A thin flat fill on a hairline track,
// minor ticks every 10%, a major one at 50%, faint caution notches at the
// colour thresholds and a peak-hold mark (the recent max, decaying slowly).
// Fill uses accentColor, then orange >50%, red >80%.

import QtQuick
import QtQuick.Layouts
import "../themes"

ColumnLayout {
  id: root

  property string label: ""
  property string valueText: ""
  property real percent: 0          // 0–100
  property color accentColor: Theme.colors.blue
  property real k: 1                // size factor from the card (DataWidget.k)
  property var history: []          // recent samples (0–100) to trace behind the label row

  // Gauge tuning
  property bool showTicks: true
  property bool showPeak: true
  property int peakHoldMs: 20000    // peak stays put this long, then decays
  property real peakDecay: 1.5      // percentage points per second once it decays

  readonly property real cautionAt: 50
  readonly property real warningAt: 80
  readonly property real clamped: Math.max(0, Math.min(100, percent))

  Layout.fillWidth: true
  spacing: Math.round(metrics.spacingSmall * root.k)

  // Label row; with `history` set, the recent trend is traced between the
  // label and the value (Sparkline, low contrast).
  Item {
    Layout.fillWidth: true
    implicitHeight: labelRow.implicitHeight
    Sparkline {
      visible: Dash.tracesEnabled && root.history.length > 1
      x: labelText.width + metrics.spacingNormal
      width: Math.max(0, labelRow.width - x - valueLabel.contentWidth - metrics.spacingNormal)
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.topMargin: 2
      anchors.bottomMargin: 2
      values: root.history
      max: 100
      color: root.accentColor
    }
    RowLayout {
      id: labelRow
      anchors.left: parent.left
      anchors.right: parent.right
      // Label: small tracked caps, muted; the value carries the weight.
      Text {
        id: labelText
        text: root.label
        color: Theme.colors.textSecondary
        font.pixelSize: Math.round(metrics.fontSmall * root.k)
        font.family: Theme.fonts.mono
        font.capitalization: Font.AllUppercase
        font.letterSpacing: root.k < 0.9 ? 0 : 1
        Layout.preferredWidth: Math.max(implicitWidth, metrics.s(70) * root.k)
      }
      Text {
        id: valueLabel
        text: root.valueText
        color: Theme.colors.textPrimary
        font.pixelSize: Math.round(metrics.fontSmall * root.k)
        font.family: Theme.fonts.mono
        font.features: { "tnum": 1, "lnum": 1 }
        horizontalAlignment: Text.AlignRight
        Layout.fillWidth: true
        elide: Text.ElideRight
      }
    }
  }

  // Gauge: same overall height as the old pill so card fitting is unchanged.
  Item {
    id: gauge
    Layout.fillWidth: true
    implicitHeight: Math.round(metrics.s(8) * root.k)
    height: implicitHeight
    readonly property real barH: Math.max(2, Math.round(3 * root.k))
    function xAt(p) { return Math.round(p / 100 * (width - 1)) }

    // Hairline track
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width; height: 1
      color: Theme.colors.border
    }

    // Scale ticks: minor every 10%, major at 0/50/100
    Repeater {
      model: root.showTicks ? 11 : 0
      Rectangle {
        required property int index
        readonly property bool major: index % 5 === 0
        x: gauge.xAt(index * 10)
        width: 1
        height: major ? gauge.height : Math.round(gauge.height * 0.5)
        anchors.verticalCenter: parent.verticalCenter
        color: Theme.colors.border
        opacity: major ? 0.7 : 0.4
      }
    }

    // Fill
    Rectangle {
      id: fill
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(0, gauge.width * root.clamped / 100)
      height: gauge.barH
      radius: Theme.rs(1)
      color: root.percent > root.warningAt ? Theme.colors.red
           : root.percent > root.cautionAt ? Theme.colors.orange
           : root.accentColor
      Behavior on width { NumberAnimation { duration: Motion.std; easing.type: Motion.easeIn } }
      Behavior on color { enabled: !Theme.fading; ColorAnimation { duration: Motion.std } }
    }

    // Caution / warning notches (above the track, so the fill never hides them)
    Repeater {
      model: root.showTicks ? [root.cautionAt, root.warningAt] : []
      Rectangle {
        required property var modelData
        required property int index
        x: gauge.xAt(modelData)
        y: 0
        width: 1
        height: Math.max(2, Math.round((gauge.height - gauge.barH) / 2))
        color: index === 0 ? Theme.colors.orange : Theme.colors.red
        opacity: 0.6
      }
    }

    // Peak-hold mark
    Rectangle {
      visible: root.showPeak && root.peak - root.clamped > 1
      x: Math.min(gauge.width - width, gauge.xAt(root.peak))
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(1, Math.round(2 * root.k))
      height: gauge.height
      color: Theme.colors.textSecondary
      opacity: 0.7
    }
  }

  // One quiet pulse when the level changes (nominal / caution / warning), then
  // steady: motion only when something changed. Nothing loops.
  readonly property int level: percent > warningAt ? 2 : percent > cautionAt ? 1 : 0
  onLevelChanged: if (visible) levelPulse.restart()
  SequentialAnimation {
    id: levelPulse
    NumberAnimation { target: fill; property: "opacity"; to: 0.35; duration: Motion.slow / 3; easing.type: Motion.easeOut }
    NumberAnimation { target: fill; property: "opacity"; to: 1; duration: Motion.slow * 2 / 3; easing.type: Motion.easeIn }
  }

  // Peak-hold state: jumps up with the value, holds, then sinks back slowly.
  property real peak: 0
  property real peakTime: 0
  onClampedChanged: if (clamped >= peak) { peak = clamped; peakTime = Date.now() }
  Timer {
    interval: 1000
    repeat: true
    running: root.visible && root.showPeak && root.peak > root.clamped
    onTriggered: if (Date.now() - root.peakTime > root.peakHoldMs)
      root.peak = Math.max(root.clamped, root.peak - root.peakDecay)
  }
}
