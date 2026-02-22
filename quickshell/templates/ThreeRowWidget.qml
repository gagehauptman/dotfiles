// Base: Three-Row Widget (title | content | footer, 2 separators)

import QtQuick
import QtQuick.Layouts

Item {
  id: root

  visible: bar.state === "dashboard"
  implicitHeight: 190

  property string title: "Widget"
  property Component middleContent: null
  property Component footerContent: null

  Rectangle {
    anchors.fill: parent
    color: "#181825"
    radius: 15

    ColumnLayout {
      anchors {
        verticalCenter: parent.verticalCenter
        left: parent.left
        right: parent.right
        margins: 15
      }
      spacing: 8

      // Title
      Text {
        text: root.title
        color: "#cdd6f4"
        font.pixelSize: 16
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

      // Middle content slot
      Loader {
        Layout.fillWidth: true
        Layout.fillHeight: true
        sourceComponent: root.middleContent
      }

      // Separator
      Rectangle {
        Layout.fillWidth: true
        height: 2
        color: "#45475a"
      }

      // Footer content slot
      Loader {
        Layout.fillWidth: true
        sourceComponent: root.footerContent
      }
    }
  }
}
