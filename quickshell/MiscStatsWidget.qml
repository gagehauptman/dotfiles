import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "templates"
import "themes"

DataWidget {
  id: miscWidget

  title: "󰌢  System Info"

  property string uptime: "..."
  property string loadAvg: "..."
  property int processCount: 0
  property string kernel: "..."
  property int userCount: 0
  property int packageCount: 0

  Process {
    id: pkgProc
    command: ["bash", "-c", "pacman -Q 2>/dev/null | wc -l"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: miscWidget.packageCount = parseInt(this.text.trim()) || 0
    }
  }

  Process {
    id: miscProc
    command: ["bash", root.home + "/.config/scripts/polls/miscstatspoll.sh"]
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
    onTriggered: { miscProc.running = true; pkgProc.running = true }
  }

  dataContent: [
    GridLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      columns: 2
      columnSpacing: 10
      rowSpacing: 7

      Text { text: "󰥔 Uptime"; color: Theme.colors.yellow; font.pixelSize: 12; font.bold: true; font.family: "monospace" }
      Text { text: miscWidget.uptime; color: Theme.colors.textPrimary; font.pixelSize: 11; Layout.fillWidth: true; elide: Text.ElideRight; wrapMode: Text.NoWrap }

      Text { text: "󰓅 Load Avg"; color: Theme.colors.orange; font.pixelSize: 12; font.bold: true; font.family: "monospace" }
      Text { text: miscWidget.loadAvg; color: Theme.colors.textPrimary; font.pixelSize: 11; Layout.fillWidth: true }

      Text { text: "󰐾 Processes"; color: Theme.colors.teal; font.pixelSize: 12; font.bold: true; font.family: "monospace" }
      Text { text: miscWidget.processCount.toString(); color: Theme.colors.textPrimary; font.pixelSize: 11; Layout.fillWidth: true }

      Text { text: "󰒓 Kernel"; color: Theme.colors.lavender; font.pixelSize: 12; font.bold: true; font.family: "monospace" }
      Text { text: miscWidget.kernel; color: Theme.colors.textPrimary; font.pixelSize: 11; Layout.fillWidth: true; elide: Text.ElideRight; wrapMode: Text.NoWrap }

      Text { text: "󰀄 Users"; color: Theme.colors.violet; font.pixelSize: 12; font.bold: true; font.family: "monospace" }
      Text { text: miscWidget.userCount.toString(); color: Theme.colors.textPrimary; font.pixelSize: 11; Layout.fillWidth: true }

      Text { text: "󰏖 Packages"; color: Theme.colors.pink; font.pixelSize: 12; font.bold: true; font.family: "monospace" }
      Text { text: miscWidget.packageCount.toString(); color: Theme.colors.textPrimary; font.pixelSize: 11; Layout.fillWidth: true }
    }
  ]

  Component.onCompleted: {
    miscProc.running = true
  }
}
