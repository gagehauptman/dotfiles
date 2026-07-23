// Labeled stat row + fill bar. Fill uses accentColor, then orange >50%, red >80%.

import QtQuick
import QtQuick.Layouts
import "../themes"

ColumnLayout {
  id: root

  property string label: ""
  property string valueText: ""
  property real percent: 0          // 0–100
  property color accentColor: Theme.colors.blue

  Layout.fillWidth: true
  spacing: metrics.spacingSmall

  RowLayout {
    Layout.fillWidth: true
    Text {
      text: root.label
      color: root.accentColor
      font.pixelSize: metrics.fontSmall
      font.bold: true
      font.family: "monospace"
      Layout.preferredWidth: metrics.s(70)
    }
    Text {
      text: root.valueText
      color: Theme.colors.textPrimary
      font.pixelSize: metrics.fontSmall
      Layout.fillWidth: true
    }
  }

  Rectangle {
    Layout.fillWidth: true
    height: metrics.s(8)
    radius: metrics.s(4)
    color: Theme.colors.inset
    Rectangle {
      width: parent.width * Math.max(0, Math.min(1, root.percent / 100))
      height: parent.height
      radius: metrics.s(4)
      color: root.percent > 80 ? Theme.colors.red
           : root.percent > 50 ? Theme.colors.orange
           : root.accentColor
      Behavior on width { NumberAnimation { duration: 200 } }
    }
  }
}
