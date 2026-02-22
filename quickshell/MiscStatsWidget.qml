import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "templates"

DataWidget {
  id: miscWidget

  title: "󰌢  System Info"

  property string uptime: "..."
  property string loadAvg: "..."
  property int processCount: 0
  property string kernel: "..."
  property int userCount: 0

  Process {
    id: miscProc
    command: ["bash", "/storage/git/dotfiles/scripts/polls/miscstatspoll.sh"]
    running: true

    stdout: StdioCollector {
      onStreamFinished: {
        let parts = this.text.trim().split('|')
        if (parts.length === 5) {
          miscWidget.uptime = parts[0]
          miscWidget.loadAvg = parts[1]
          miscWidget.processCount = parseInt(parts[2])
          miscWidget.kernel = parts[3]
          miscWidget.userCount = parseInt(parts[4])
        }
      }
    }
  }

  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: miscProc.running = true
  }

  dataContent: [
    GridLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      columns: 2
      columnSpacing: 10
      rowSpacing: 7

      Text { text: "󰥔 Uptime"; color: "#f9e2af"; font.pixelSize: 12; font.bold: true; font.family: "monospace" }
      Text { text: miscWidget.uptime; color: "#cdd6f4"; font.pixelSize: 11; Layout.fillWidth: true; elide: Text.ElideRight; wrapMode: Text.NoWrap }

      Text { text: "󰓅 Load Avg"; color: "#fab387"; font.pixelSize: 12; font.bold: true; font.family: "monospace" }
      Text { text: miscWidget.loadAvg; color: "#cdd6f4"; font.pixelSize: 11; Layout.fillWidth: true }

      Text { text: "󰐾 Processes"; color: "#94e2d5"; font.pixelSize: 12; font.bold: true; font.family: "monospace" }
      Text { text: miscWidget.processCount.toString(); color: "#cdd6f4"; font.pixelSize: 11; Layout.fillWidth: true }

      Text { text: "󰒓 Kernel"; color: "#b4befe"; font.pixelSize: 12; font.bold: true; font.family: "monospace" }
      Text { text: miscWidget.kernel; color: "#cdd6f4"; font.pixelSize: 11; Layout.fillWidth: true; elide: Text.ElideRight; wrapMode: Text.NoWrap }

      Text { text: "󰀄 Users"; color: "#cba6f7"; font.pixelSize: 12; font.bold: true; font.family: "monospace" }
      Text { text: miscWidget.userCount.toString(); color: "#cdd6f4"; font.pixelSize: 11; Layout.fillWidth: true }
    }
  ]

  Component.onCompleted: {
    miscProc.running = true
  }
}
