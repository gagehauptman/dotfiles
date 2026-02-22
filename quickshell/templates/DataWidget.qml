// Base: Data Widget (title + separator + data, 1 separator)
// Props: title, dataContent (Component)

import QtQuick
import QtQuick.Layouts

Item {
  id: root

  visible: bar.state === "dashboard"
  implicitHeight: 190

  property string title: "Widget"
  property int titleSize: 14
  property alias dataContent: dataPlaceholder.children

  Rectangle {
    anchors.fill: parent
    color: "#181825"
    radius: 15

    ColumnLayout {
      anchors {
        top: parent.top
        left: parent.left
        right: parent.right
        margins: 15
      }
      spacing: 8

      // Title
      Text {
        text: root.title
        color: "#cdd6f4"
        font.pixelSize: root.titleSize
        font.bold: true
        font.family: "monospace"
        Layout.fillWidth: true
        elide: Text.ElideRight
      }

      // Separator
      Rectangle {
        Layout.fillWidth: true
        height: 2
        color: "#45475a"
      }

      // Data content slot
      Item {
        id: dataPlaceholder
        Layout.fillWidth: true
        implicitHeight: childrenRect.height
      }
    }
  }
}
