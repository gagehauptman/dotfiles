// Base: Data Widget (title + separator + data, 1 separator)
// Props: title, dataContent (Component)
// Size-adaptive like ThreeRowWidget: `k`/fs() scale with the cell, `compact`
// flags a squished cell, `dataHeight` is the room the data slot has (for
// widgets that drop low-priority rows), and the data clips instead of spilling.

import QtQuick
import QtQuick.Layouts
import "../themes"

Item {
  id: root

  visible: bar.state === "dashboard"
  implicitHeight: metrics.dataWidgetHeight

  property string title: "Widget"
  property int titleSize: metrics.fontNormal
  // Per-widget options from the active dashboard preset (see presets.json).
  property var options: ({})
  property alias dataContent: dataPlaceholder.children
  // true: the data content gets the whole slot height (for content that fills,
  // e.g. a trace under the readouts) instead of being centred at its own height.
  property bool dataFills: false

  // Size the content was designed for (unscaled px).
  property real refWidth: 360
  property real refHeight: 160
  readonly property real k: metrics.cardScale(width, height, refWidth, refHeight)
  // Scaled size; shrinking never takes text below fontTiny
  function fs(px) { return Math.max(Math.round(px * k), Math.min(px, metrics.fontTiny)) }
  readonly property bool compact: width < metrics.s(260) || height < metrics.s(140)
  readonly property real dataHeight: dataSlot.height
  readonly property real pad: Math.round((compact ? metrics.spacingNormal : metrics.spacingLarge) * Math.min(k, 1.4))

  Rectangle {
    anchors.fill: parent
    color: Theme.colors.panel
    radius: metrics.radiusLarge
    // Hairline frame (Theme.cardFrameOpacity)
    border.width: Theme.cardFrameOpacity > 0 ? Theme.bw(1) : 0
    border.color: Theme.cardFrame

    ColumnLayout {
      anchors.fill: parent
      anchors.margins: root.pad
      spacing: Math.round(metrics.spacingSmall * Math.min(root.k, 1.4))

      // Title
      Text {
        text: root.title
        // Instrument-style label: tracked caps, secondary weight; values below carry the emphasis.
        color: Theme.colors.textSecondary
        font.pixelSize: root.fs(Math.round(root.titleSize * 0.9))
        font.family: Theme.fonts.mono
        font.capitalization: Font.AllUppercase
        font.letterSpacing: root.compact ? 0 : Theme.titleTracking
        Layout.fillWidth: true
        elide: Text.ElideRight
      }

      // Separator
      Rectangle {
        Layout.fillWidth: true
        height: bar.dividerThickness
        color: Theme.colors.border
      }

      // Data content slot: centred in the room left, top-aligned when it doesn't fit
      Item {
        id: dataSlot
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true

        Item {
          id: dataPlaceholder
          width: parent.width
          height: root.dataFills ? parent.height : childrenRect.height
          y: root.dataFills ? 0 : Math.max(0, (parent.height - height) / 2)
        }
      }
    }
  }
}
