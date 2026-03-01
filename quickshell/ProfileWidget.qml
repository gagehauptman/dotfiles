import QtQuick
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Quickshell
import Quickshell.Io

Item {
  id: profileWidget

  visible: bar.state === "dashboard"

  property string username: ""
  property string hostname: ""

  Process {
    id: usernameProc
    command: ["whoami"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: profileWidget.username = this.text.trim()
    }
  }

  Process {
    id: hostnameProc
    command: ["cat", "/etc/hostname"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: profileWidget.hostname = this.text.trim()
    }
  }

  Rectangle {
    anchors.fill: parent
    color: "#181825"
    radius: 15
    ColumnLayout {
      anchors.centerIn: parent
      spacing: 15

      // Profile picture
      Item {
        Layout.alignment: Qt.AlignHCenter
        width: 100
        height: 100

        // Fallback placeholder
        Rectangle {
          anchors.fill: parent
          radius: 50
          color: "#313244"
          border.color: "#45475a"
          border.width: 2
          visible: pfpImage.status !== Image.Ready

          Text {
            anchors.centerIn: parent
            text: "󰀉"
            color: "#6c7086"
            font.pixelSize: 48
            font.family: "monospace"
          }
        }

        // Actual profile picture
        Image {
          id: pfpImage
          anchors.fill: parent
          source: "file:///home/v1k/.face"
          sourceSize: Qt.size(100, 100)
          fillMode: Image.PreserveAspectCrop
          visible: false
        }

        Rectangle {
          id: pfpMask
          anchors.fill: parent
          radius: 50
          visible: false
        }

        OpacityMask {
          anchors.fill: parent
          source: pfpImage
          maskSource: pfpMask
          visible: pfpImage.status === Image.Ready
        }
      }

      // Username
      Text {
        Layout.alignment: Qt.AlignHCenter
        text: profileWidget.username
        color: "#cdd6f4"
        font.pixelSize: 16
        font.bold: true
        font.family: "monospace"
      }

      // Hostname
      Text {
        Layout.alignment: Qt.AlignHCenter
        text: profileWidget.hostname
        color: "#6c7086"
        font.pixelSize: 12
        font.family: "monospace"
      }

      // Color palette dots
      Row {
        Layout.alignment: Qt.AlignHCenter
        spacing: 6

        Repeater {
          model: ["#f38ba8", "#fab387", "#f9e2af", "#a6e3a1", "#89b4fa", "#cba6f7", "#f5c2e7", "#94e2d5"]
          Rectangle {
            width: 14
            height: 14
            radius: 7
            color: modelData
          }
        }
      }
    }
  }
}
