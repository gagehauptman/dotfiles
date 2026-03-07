import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "templates"

DataWidget {
  id: tailscaleWidget

  title: "󰛳  Tailscale Network"
  titleSize: 16

  property var devices: []

  Process {
    id: tailscaleProc
    command: ["bash", root.home + "/.config/scripts/polls/tailscalepoll.sh"]
    running: true

    stdout: StdioCollector {
      onStreamFinished: {
        let lines = this.text.trim().split('\n').filter(l => l.trim())
        let deviceList = []

        for (let i = 0; i < lines.length; i++) {
          let parts = lines[i].split('|')
          if (parts.length === 3) {
            deviceList.push({
              name: parts[0],
              status: parts[1],
              ping: parts[2]
            })
          }
        }

        tailscaleWidget.devices = deviceList
      }
    }
  }

  Timer {
    interval: 10000
    running: true
    repeat: true
    onTriggered: tailscaleProc.running = true
  }

  dataContent: [
    ColumnLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      spacing: 6

      Repeater {
        model: tailscaleWidget.devices

        RowLayout {
          Layout.fillWidth: true
          spacing: 10

          Rectangle {
            width: 10; height: 10; radius: 5
            color: modelData.status === "online" ? "#a6e3a1" : "#f38ba8"
          }

          Text {
            text: modelData.name
            color: "#cdd6f4"
            font.pixelSize: 14
            font.bold: true
            Layout.fillWidth: true
          }

          Text {
            text: modelData.status
            color: modelData.status === "online" ? "#a6e3a1" : "#6c7086"
            font.pixelSize: 13
            font.italic: true
          }

          Text {
            visible: modelData.ping !== "N/A"
            text: "(" + modelData.ping + ")"
            color: {
              if (modelData.ping === "N/A") return "#6c7086"
              let pingValue = parseInt(modelData.ping)
              if (pingValue < 30) return "#a6e3a1"
              if (pingValue < 100) return "#f9e2af"
              return "#f38ba8"
            }
            font.pixelSize: 12
          }
        }
      }

      Text {
        visible: tailscaleWidget.devices.length === 0
        text: "Loading devices..."
        color: "#6c7086"
        font.pixelSize: 13
        font.italic: true
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignHCenter
      }
    }
  ]

  Component.onCompleted: {
    tailscaleProc.running = true
  }
}
