import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "templates"

DataWidget {
  id: networkWidget

  title: "󰖟  Network (" + interfaceName + ")"

  property string interfaceName: "..."
  property string rxTotal: "0B"
  property string txTotal: "0B"
  property string rxRate: "0B/s"
  property string txRate: "0B/s"

  Process {
    id: networkProc
    command: ["bash", "/storage/git/dotfiles/scripts/polls/networkpoll.sh"]
    running: true

    stdout: StdioCollector {
      onStreamFinished: {
        let parts = this.text.trim().split('|')
        if (parts.length === 5) {
          networkWidget.interfaceName = parts[0]
          networkWidget.rxTotal = parts[1]
          networkWidget.txTotal = parts[2]
          networkWidget.rxRate = parts[3]
          networkWidget.txRate = parts[4]
        }
      }
    }
  }

  Timer {
    interval: 2000
    running: true
    repeat: true
    onTriggered: networkProc.running = true
  }

  dataContent: [
    GridLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      columns: 2
      columnSpacing: 20
      rowSpacing: 12

      RowLayout {
        Layout.columnSpan: 2
        Layout.fillWidth: true
        spacing: 10

        Text { text: "󰇚"; color: "#89dceb"; font.pixelSize: 16; font.family: "monospace" }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: 2

          Text { text: "Download"; color: "#89dceb"; font.pixelSize: 11; font.bold: true }

          RowLayout {
            spacing: 8
            Text { text: networkWidget.rxRate; color: "#cdd6f4"; font.pixelSize: 12; font.bold: true }
            Text { text: "(" + networkWidget.rxTotal + " total)"; color: "#6c7086"; font.pixelSize: 10 }
          }
        }
      }

      RowLayout {
        Layout.columnSpan: 2
        Layout.fillWidth: true
        spacing: 10

        Text { text: "󰕒"; color: "#a6e3a1"; font.pixelSize: 16; font.family: "monospace" }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: 2

          Text { text: "Upload"; color: "#a6e3a1"; font.pixelSize: 11; font.bold: true }

          RowLayout {
            spacing: 8
            Text { text: networkWidget.txRate; color: "#cdd6f4"; font.pixelSize: 12; font.bold: true }
            Text { text: "(" + networkWidget.txTotal + " total)"; color: "#6c7086"; font.pixelSize: 10 }
          }
        }
      }
    }
  ]

  Component.onCompleted: {
    networkProc.running = true
  }
}
