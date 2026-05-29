import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "templates"
import "themes"

DataWidget {
  id: networkWidget

  title: "󰖟  Network (" + interfaceName + ")"

  property string interfaceName: "..."
  property string rxTotal: "0B"
  property string txTotal: "0B"
  property string rxRate: "0B/s"
  property string txRate: "0B/s"

  PollProcess {
    id: networkProc
    command: ["bash", root.home + "/.config/scripts/polls/networkpoll.sh"]
    interval: 2000
    onOutput: text => {
      let parts = text.split('|')
      if (parts.length === 5) {
        networkWidget.interfaceName = parts[0]
        networkWidget.rxTotal = parts[1]
        networkWidget.txTotal = parts[2]
        networkWidget.rxRate = parts[3]
        networkWidget.txRate = parts[4]
      }
    }
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

        Text { text: "󰇚"; color: Theme.colors.cyan; font.pixelSize: 16; font.family: "monospace" }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: 2

          Text { text: "Download"; color: Theme.colors.cyan; font.pixelSize: 11; font.bold: true }

          RowLayout {
            spacing: 8
            Text { text: networkWidget.rxRate; color: Theme.colors.textPrimary; font.pixelSize: 12; font.bold: true }
            Text { text: "(" + networkWidget.rxTotal + " total)"; color: Theme.colors.textMuted; font.pixelSize: 10 }
          }
        }
      }

      RowLayout {
        Layout.columnSpan: 2
        Layout.fillWidth: true
        spacing: 10

        Text { text: "󰕒"; color: Theme.colors.green; font.pixelSize: 16; font.family: "monospace" }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: 2

          Text { text: "Upload"; color: Theme.colors.green; font.pixelSize: 11; font.bold: true }

          RowLayout {
            spacing: 8
            Text { text: networkWidget.txRate; color: Theme.colors.textPrimary; font.pixelSize: 12; font.bold: true }
            Text { text: "(" + networkWidget.txTotal + " total)"; color: Theme.colors.textMuted; font.pixelSize: 10 }
          }
        }
      }
    }
  ]
}
