import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "templates"

DataWidget {
  id: systemWidget

  title: "󰻠  System Resources"
  implicitHeight: 280

  property real cpuUsage: 0
  property real ramUsed: 0
  property real ramTotal: 0
  property real ramPercent: 0
  property string diskUsed: "0G"
  property string diskTotal: "0G"
  property real diskPercent: 0
  property string cpuGovernor: "powersave"
  property int gpuProfileIdx: 0
  property string gpuProfileName: "DEFAULT"

  Process {
    id: systemProc
    command: ["bash", "/storage/git/dotfiles/scripts/polls/systempoll.sh"]
    running: true

    stdout: StdioCollector {
      onStreamFinished: {
        let parts = this.text.trim().split('|')
        if (parts.length >= 7) {
          systemWidget.cpuUsage = parseFloat(parts[0])
          systemWidget.ramUsed = parseFloat(parts[1])
          systemWidget.ramTotal = parseFloat(parts[2])
          systemWidget.ramPercent = parseFloat(parts[3])
          systemWidget.diskUsed = parts[4]
          systemWidget.diskTotal = parts[5]
          systemWidget.diskPercent = parseFloat(parts[6])
          if (parts.length >= 8) systemWidget.cpuGovernor = parts[7].trim()
          if (parts.length >= 10) {
            systemWidget.gpuProfileIdx = parseInt(parts[8])
            systemWidget.gpuProfileName = parts[9].trim()
          }
        }
      }
    }
  }

  Timer {
    interval: 3000
    running: true
    repeat: true
    onTriggered: systemProc.running = true
  }

  dataContent: [
    ColumnLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      spacing: 8

      // CPU
      ColumnLayout {
        Layout.fillWidth: true
        spacing: 6

        RowLayout {
          Layout.fillWidth: true
          Text { text: "󰘚 CPU"; color: "#89b4fa"; font.pixelSize: 13; font.bold: true; font.family: "monospace"; Layout.preferredWidth: 70 }
          Text { text: systemWidget.cpuUsage.toFixed(1) + "%"; color: "#cdd6f4"; font.pixelSize: 12; Layout.fillWidth: true }
        }

        Rectangle {
          Layout.fillWidth: true; height: 8; radius: 4; color: "#313244"
          Rectangle {
            width: parent.width * (systemWidget.cpuUsage / 100); height: parent.height; radius: 4
            color: systemWidget.cpuUsage > 80 ? "#f38ba8" : systemWidget.cpuUsage > 50 ? "#fab387" : "#89b4fa"
            Behavior on width { NumberAnimation { duration: 200 } }
          }
        }
      }

      // RAM
      ColumnLayout {
        Layout.fillWidth: true
        spacing: 6

        RowLayout {
          Layout.fillWidth: true
          Text { text: "󰍛 RAM"; color: "#a6e3a1"; font.pixelSize: 13; font.bold: true; font.family: "monospace"; Layout.preferredWidth: 70 }
          Text { text: systemWidget.ramUsed.toFixed(1) + " / " + systemWidget.ramTotal.toFixed(1) + " GB (" + systemWidget.ramPercent.toFixed(0) + "%)"; color: "#cdd6f4"; font.pixelSize: 12; Layout.fillWidth: true }
        }

        Rectangle {
          Layout.fillWidth: true; height: 8; radius: 4; color: "#313244"
          Rectangle {
            width: parent.width * (systemWidget.ramPercent / 100); height: parent.height; radius: 4
            color: systemWidget.ramPercent > 80 ? "#f38ba8" : systemWidget.ramPercent > 50 ? "#fab387" : "#a6e3a1"
            Behavior on width { NumberAnimation { duration: 200 } }
          }
        }
      }

      // Disk
      ColumnLayout {
        Layout.fillWidth: true
        spacing: 6

        RowLayout {
          Layout.fillWidth: true
          Text { text: "󰋊 Disk"; color: "#f5c2e7"; font.pixelSize: 13; font.bold: true; font.family: "monospace"; Layout.preferredWidth: 70 }
          Text { text: systemWidget.diskUsed + " / " + systemWidget.diskTotal + " (" + systemWidget.diskPercent.toFixed(0) + "%)"; color: "#cdd6f4"; font.pixelSize: 12; Layout.fillWidth: true }
        }

        Rectangle {
          Layout.fillWidth: true; height: 8; radius: 4; color: "#313244"
          Rectangle {
            width: parent.width * (systemWidget.diskPercent / 100); height: parent.height; radius: 4
            color: systemWidget.diskPercent > 80 ? "#f38ba8" : systemWidget.diskPercent > 50 ? "#fab387" : "#f5c2e7"
            Behavior on width { NumberAnimation { duration: 200 } }
          }
        }
      }

      // Separator
      Rectangle {
        Layout.fillWidth: true
        height: 1
        color: "#313244"
      }

      // Toggles
      Process {
        id: governorToggle
        command: ["sudo", "/storage/git/dotfiles/scripts/cpu-governor-toggle.sh"]

        stdout: StdioCollector {
          onStreamFinished: {
            systemWidget.cpuGovernor = this.text.trim()
          }
        }
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: 10

        Rectangle {
          width: 10; height: 10; radius: 5
          color: systemWidget.cpuGovernor === "performance" ? "#a6e3a1" : "#89b4fa"
          Behavior on color { ColorAnimation { duration: 200 } }
        }

        Text {
          text: "󱐋 CPU Governor"
          color: "#cdd6f4"
          font.pixelSize: 13
          font.bold: true
          font.family: "monospace"
          Layout.fillWidth: true
        }

        Text {
          text: systemWidget.cpuGovernor === "performance" ? "performance" : "powersave"
          color: systemWidget.cpuGovernor === "performance" ? "#a6e3a1" : "#89b4fa"
          font.pixelSize: 13
          font.italic: true
          font.family: "monospace"

          Behavior on color { ColorAnimation { duration: 200 } }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: governorToggle.running = true
          }
        }
      }

      // GPU Power Profile toggle
      Process {
        id: gpuProfileToggle
        command: ["sudo", "/storage/git/dotfiles/scripts/gpu-profile-toggle.sh"]

        stdout: StdioCollector {
          onStreamFinished: {
            let parts = this.text.trim().split('|')
            if (parts.length >= 2) {
              systemWidget.gpuProfileIdx = parseInt(parts[0])
              systemWidget.gpuProfileName = parts[1]
            }
          }
        }
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: 10

        Rectangle {
          width: 10; height: 10; radius: 5
          color: systemWidget.gpuProfileIdx === 1 ? "#a6e3a1" : systemWidget.gpuProfileIdx === 2 ? "#89b4fa" : "#f9e2af"
          Behavior on color { ColorAnimation { duration: 200 } }
        }

        Text {
          text: "󰢮 GPU Profile"
          color: "#cdd6f4"
          font.pixelSize: 13
          font.bold: true
          font.family: "monospace"
          Layout.fillWidth: true
        }

        Text {
          text: systemWidget.gpuProfileIdx === 0 ? "default" : systemWidget.gpuProfileIdx === 1 ? "3D gaming" : "powersave"
          color: systemWidget.gpuProfileIdx === 1 ? "#a6e3a1" : systemWidget.gpuProfileIdx === 2 ? "#89b4fa" : "#f9e2af"
          font.pixelSize: 13
          font.italic: true
          font.family: "monospace"

          Behavior on color { ColorAnimation { duration: 200 } }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: gpuProfileToggle.running = true
          }
        }
      }
    }
  ]

  Component.onCompleted: {
    systemProc.running = true
  }
}
