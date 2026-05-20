import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "templates"

ThreeRowWidget {
  id: servicesWidget

  title: "󰒍  Services"

  // Press-and-hold duration for the unlock gesture; the MouseArea and the
  // cross-fade animation both read from this so they can't drift apart.
  readonly property int holdMs: 1000

  readonly property string tessieCmdScript: root.home + "/.config/scripts/polls/tessiecmd.sh"

  // Tailscale state
  property var devices: []

  // Tessie / car state
  property string carStatus: "loading"   // "ok" | "error" | "loading"
  property string carError: ""
  property string carName: "Car"
  property string carState: "unknown"    // "online" | "asleep" | "offline" | ...
  property int    carBattery: 0
  property int    carRange: 0
  property string carCharging: "Unknown"
  property bool   carLocked: false
  property bool   carClimateOn: false
  property real   carTemp: 0
  property int    carChargePower: 0    // kW, only meaningful while charging

  readonly property bool carOk:      carStatus === "ok"
  readonly property bool isCharging: carCharging === "Charging"

  // After a successful command, the Tessie cache takes ~10–30s to reflect
  // the change. During that window we trust the optimistic state and ignore
  // poll updates for the affected field — otherwise the icon would flicker
  // back to the stale cached value before settling.
  property bool climateUpdateSuppressed: false
  property bool lockUpdateSuppressed:    false

  Timer { id: climateSuppressTimer; interval: 30000; onTriggered: servicesWidget.climateUpdateSuppressed = false }
  Timer { id: lockSuppressTimer;    interval: 30000; onTriggered: servicesWidget.lockUpdateSuppressed    = false }

  // Handle the stdout of a tessiecmd.sh invocation. "ok" → command succeeded;
  // suppress poll overrides on that field for a while. Anything else → revert
  // the optimistic state via an immediate re-poll, and log the reason.
  function handleCmdResult(text, kind) {
    let out = text.trim()
    if (out === "ok") {
      if (kind === "climate") { climateUpdateSuppressed = true; climateSuppressTimer.restart() }
      else if (kind === "lock") { lockUpdateSuppressed = true; lockSuppressTimer.restart() }
    } else {
      console.warn("Tessie", kind, "command failed:", out)
      tessieProc.running = true
    }
  }

  Process {
    id: tailscaleProc
    command: ["bash", root.home + "/.config/scripts/polls/tailscalepoll.sh"]
    running: true

    stdout: StdioCollector {
      onStreamFinished: {
        let deviceList = []
        for (let line of this.text.trim().split('\n')) {
          if (!line.trim()) continue
          let parts = line.split('|')
          if (parts.length === 3) {
            deviceList.push({ name: parts[0], status: parts[1], ping: parts[2] })
          }
        }
        servicesWidget.devices = deviceList
      }
    }
  }

  Timer {
    interval: 10000; running: true; repeat: true
    onTriggered: tailscaleProc.running = true
  }

  Process {
    id: tessieProc
    command: ["bash", root.home + "/.config/scripts/polls/tessiepoll.sh"]
    running: true

    stdout: StdioCollector {
      onStreamFinished: {
        let parts = this.text.trim().split('|')

        if (parts[0] === "ok" && parts.length >= 10) {
          servicesWidget.carStatus      = "ok"
          servicesWidget.carError       = ""
          servicesWidget.carState       = parts[1]
          servicesWidget.carBattery     = parseInt(parts[2])
          servicesWidget.carRange       = parseInt(parts[3])
          servicesWidget.carCharging    = parts[4]
          if (!servicesWidget.lockUpdateSuppressed)    servicesWidget.carLocked    = parts[5] === "true"
          if (!servicesWidget.climateUpdateSuppressed) servicesWidget.carClimateOn = parts[6] === "true"
          servicesWidget.carTemp        = parseFloat(parts[7])
          servicesWidget.carName        = parts[8] || "Car"
          servicesWidget.carChargePower = parseInt(parts[9])
        } else {
          servicesWidget.carStatus = "error"
          servicesWidget.carError  = parts[1] || "unknown error"
        }
      }
    }
  }

  Timer {
    interval: 30000; running: true; repeat: true
    onTriggered: tessieProc.running = true
  }

  // Action processes. Optimistic updates happen in the click handlers; the
  // suppression flags above keep poll updates from clobbering them while the
  // Tessie cache settles. Failure is handled by handleCmdResult — see above.
  Process {
    id: lockCmdProc
    command: ["bash", servicesWidget.tessieCmdScript, "lock"]
    running: false
    stdout: StdioCollector { onStreamFinished: servicesWidget.handleCmdResult(this.text, "lock") }
  }

  Process {
    id: unlockCmdProc
    command: ["bash", servicesWidget.tessieCmdScript, "unlock"]
    running: false
    stdout: StdioCollector { onStreamFinished: servicesWidget.handleCmdResult(this.text, "lock") }
  }

  Process {
    id: climateOnCmdProc
    command: ["bash", servicesWidget.tessieCmdScript, "start_climate"]
    running: false
    stdout: StdioCollector { onStreamFinished: servicesWidget.handleCmdResult(this.text, "climate") }
  }

  Process {
    id: climateOffCmdProc
    command: ["bash", servicesWidget.tessieCmdScript, "stop_climate"]
    running: false
    stdout: StdioCollector { onStreamFinished: servicesWidget.handleCmdResult(this.text, "climate") }
  }

  middleContent: Component {
    ColumnLayout {
      spacing: 6

      Text {
        text: "󰛳  Tailscale"
        color: "#a6adc8"
        font.pixelSize: 12
        font.bold: true
        font.family: "monospace"
        Layout.fillWidth: true
      }

      Repeater {
        model: servicesWidget.devices

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
              let pingValue = parseInt(modelData.ping)
              if (pingValue < 30)  return "#a6e3a1"
              if (pingValue < 100) return "#f9e2af"
              return "#f38ba8"
            }
            font.pixelSize: 12
          }
        }
      }

      Text {
        visible: servicesWidget.devices.length === 0
        text: "Loading devices..."
        color: "#6c7086"
        font.pixelSize: 13
        font.italic: true
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignHCenter
      }
    }
  }

  footerContent: Component {
    RowLayout {
      spacing: 8

      // Status dot
      Rectangle {
        Layout.alignment: Qt.AlignVCenter
        Layout.rightMargin: 2
        width: 10; height: 10; radius: 5
        color: {
          if (!servicesWidget.carOk)                return "#6c7086"
          if (servicesWidget.carState === "online") return "#a6e3a1"
          if (servicesWidget.carState === "asleep") return "#f9e2af"
          return "#f38ba8"
        }
        Behavior on color { ColorAnimation { duration: 150 } }
      }

      // Name
      Text {
        text: "󰄋  " + servicesWidget.carName
        color: "#cdd6f4"
        font.pixelSize: 14
        font.bold: true
        font.family: "monospace"
      }

      // Error / loading message — fills middle when shown
      Text {
        visible: !servicesWidget.carOk
        text: servicesWidget.carStatus === "loading" ? "loading..." : servicesWidget.carError
        color: "#6c7086"
        font.pixelSize: 12
        font.italic: true
        Layout.leftMargin: 4
        Layout.fillWidth: true
      }

      // Battery (+ live charge rate when charging)
      Text {
        visible: servicesWidget.carOk
        Layout.leftMargin: 4
        text: {
          let icon = servicesWidget.isCharging ? "󰂄  " : "󰁹  "
          let rate = (servicesWidget.isCharging && servicesWidget.carChargePower > 0)
                     ? " · " + servicesWidget.carChargePower + " kW" : ""
          return icon + servicesWidget.carBattery + "%" + rate
        }
        color: {
          if (servicesWidget.isCharging)      return "#a6e3a1"
          if (servicesWidget.carBattery > 50) return "#a6e3a1"
          if (servicesWidget.carBattery > 20) return "#f9e2af"
          return "#f38ba8"
        }
        font.pixelSize: 13
        font.bold: true
        font.family: "monospace"
      }

      // Range
      Text {
        visible: servicesWidget.carOk
        text: servicesWidget.carRange + " mi"
        color: "#a6adc8"
        font.pixelSize: 12
      }

      Item { visible: servicesWidget.carOk; Layout.fillWidth: true }

      // Cabin temp
      Text {
        visible: servicesWidget.carOk
        text: servicesWidget.carTemp.toFixed(0) + "°C"
        color: "#a6adc8"
        font.pixelSize: 12
        font.family: "monospace"
      }

      // Climate toggle — single click to toggle on/off
      Item {
        id: climateButton
        visible: servicesWidget.carOk
        implicitWidth: 22
        implicitHeight: 20

        opacity: climateArea.pressed ? 0.6 : (climateArea.containsMouse ? 0.85 : 1.0)
        Behavior on opacity { NumberAnimation { duration: 100 } }

        Text {
          anchors.centerIn: parent
          text: "󰈐"
          color: servicesWidget.carClimateOn ? "#89b4fa" : "#6c7086"
          font.pixelSize: 14
          font.family: "monospace"
          Behavior on color { ColorAnimation { duration: 150 } }

          RotationAnimator on rotation {
            running: servicesWidget.carClimateOn
            loops: Animation.Infinite
            from: 0; to: 360
            duration: 2000
          }
        }

        MouseArea {
          id: climateArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor

          onClicked: {
            let turningOn = !servicesWidget.carClimateOn
            servicesWidget.carClimateOn = turningOn   // optimistic
            (turningOn ? climateOnCmdProc : climateOffCmdProc).running = true
          }
        }
      }

      // Lock toggle — click to lock, press-and-hold to unlock.
      // While unlocking, the locked icon cross-fades into the unlocked icon.
      Item {
        id: lockButton
        visible: servicesWidget.carOk
        implicitWidth: 22
        implicitHeight: 20

        opacity: lockArea.pressed ? 0.6 : (lockArea.containsMouse ? 0.85 : 1.0)
        Behavior on opacity { NumberAnimation { duration: 100 } }

        // 0 idle, 1 at full hold. Drives the cross-fade.
        property real holdProgress: 0

        Behavior on holdProgress {
          enabled: !holdAnim.running
          NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
        }

        Text {
          anchors.centerIn: parent
          text: "󰌾"
          color: "#a6e3a1"
          font.pixelSize: 14
          font.family: "monospace"
          visible: servicesWidget.carLocked
          opacity: 1.0 - lockButton.holdProgress
        }

        Text {
          anchors.centerIn: parent
          text: "󰿆"
          color: "#f38ba8"
          font.pixelSize: 14
          font.family: "monospace"
          opacity: servicesWidget.carLocked ? lockButton.holdProgress : 1.0
          visible: opacity > 0
        }

        NumberAnimation {
          id: holdAnim
          target: lockButton
          property: "holdProgress"
          from: 0; to: 1
          duration: servicesWidget.holdMs
        }

        MouseArea {
          id: lockArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          pressAndHoldInterval: servicesWidget.holdMs

          property bool holdFired: false

          onPressed: {
            holdFired = false
            if (servicesWidget.carLocked) holdAnim.restart()
          }

          onReleased: {
            holdAnim.stop()
            lockButton.holdProgress = 0
          }

          onPressAndHold: {
            if (servicesWidget.carLocked) {
              holdFired = true
              servicesWidget.carLocked = false   // optimistic
              unlockCmdProc.running = true
            }
          }

          onClicked: {
            if (holdFired) return
            if (!servicesWidget.carLocked) {
              servicesWidget.carLocked = true    // optimistic
              lockCmdProc.running = true
            }
          }
        }
      }
    }
  }
}
