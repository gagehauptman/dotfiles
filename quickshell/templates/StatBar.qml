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
  spacing: 6

  RowLayout {
    Layout.fillWidth: true
    Text {
      text: root.label
      color: root.accentColor
      font.pixelSize: 13
      font.bold: true
      font.family: "monospace"
      Layout.preferredWidth: 70
    }
    Text {
      text: root.valueText
      color: Theme.colors.textPrimary
      font.pixelSize: 12
      Layout.fillWidth: true
    }
  }

  Rectangle {
    Layout.fillWidth: true
    height: 8
    radius: 4
    color: Theme.colors.inset
    Rectangle {
      width: parent.width * Math.max(0, Math.min(1, root.percent / 100))
      height: parent.height
      radius: 4
      color: root.percent > 80 ? Theme.colors.red
           : root.percent > 50 ? Theme.colors.orange
           : root.accentColor
      Behavior on width { NumberAnimation { duration: 200 } }
    }
  }
}
