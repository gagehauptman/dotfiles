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
      columnSpacing: metrics.s(20)
      rowSpacing: metrics.s(12)

      RowLayout {
        Layout.columnSpan: 2
        Layout.fillWidth: true
        spacing: metrics.spacingNormal

        Text { text: "󰇚"; color: Theme.colors.cyan; font.pixelSize: metrics.fontLarge; font.family: "monospace" }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: metrics.spacingTiny

          Text { text: "Download"; color: Theme.colors.cyan; font.pixelSize: metrics.fontTiny; font.bold: true }

          RowLayout {
            spacing: metrics.spacingSmall
            Text { text: networkWidget.rxRate; color: Theme.colors.textPrimary; font.pixelSize: metrics.fontSmall; font.bold: true }
            Text { text: "(" + networkWidget.rxTotal + " total)"; color: Theme.colors.textMuted; font.pixelSize: metrics.fontTiny }
          }
        }
      }

      RowLayout {
        Layout.columnSpan: 2
        Layout.fillWidth: true
        spacing: metrics.spacingNormal

        Text { text: "󰕒"; color: Theme.colors.green; font.pixelSize: metrics.fontLarge; font.family: "monospace" }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: metrics.spacingTiny

          Text { text: "Upload"; color: Theme.colors.green; font.pixelSize: metrics.fontTiny; font.bold: true }

          RowLayout {
            spacing: metrics.spacingSmall
            Text { text: networkWidget.txRate; color: Theme.colors.textPrimary; font.pixelSize: metrics.fontSmall; font.bold: true }
            Text { text: "(" + networkWidget.txTotal + " total)"; color: Theme.colors.textMuted; font.pixelSize: metrics.fontTiny }
          }
        }
      }
    }
  ]
}
