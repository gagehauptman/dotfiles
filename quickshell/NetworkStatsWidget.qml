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

  // Rate history for the scope trace (rx up, tx mirrored down), bytes/s
  property var rxHistory: []
  property var txHistory: []
  // "12.3MiB/s" -> bytes/s
  function bytes(str) {
    let m = /^\s*([\d.]+)\s*([KMGT]?)/.exec(str || "")
    if (!m) return 0
    return parseFloat(m[1]) * Math.pow(1024, " KMGT".indexOf(m[2] || " ") || 0)
  }
  function human(b) {
    let u = ["B", "KiB", "MiB", "GiB"], i = 0
    while (b >= 1024 && i < u.length - 1) { b /= 1024; i++ }
    return (i === 0 ? Math.round(b) : b.toFixed(1)) + u[i] + "/s"
  }

  dataFills: true

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
        let n = Dash.traceSamples
        networkWidget.rxHistory = networkWidget.rxHistory.concat([networkWidget.bytes(parts[3])]).slice(-n)
        networkWidget.txHistory = networkWidget.txHistory.concat([networkWidget.bytes(parts[4])]).slice(-n)
        if (typeof dashState !== "undefined")
          dashState.report("net", "NET", "network", parts[0] === "N/A" ? Status.caution : Status.nominal, parts[0] === "N/A" ? "NO ROUTE" : "", 8000)
      }
    }
  }

  dataContent: [
    ColumnLayout {
    anchors.fill: parent
    spacing: networkWidget.fs(metrics.spacingSmall)
    GridLayout {
      Layout.fillWidth: true
      columns: 2
      columnSpacing: metrics.s(20)
      rowSpacing: networkWidget.fs(networkWidget.compact ? metrics.spacingSmall : metrics.s(12))

      RowLayout {
        Layout.columnSpan: 2
        Layout.fillWidth: true
        spacing: metrics.spacingNormal

        Text { text: "󰇚"; color: Theme.colors.cyan; font.pixelSize: networkWidget.fs(metrics.fontLarge); font.family: Theme.fonts.mono }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: metrics.spacingTiny

          // The label is the first thing dropped when the card is squished
          Text { visible: !networkWidget.compact; font.family: Theme.fonts.mono; font.capitalization: Font.AllUppercase; font.letterSpacing: 1; text: "Download"; color: Theme.colors.cyan; font.pixelSize: networkWidget.fs(metrics.fontTiny) }

          RowLayout {
            Layout.fillWidth: true
            spacing: metrics.spacingSmall
            Readout { text: networkWidget.rxRate; pixelSize: networkWidget.fs(metrics.fontSmall); bold: true }
            Text { visible: networkWidget.width >= metrics.s(230); Layout.fillWidth: true; elide: Text.ElideRight; font.family: Theme.fonts.mono; font.features: { "tnum": 1 }; text: "(" + networkWidget.rxTotal + " total)"; color: Theme.colors.textMuted; font.pixelSize: networkWidget.fs(metrics.fontTiny) }
          }
        }
      }

      RowLayout {
        Layout.columnSpan: 2
        Layout.fillWidth: true
        spacing: metrics.spacingNormal

        Text { text: "󰕒"; color: Theme.colors.green; font.pixelSize: networkWidget.fs(metrics.fontLarge); font.family: Theme.fonts.mono }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: metrics.spacingTiny

          Text { visible: !networkWidget.compact; font.family: Theme.fonts.mono; font.capitalization: Font.AllUppercase; font.letterSpacing: 1; text: "Upload"; color: Theme.colors.green; font.pixelSize: networkWidget.fs(metrics.fontTiny) }

          RowLayout {
            Layout.fillWidth: true
            spacing: metrics.spacingSmall
            Readout { text: networkWidget.txRate; pixelSize: networkWidget.fs(metrics.fontSmall); bold: true }
            Text { visible: networkWidget.width >= metrics.s(230); Layout.fillWidth: true; elide: Text.ElideRight; font.family: Theme.fonts.mono; font.features: { "tnum": 1 }; text: "(" + networkWidget.txTotal + " total)"; color: Theme.colors.textMuted; font.pixelSize: networkWidget.fs(metrics.fontTiny) }
          }
        }
      }
    }
    // Scope: rx above the baseline, tx mirrored below, oldest at the left;
    // auto-scaled to the window's peak, which is stamped at the right.
    Item {
      id: scope
      // Always in the layout (so it can't size itself out); its content shows once there's room.
      readonly property bool room: Dash.tracesEnabled && height >= metrics.s(28)
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.minimumHeight: 0
      Sparkline {
        id: trace
        visible: scope.room
        anchors.fill: parent
        mirror: true
        values: networkWidget.rxHistory
        values2: networkWidget.txHistory
        floor: 4096
        color: Theme.colors.cyan
        color2: Theme.colors.green
      }
      Text {
        visible: scope.room
        anchors { left: parent.left; top: parent.top }
        text: "PK " + networkWidget.human(trace.peak)
        color: Theme.colors.textMuted
        font.pixelSize: Math.max(8, Math.round(metrics.fontTiny * 0.85))
        font.family: Theme.fonts.mono
        font.features: { "tnum": 1, "lnum": 1 }
      }
      Text {
        visible: scope.room
        anchors { left: parent.left; bottom: parent.bottom }
        text: "−" + Math.round(Dash.traceSamples * 2 / 60) + " MIN"
        color: Theme.colors.textMuted
        font.pixelSize: Math.max(8, Math.round(metrics.fontTiny * 0.85))
        font.family: Theme.fonts.mono
        font.letterSpacing: 1
      }
    }
    }
  ]
}
