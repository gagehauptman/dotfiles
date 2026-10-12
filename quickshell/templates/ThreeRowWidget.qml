// Base: Three-Row Widget (title | content | footer, 2 separators)
// Size-adaptive: `k` scales fonts/spacing with the cell (use fs() for font
// sizes), `compact` flags a squished cell, and the title row is dropped when
// the cell is too short for it. The middle slot clips instead of spilling
// over neighbouring cards.

import QtQuick
import QtQuick.Layouts
import "../themes"

Item {
  id: root

  visible: bar.state === "dashboard"
  implicitHeight: metrics.dataWidgetHeight

  property string title: "Widget"
  // Per-widget options from the active dashboard preset (see presets.json).
  property var options: ({})
  property Component middleContent: null
  property Component footerContent: null
  // false drops the footer row and the separator above it
  property bool showFooter: true

  // Size the content was designed for (unscaled px; one dashboard row).
  property real refWidth: 360
  property real refHeight: 160
  // true: the middle content gets the whole slot (its own height) instead of
  // being centred at its implicit height.
  property bool middleFills: false
  readonly property real k: metrics.cardScale(width, height, refWidth, refHeight)
  // Scaled size; shrinking never takes text below fontTiny
  function fs(px) { return Math.max(Math.round(px * k), Math.min(px, metrics.fontTiny)) }
  readonly property bool compact: width < metrics.s(260) || height < metrics.s(140)
  readonly property bool showTitle: height >= metrics.s(110)
  readonly property real middleHeight: middleSlot.height
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
        visible: root.showTitle
        text: root.title
        // Instrument-style label: tracked caps, secondary weight; values below carry the emphasis.
        color: Theme.colors.textSecondary
        font.pixelSize: root.fs(metrics.fontNormal)
        font.family: Theme.fonts.mono
        font.capitalization: Font.AllUppercase
        font.letterSpacing: root.compact ? 0 : Theme.titleTracking
        Layout.fillWidth: true
        elide: Text.ElideRight
      }

      // Separator
      Rectangle {
        visible: root.showTitle
        Layout.fillWidth: true
        height: bar.dividerThickness
        color: Theme.colors.border
      }

      // Middle content slot: takes the space left over, centred, clipped
      Item {
        id: middleSlot
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true

        Loader {
          id: middleLoader
          width: parent.width
          height: root.middleFills ? parent.height : undefined
          // Centred; top-aligned once it no longer fits so the start stays readable
          y: root.middleFills ? 0 : Math.max(0, (parent.height - height) / 2)
          sourceComponent: root.middleContent
        }
      }

      // Separator
      Rectangle {
        visible: root.showFooter
        Layout.fillWidth: true
        height: bar.dividerThickness
        color: Theme.colors.border
      }

      // Footer content slot
      Loader {
        visible: root.showFooter
        active: root.showFooter
        Layout.fillWidth: true
        sourceComponent: root.footerContent
      }
    }
  }
}
