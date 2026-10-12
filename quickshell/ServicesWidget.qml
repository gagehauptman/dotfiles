import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "templates"
import "themes"

ThreeRowWidget {
  id: servicesWidget

  title: "󰒍  Services"
  refWidth: 742    // two columns x 1.5 rows in the default preset
  refHeight: 250

  // Fit: Tailscale devices fill as many rows as the middle slot holds, then
  // spill into extra columns when the card is wide enough for them (column-major,
  // fewest columns that show everything). Still too many: online devices first
  // plus a "+N more" line; the header goes before any device does. Narrow
  // cards drop the status words and, in the car row, range and cabin temperature.
  readonly property bool narrow: width < metrics.s(480)
  readonly property real rowGap: fs(metrics.spacingSmall)
  readonly property real rowH: Math.ceil(fs(metrics.fontNormal) * 1.35)
  readonly property int rowSlots: Math.max(1, Math.floor((middleHeight + rowGap) / (rowH + rowGap)))
  // Columns: as many cells of at least minCellW as fit, capped by what's needed.
  readonly property real colGap: fs(metrics.spacingLarge)
  readonly property real minCellW: Math.round(metrics.s(190) * k)
  readonly property real middleWidth: width - 2 * pad
  readonly property int maxCols: Math.max(1, Math.min(devices.length,
    Math.floor((middleWidth + colGap) / (minCellW + colGap))))
  readonly property int tsCols: Math.max(1, Math.min(maxCols, Math.ceil(devices.length / rowSlots)))
  readonly property real cellW: Math.floor((middleWidth - (tsCols - 1) * colGap) / tsCols)
  readonly property int rowsNeeded: Math.ceil(devices.length / tsCols)
  readonly property bool showTsHeader: rowSlots > rowsNeeded
  readonly property bool devicesCut: rowSlots < rowsNeeded
  readonly property int gridRows: devicesCut ? Math.max(1, rowSlots - 1) : Math.max(1, rowsNeeded)
  readonly property var shownDevices: devicesCut
    ? devices.slice().sort((a, b) => (b.status === "online") - (a.status === "online")).slice(0, tsCols * gridRows)
    : devices
  // Status words: one column keeps the card-width rule; multi-column cells
  // show them only when each cell is roomy.
  readonly property bool showStatusWord: tsCols === 1 ? !narrow : cellW >= Math.round(metrics.s(250) * k)

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

  // Mission strip subsystems. LINK: worst ping among online peers (offline
  // peers are normal, not a fault). CAR: battery level, or the API failing.
  function reportLink() {
    if (typeof dashState === "undefined") return
    let worst = 0, detail = ""
    for (let d of devices) {
      if (d.status !== "online") continue
      let l = Status.level("ping", parseInt(d.ping))
      if (l > worst) { worst = l; detail = d.name + " " + d.ping }
    }
    dashState.report("link", "LINK", "services", worst, detail, 35000)
  }
  function reportCar() {
    if (typeof dashState === "undefined") return
    let l = !carOk ? Status.advisory : carBattery <= 10 ? Status.warning : carBattery <= 20 ? Status.caution : Status.nominal
    dashState.report("car", "CAR", "services", l, !carOk ? "CAR " + carError.toUpperCase().slice(0, 24) : "CAR " + carBattery + "%", 35000)
  }

  PollProcess {
    id: tailscaleProc
    command: ["bash", root.home + "/.config/scripts/polls/tailscalepoll.sh"]
    interval: 10000
    onOutput: text => {
      let deviceList = []
      for (let line of text.split('\n')) {
        if (!line.trim()) continue
        let parts = line.split('|')
        if (parts.length === 3) {
          deviceList.push({ name: parts[0], status: parts[1], ping: parts[2] })
        }
      }
      servicesWidget.devices = deviceList
      servicesWidget.reportLink()
    }
  }

  PollProcess {
    id: tessieProc
    command: ["bash", root.home + "/.config/scripts/polls/tessiepoll.sh"]
    interval: 10000
    onOutput: text => {
      let parts = text.split('|')

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
      servicesWidget.reportCar()
    }
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
      spacing: servicesWidget.rowGap

      Text {
        visible: servicesWidget.showTsHeader || servicesWidget.devices.length === 0
        text: "󰛳  Tailscale"
        color: Theme.colors.textSecondary
        font.pixelSize: servicesWidget.fs(metrics.fontSmall)
        font.bold: true
        font.family: Theme.fonts.mono
        Layout.fillWidth: true
      }

      GridLayout {
        Layout.fillWidth: true
        flow: GridLayout.TopToBottom
        rows: servicesWidget.gridRows
        rowSpacing: servicesWidget.rowGap
        columnSpacing: servicesWidget.colGap

        Repeater {
          model: servicesWidget.shownDevices

          RowLayout {
            Layout.preferredWidth: servicesWidget.cellW
            Layout.maximumWidth: servicesWidget.cellW
            Layout.minimumWidth: 0
            spacing: metrics.spacingNormal

            Rectangle {
              width: metrics.s(10); height: metrics.s(10); radius: metrics.s(5)
              color: modelData.status === "online" ? Theme.colors.green : Theme.colors.red
            }

            Text {
              font.family: Theme.fonts.ui
              text: modelData.name
              color: Theme.colors.textPrimary
              font.pixelSize: servicesWidget.fs(metrics.fontNormal)
              font.bold: true
              Layout.fillWidth: true
              elide: Text.ElideRight
            }

            Text {
              font.family: Theme.fonts.ui
              visible: servicesWidget.showStatusWord
              text: modelData.status
              color: Theme.colors.textMuted
              font.pixelSize: servicesWidget.fs(metrics.fontSmall)
              font.italic: true
            }

            Text {
              font.family: Theme.fonts.mono
              font.features: { "tnum": 1, "lnum": 1 }
              visible: modelData.ping !== "N/A"
              text: "(" + modelData.ping + ")"
              color: {
                let l = Status.level("ping", parseInt(modelData.ping))
                return l === Status.nominal ? Theme.colors.textSecondary : Status.color(l)
              }
              font.pixelSize: servicesWidget.fs(metrics.fontSmall)
            }
          }
        }
      }

      Text {
        font.family: Theme.fonts.ui
        visible: servicesWidget.devicesCut
        text: "+" + (servicesWidget.devices.length - servicesWidget.shownDevices.length) + " more"
        color: Theme.colors.textMuted
        font.pixelSize: servicesWidget.fs(metrics.fontSmall)
        font.italic: true
        Layout.fillWidth: true
      }

      Text {
        font.family: Theme.fonts.ui
        visible: servicesWidget.devices.length === 0
        text: "Loading devices..."
        color: Theme.colors.textMuted
        font.pixelSize: servicesWidget.fs(metrics.fontSmall)
        font.italic: true
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignHCenter
      }
    }
  }

  footerContent: Component {
    RowLayout {
      spacing: metrics.spacingSmall

      // Status dot
      Rectangle {
        Layout.alignment: Qt.AlignVCenter
        Layout.rightMargin: metrics.s(2)
        width: metrics.s(10); height: metrics.s(10); radius: metrics.s(5)
        color: {
          if (!servicesWidget.carOk)                return Theme.colors.textMuted
          if (servicesWidget.carState === "online") return Theme.colors.green
          if (servicesWidget.carState === "asleep") return Theme.colors.yellow
          return Theme.colors.red
        }
        Behavior on color { enabled: !Theme.fading; ColorAnimation { duration: 150 } }
      }

      // Name
      Text {
        text: servicesWidget.width < metrics.s(300) ? "󰄋" : "󰄋  " + servicesWidget.carName
        color: Theme.colors.textPrimary
        font.pixelSize: servicesWidget.fs(metrics.fontNormal)
        font.bold: true
        font.family: Theme.fonts.mono
        elide: Text.ElideRight
      }

      // Error / loading message — fills middle when shown
      Text {
        font.family: Theme.fonts.ui
        visible: !servicesWidget.carOk
        text: servicesWidget.carStatus === "loading" ? "loading..." : servicesWidget.carError
        color: Theme.colors.textMuted
        font.pixelSize: servicesWidget.fs(metrics.fontSmall)
        font.italic: true
        Layout.leftMargin: metrics.s(4)
        Layout.fillWidth: true
        elide: Text.ElideRight
      }

      // Battery (+ live charge rate when charging)
      Text {
        visible: servicesWidget.carOk
        Layout.leftMargin: metrics.s(4)
        text: {
          let icon = servicesWidget.isCharging ? "󰂄  " : "󰁹  "
          let rate = (servicesWidget.isCharging && servicesWidget.carChargePower > 0 && !servicesWidget.narrow)
                     ? " · " + servicesWidget.carChargePower + " kW" : ""
          return icon + servicesWidget.carBattery + "%" + rate
        }
        color: {
          if (servicesWidget.isCharging)      return Theme.colors.green
          if (servicesWidget.carBattery > 20) return Theme.colors.textPrimary
          if (servicesWidget.carBattery > 10) return Theme.colors.yellow
          return Theme.colors.red
        }
        font.pixelSize: servicesWidget.fs(metrics.fontSmall)
        font.bold: true
        font.family: Theme.fonts.mono
      }

      // Range
      Text {
        font.family: Theme.fonts.ui
        visible: servicesWidget.carOk && !servicesWidget.narrow
        text: servicesWidget.carRange + " mi"
        color: Theme.colors.textSecondary
        font.pixelSize: servicesWidget.fs(metrics.fontSmall)
      }

      Item { visible: servicesWidget.carOk; Layout.fillWidth: true }

      // Cabin temp
      Text {
        visible: servicesWidget.carOk && !servicesWidget.narrow
        text: servicesWidget.carTemp.toFixed(0) + "°C"
        color: Theme.colors.textSecondary
        font.pixelSize: servicesWidget.fs(metrics.fontSmall)
        font.family: Theme.fonts.mono
      }

      // Climate toggle — single click to toggle on/off
      Item {
        id: climateButton
        visible: servicesWidget.carOk
        implicitWidth: servicesWidget.fs(metrics.s(22))
        implicitHeight: servicesWidget.fs(metrics.s(20))

        opacity: climateArea.pressed ? 0.6 : (climateArea.containsMouse ? 0.85 : 1.0)
        Behavior on opacity { NumberAnimation { duration: 100 } }

        Text {
          anchors.centerIn: parent
          text: "󰈐"
          color: servicesWidget.carClimateOn ? Theme.colors.blue : Theme.colors.textMuted
          font.pixelSize: servicesWidget.fs(metrics.fontNormal)
          font.family: Theme.fonts.mono
          Behavior on color { enabled: !Theme.fading; ColorAnimation { duration: 150 } }

          RotationAnimator on rotation {
            // only while the card is on screen: a running animator keeps the render
            // thread drawing frames at the monitor's refresh rate even when its item is
            // hidden (dashboard closed, other tab), so an idle bar would spin the GPU
            // for a fan nobody sees (2026-10-10)
            running: servicesWidget.carClimateOn && servicesWidget.visible
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
            servicesWidget.carClimateOn = turningOn
            if (turningOn) climateOnCmdProc.running = true
            else climateOffCmdProc.running = true
          }
        }
      }

      // Lock toggle — click to lock, press-and-hold to unlock.
      // While unlocking, the locked icon cross-fades into the unlocked icon.
      Item {
        id: lockButton
        visible: servicesWidget.carOk
        implicitWidth: servicesWidget.fs(metrics.s(22))
        implicitHeight: servicesWidget.fs(metrics.s(20))

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
          color: Theme.colors.textSecondary
          font.pixelSize: servicesWidget.fs(metrics.fontNormal)
          font.family: Theme.fonts.mono
          visible: servicesWidget.carLocked
          opacity: 1.0 - lockButton.holdProgress
        }

        Text {
          anchors.centerIn: parent
          text: "󰿆"
          color: Theme.colors.red
          font.pixelSize: servicesWidget.fs(metrics.fontNormal)
          font.family: Theme.fonts.mono
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
