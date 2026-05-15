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

  // Bluetooth summary (one connected device, else first paired, else state)
  property string btPower: "off"
  property string btDeviceMac: ""
  property string btDeviceName: ""
  property bool btDeviceConnected: false
  property string btDeviceBattery: "NA"

  // Days since last `pacman -Syu` ("NA" if unknown)
  property string daysSinceUpgrade: "NA"

  Process {
    id: systemProc
    command: ["bash", root.home + "/.config/scripts/polls/systempoll.sh"]
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

  Process {
    id: btProc
    command: ["bash", root.home + "/.config/scripts/polls/bluetoothpoll.sh"]
    running: true

    stdout: StdioCollector {
      onStreamFinished: {
        let lines = this.text.trim().split('\n').filter(l => l.trim())
        let pwr = "off"
        let pickMac = ""
        let pickName = ""
        let pickConnected = false
        let pickBattery = "NA"
        for (let i = 0; i < lines.length; i++) {
          let parts = lines[i].split('|')
          if (parts[0] === "power") {
            pwr = parts[1]
          } else if (parts[0] === "device" && parts.length >= 6) {
            let connected = parts[3] === "1"
            // Prefer first connected; otherwise fall back to first paired.
            if (connected && !pickConnected) {
              pickMac = parts[1]
              pickName = parts[2]
              pickConnected = true
              pickBattery = parts[4]
            } else if (!pickConnected && pickName === "") {
              pickMac = parts[1]
              pickName = parts[2]
              pickBattery = parts[4]
            }
          }
        }
        systemWidget.btPower = pwr
        systemWidget.btDeviceMac = pickMac
        systemWidget.btDeviceName = pickName
        systemWidget.btDeviceConnected = pickConnected
        systemWidget.btDeviceBattery = pickBattery
      }
    }
  }

  Timer {
    interval: 5000
    running: true
    repeat: true
    onTriggered: btProc.running = true
  }

  Process {
    id: btToggleProc
    property string mac: ""
    property bool doConnect: false
    command: ["bluetoothctl", doConnect ? "connect" : "disconnect", mac]
    onExited: btProc.running = true
  }

  Process {
    id: updatesProc
    command: ["bash", root.home + "/.config/scripts/polls/updatespoll.sh"]
    running: true

    stdout: StdioCollector {
      onStreamFinished: {
        systemWidget.daysSinceUpgrade = this.text.trim() || "NA"
      }
    }
  }

  Timer {
    interval: 300000
    running: true
    repeat: true
    onTriggered: updatesProc.running = true
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

      // Bluetooth status row
      Rectangle {
        Layout.fillWidth: true
        implicitHeight: btRow.implicitHeight
        color: "transparent"

        RowLayout {
          id: btRow
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: 10

          Rectangle {
            width: 10; height: 10; radius: 5
            color: systemWidget.btPower === "unavailable" ? "#f38ba8"
                 : systemWidget.btDeviceConnected ? "#a6e3a1"
                 : systemWidget.btPower === "on" ? "#89b4fa"
                 : "#6c7086"
            Behavior on color { ColorAnimation { duration: 200 } }
          }

          Text {
            text: "󰂯 Bluetooth"
            color: "#cdd6f4"
            font.pixelSize: 13
            font.bold: true
            font.family: "monospace"
            Layout.fillWidth: true
          }

          Text {
            text: {
              if (systemWidget.btPower === "unavailable") return "unavailable"
              if (systemWidget.btPower === "off") return "off"
              if (!systemWidget.btDeviceName) return "ready"
              let s = systemWidget.btDeviceName
              if (systemWidget.btDeviceConnected) {
                if (systemWidget.btDeviceBattery !== "NA") {
                  s += " · " + systemWidget.btDeviceBattery + "%"
                }
              } else {
                s += " (paired)"
              }
              return s
            }
            color: systemWidget.btPower === "unavailable" ? "#f38ba8"
                 : systemWidget.btDeviceConnected ? "#a6e3a1"
                 : systemWidget.btPower === "on" ? "#89b4fa"
                 : "#6c7086"
            font.pixelSize: 13
            font.italic: true
            font.family: "monospace"

            Behavior on color { ColorAnimation { duration: 200 } }
          }
        }

        MouseArea {
          anchors.fill: parent
          enabled: systemWidget.btPower === "on" && systemWidget.btDeviceMac !== ""
          hoverEnabled: enabled
          acceptedButtons: Qt.LeftButton
          cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: {
            btToggleProc.mac = systemWidget.btDeviceMac
            btToggleProc.doConnect = !systemWidget.btDeviceConnected
            btToggleProc.running = true
          }
        }
      }

      // Last upgrade row (days since `pacman -Syu`)
      RowLayout {
        Layout.fillWidth: true
        spacing: 10

        Rectangle {
          width: 10; height: 10; radius: 5
          color: {
            let d = parseInt(systemWidget.daysSinceUpgrade)
            if (isNaN(d)) return "#6c7086"
            if (d <= 7) return "#a6e3a1"
            if (d <= 30) return "#f9e2af"
            return "#f38ba8"
          }
          Behavior on color { ColorAnimation { duration: 200 } }
        }

        Text {
          text: "󰚰 Last Upgrade"
          color: "#cdd6f4"
          font.pixelSize: 13
          font.bold: true
          font.family: "monospace"
          Layout.fillWidth: true
        }

        Text {
          text: {
            let d = parseInt(systemWidget.daysSinceUpgrade)
            if (isNaN(d)) return "unknown"
            if (d === 0) return "today"
            if (d === 1) return "1 day ago"
            return d + " days ago"
          }
          color: {
            let d = parseInt(systemWidget.daysSinceUpgrade)
            if (isNaN(d)) return "#6c7086"
            if (d <= 7) return "#a6e3a1"
            if (d <= 30) return "#f9e2af"
            return "#f38ba8"
          }
          font.pixelSize: 13
          font.italic: true
          font.family: "monospace"

          Behavior on color { ColorAnimation { duration: 200 } }
        }
      }
    }
  ]

  Component.onCompleted: {
    systemProc.running = true
    btProc.running = true
    updatesProc.running = true
  }
}
