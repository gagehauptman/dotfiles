import QtQuick
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Quickshell
import Quickshell.Io
import "themes"

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
    color: Theme.colors.panel
    radius: metrics.radiusLarge
    ColumnLayout {
      anchors.centerIn: parent
      spacing: metrics.spacingLarge

      // Profile picture
      Item {
        Layout.alignment: Qt.AlignHCenter
        width: metrics.profilePicSize
        height: metrics.profilePicSize

        // Fallback placeholder
        Rectangle {
          anchors.fill: parent
          radius: metrics.s(50)
          color: Theme.colors.inset
          border.color: Theme.colors.border
          border.width: 2
          visible: pfpImage.status !== Image.Ready

          Text {
            anchors.centerIn: parent
            text: "󰀉"
            color: Theme.colors.textMuted
            font.pixelSize: metrics.fontHuge
            font.family: "monospace"
          }
        }

        // Actual profile picture
        Image {
          id: pfpImage
          anchors.fill: parent
          source: "file://" + root.home + "/.face"
          sourceSize: Qt.size(metrics.profilePicSize, metrics.profilePicSize)
          fillMode: Image.PreserveAspectCrop
          visible: false
        }

        Rectangle {
          id: pfpMask
          anchors.fill: parent
          radius: metrics.s(50)
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
        color: Theme.colors.textPrimary
        font.pixelSize: metrics.fontLarge
        font.bold: true
        font.family: "monospace"
      }

      // Hostname
      Text {
        Layout.alignment: Qt.AlignHCenter
        text: profileWidget.hostname
        color: Theme.colors.textMuted
        font.pixelSize: metrics.fontSmall
        font.family: "monospace"
      }

      // Color palette dots
      Row {
        Layout.alignment: Qt.AlignHCenter
        spacing: metrics.spacingSmall

        Repeater {
          model: [Theme.colors.red, Theme.colors.orange, Theme.colors.yellow, Theme.colors.green, Theme.colors.blue, Theme.colors.violet, Theme.colors.pink, Theme.colors.teal]
          Rectangle {
            width: metrics.s(14)
            height: metrics.s(14)
            radius: metrics.s(7)
            color: modelData
          }
        }
      }
    }
  }
}
