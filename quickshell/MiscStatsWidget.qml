import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "templates"
import "themes"

DataWidget {
  id: miscWidget

  title: "󰌢  System Info"
  refHeight: 250   // 1.5 rows in the default preset

  property string uptime: "..."
  property string loadAvg: "..."
  property int processCount: 0
  property string kernel: "..."
  property int userCount: 0
  property int packageCount: 0

  PollProcess {
    id: pkgProc
    command: ["bash", "-c", "pacman -Q 2>/dev/null | wc -l"]
    interval: 30000
    onOutput: text => miscWidget.packageCount = parseInt(text) || 0
  }

  PollProcess {
    id: miscProc
    command: ["bash", root.home + "/.config/scripts/polls/miscstatspoll.sh"]
    interval: 30000
    onOutput: text => {
      let parts = text.split('|')
      if (parts.length === 5) {
        miscWidget.uptime = parts[0]
        miscWidget.loadAvg = parts[1]
        miscWidget.processCount = parseInt(parts[2])
        miscWidget.kernel = parts[3]
        miscWidget.userCount = parseInt(parts[4])
      }
    }
  }

  // Rows in display order; the ones at the end are dropped when the card is
  // too short for all of them, and labels shrink to their icon when narrow.
  readonly property var rows: [
    { icon: "󰥔", label: "Uptime",    color: Theme.colors.yellow,   value: uptime },
    { icon: "󰓅", label: "Load Avg",  color: Theme.colors.orange,   value: loadAvg },
    { icon: "󰐾", label: "Processes", color: Theme.colors.teal,     value: processCount.toString() },
    { icon: "󰒓", label: "Kernel",    color: Theme.colors.lavender, value: kernel },
    { icon: "󰀄", label: "Users",     color: Theme.colors.violet,   value: userCount.toString() },
    { icon: "󰏖", label: "Packages",  color: Theme.colors.pink,     value: packageCount.toString() }
  ]
  readonly property real rowSpacing: fs(metrics.spacingSmall)
  readonly property real rowPitch: Math.ceil(fs(metrics.fontSmall) * 1.35) + rowSpacing
  readonly property int rowsShown: Math.max(2, Math.min(rows.length, Math.floor((dataHeight + rowSpacing) / rowPitch)))
  readonly property bool iconOnly: width < metrics.s(230)

  dataContent: [
    GridLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      columns: 2
      columnSpacing: miscWidget.fs(metrics.spacingNormal)
      rowSpacing: miscWidget.rowSpacing

      Repeater {
        model: miscWidget.rowsShown
        Text {
          required property int index
          readonly property var row: miscWidget.rows[index]
          Layout.row: index; Layout.column: 0
          text: miscWidget.iconOnly ? row.icon : row.icon + " " + row.label
          color: row.color; font.pixelSize: miscWidget.fs(metrics.fontSmall); font.family: Theme.fonts.mono
          font.capitalization: Font.AllUppercase; font.letterSpacing: miscWidget.compact ? 0 : 1
        }
      }
      Repeater {
        model: miscWidget.rowsShown
        Text {
          required property int index
          readonly property var row: miscWidget.rows[index]
          Layout.row: index; Layout.column: 1
          font.family: Theme.fonts.mono; font.features: { "tnum": 1, "lnum": 1 }; text: row.value; color: Theme.colors.textPrimary; font.pixelSize: miscWidget.fs(metrics.fontTiny)
          Layout.fillWidth: true; elide: Text.ElideRight; wrapMode: Text.NoWrap
        }
      }
    }
  ]
}
