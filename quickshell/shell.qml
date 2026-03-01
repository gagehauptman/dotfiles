import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import QtQuick.Effects
import Quickshell
import Quickshell.Services.Pipewire
import Quickshell.Widgets
import Quickshell.Hyprland
import Quickshell.Wayland
import Qt.labs.folderlistmodel
import Qt5Compat.GraphicalEffects
import Quickshell.Io

Scope {
  id: root

  // === SHARED DATA (runs once, not per-screen) ===
  property string tempValue: "0"
  property string batteryPercent: "0"
  property string batteryIcon: ""
  property string cpuLoad: "0"
  property string volumePercent: "0"
  property string volumeIcon: "󰕾"
  property int lowBatteryThreshold: 15
  property bool lowBatteryWarningShown: false
  property int lowBatteryTrigger: 0

  // PipeWire volume tracking (shared)
  PwObjectTracker {
    objects: [ Pipewire.defaultAudioSink ]
  }

  Connections {
    target: Pipewire.defaultAudioSink?.audio

    function onVolumeChanged() {
      let volume = Math.round((Pipewire.defaultAudioSink?.audio.volume ?? 0) * 100)
      root.volumePercent = volume.toString()
    }

    function onMutedChanged() {
      root.volumeIcon = Pipewire.defaultAudioSink?.audio.muted ? "󰖁" : "󰕾"
    }
  }

  Component.onCompleted: {
    if (Pipewire.defaultAudioSink?.audio) {
      let volume = Math.round(Pipewire.defaultAudioSink.audio.volume * 100)
      root.volumePercent = volume.toString()
      root.volumeIcon = Pipewire.defaultAudioSink.audio.muted ? "󰖁" : "󰕾"
    }
  }

  // === POLLING PROCESSES (shared, run once) ===
  Process {
    id: tempProc
    command: ["bash", "/storage/git/dotfiles/scripts/polls/temppoll.sh"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: root.tempValue = this.text.trim()
    }
  }
  Timer { interval: 2000; running: true; repeat: true; onTriggered: tempProc.running = true }

  Process {
    id: batteryPercentProc
    command: ["bash", "/storage/git/dotfiles/scripts/polls/batterypoll1.sh"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        let newPercent = this.text.trim()
        root.batteryPercent = newPercent
        let currentPercent = parseInt(newPercent)
        if (currentPercent > root.lowBatteryThreshold + 5) {
          root.lowBatteryWarningShown = false
        }
        if (currentPercent <= root.lowBatteryThreshold && !root.lowBatteryWarningShown) {
          root.lowBatteryWarningShown = true
          root.lowBatteryTrigger++
        }
      }
    }
  }
  Timer { interval: 5000; running: true; repeat: true; onTriggered: batteryPercentProc.running = true }

  Process {
    id: batteryIconProc
    command: ["bash", "/storage/git/dotfiles/scripts/polls/batterypoll2.sh"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: root.batteryIcon = this.text.trim()
    }
  }
  Timer { interval: 5000; running: true; repeat: true; onTriggered: batteryIconProc.running = true }

  Process {
    id: cpuProc
    command: ["bash", "/storage/git/dotfiles/scripts/polls/cpupoll.sh"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: root.cpuLoad = this.text.trim()
    }
  }
  Timer { interval: 2000; running: true; repeat: true; onTriggered: cpuProc.running = true }

  // === GLOBAL SHORTCUTS (registered once) ===
  property int toggleCounter: 0
  property string toggleTarget: ""

  GlobalShortcut {
    name: "toggleDashboard"
    onPressed: { root.toggleTarget = "dashboard"; root.toggleCounter++ }
  }

  GlobalShortcut {
    name: "toggleWallpaperSelector"
    onPressed: { root.toggleTarget = "wallpaper_selector"; root.toggleCounter++ }
  }

  GlobalShortcut {
    name: "toggleAppSelector"
    onPressed: { root.toggleTarget = "app_selector"; root.toggleCounter++ }
  }

  GlobalShortcut {
    name: "togglePowerMenu"
    onPressed: { root.toggleTarget = "power_menu"; root.toggleCounter++ }
  }

  // === PER-SCREEN BAR ===
  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: barWindow
      property var modelData
      screen: modelData

      // Map QScreen -> Hyprland monitor by name
      property var hyprMonitor: {
        let monitors = Hyprland.monitors.values
        for (let i = 0; i < monitors.length; i++) {
          if (monitors[i].name === modelData.name) return monitors[i]
        }
        return null
      }
      property int monitorId: hyprMonitor?.id ?? 0
      property bool isFocused: Hyprland.focusedMonitor?.id === monitorId

      // Handle global shortcut toggles (only on focused monitor)
      Connections {
        target: root
        function onToggleCounterChanged() {
          if (barWindow.isFocused) {
            if (bar.state !== root.toggleTarget) {
              bar.state = root.toggleTarget
            } else {
              bar.state = "normal"
            }
          }
        }
      }

      // Low battery popup trigger (only on focused monitor)
      Connections {
        target: root
        function onLowBatteryTriggerChanged() {
          if (barWindow.isFocused) {
            lowBatteryPopup.show()
          }
        }
      }

      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.keyboardFocus: (bar.state === "wallpaper_selector" || bar.state === "app_selector" || bar.state === "power_menu")
            ? WlrKeyboardFocus.Exclusive 
            : WlrKeyboardFocus.None
      mask: Region {
        item: bar
      }

      anchors {
        top: true
        bottom: true
        left: true
        right: true
      }

      Item {
        id: main
        anchors.fill: parent

        // Low battery popup warning
        Rectangle {
          id: lowBatteryPopup
          visible: false
          opacity: 0
          
          width: 400
          height: 120
          radius: 20
          color: "#1e1e2e"
          border.color: "#f38ba8"
          border.width: 2
          
          anchors {
            horizontalCenter: parent.horizontalCenter
            top: parent.top
            topMargin: 80
          }
          
          layer.enabled: true
          layer.samples: 4
          
          ColumnLayout {
            anchors.centerIn: parent
            spacing: 10
            
            Text {
              text: ""
              color: "#f38ba8"
              font.pixelSize: 36
              font.family: "monospace"
              Layout.alignment: Qt.AlignHCenter
            }
            
            Text {
              text: "Low Battery Warning"
              color: "#cdd6f4"
              font.pixelSize: 16
              font.bold: true
              Layout.alignment: Qt.AlignHCenter
            }
            
            Text {
              text: "Battery at " + root.batteryPercent + "% — Please plug in charger"
              color: "#a6adc8"
              font.pixelSize: 13
              Layout.alignment: Qt.AlignHCenter
            }
          }
          
          Behavior on opacity {
            NumberAnimation { duration: 300; easing.type: Easing.OutQuad }
          }
          
          Timer {
            id: lowBatteryPopupTimer
            interval: 5000
            running: false
            repeat: false
            onTriggered: {
              lowBatteryPopup.opacity = 0
              lowBatteryPopupHideTimer.start()
            }
          }
          
          Timer {
            id: lowBatteryPopupHideTimer
            interval: 300
            running: false
            repeat: false
            onTriggered: {
              lowBatteryPopup.visible = false
            }
          }
          
          function show() {
            lowBatteryPopup.visible = true
            lowBatteryPopup.opacity = 1
            lowBatteryPopupTimer.restart()
          }
        }

        Shape {
          id: bar
          state: "normal"

          layer.enabled: true
          layer.samples: 4

          property real barHeight: 2.5 * parent.height / 100

          property real dropdownWidth: 30 * parent.width / 100
          property real dropdownHeight: 10 * parent.height / 100
          property real dropdownFilletRadius: 10
          property real dropdownCornerRadius: 25
          property int dropdownWidgetPadding: 20

          width: parent.width
          height: barHeight + dropdownHeight

          property int appSelectorCellHeightConst: 120
          property int appSelectorOffsetFromBar: 5
          property int appSelectorRowsPerPage: 5

          ShapePath {
            fillColor: "#11111b"
            strokeColor: "transparent"

            startX: 0; startY: 0
            PathLine { x: bar.width; y: 0 }
            PathLine { x: bar.width; y: bar.barHeight }
            PathLine { x: bar.dropdownWidth + (bar.width - bar.dropdownWidth)/2 + bar.dropdownFilletRadius; y: bar.barHeight }

            PathArc {
              x: bar.dropdownWidth + (bar.width - bar.dropdownWidth)/2
              y: bar.barHeight + bar.dropdownFilletRadius
              radiusX: bar.dropdownFilletRadius
              radiusY: bar.dropdownFilletRadius
              direction: PathArc.Counterclockwise
            }

            PathLine { x: bar.dropdownWidth + (bar.width - bar.dropdownWidth)/2; y: bar.height - bar.dropdownCornerRadius }

            PathArc {
              x: bar.dropdownWidth + (bar.width - bar.dropdownWidth)/2 - bar.dropdownCornerRadius
              y: bar.height
              radiusX: bar.dropdownCornerRadius
              radiusY: bar.dropdownCornerRadius
              direction: PathArc.Clockwise
            }

            PathLine { x: (bar.width - bar.dropdownWidth)/2 + bar.dropdownCornerRadius; y: bar.height }

            PathArc {
              x: (bar.width - bar.dropdownWidth)/2
              y: bar.height - bar.dropdownCornerRadius
              radiusX: bar.dropdownCornerRadius
              radiusY: bar.dropdownCornerRadius
              direction: PathArc.Clockwise
            }

            PathLine { x: (bar.width - bar.dropdownWidth)/2; y: bar.barHeight + bar.dropdownFilletRadius }

            PathArc {
              x: (bar.width - bar.dropdownWidth)/2 - bar.dropdownFilletRadius
              y: bar.barHeight
              radiusX: bar.dropdownFilletRadius
              radiusY: bar.dropdownFilletRadius
              direction: PathArc.Counterclockwise
            }

            PathLine { x: 0; y: bar.barHeight }
            PathLine { x: 0; y: 0 }
          }

          states: [
            State {
              name: "normal"
              PropertyChanges { target: bar; dropdownWidth: 10 * parent.width / 100; dropdownHeight: 0; dropdownFilletRadius: 0; dropdownCornerRadius: 0 }
            },
            State {
              name: "dashboard"
              PropertyChanges {
                target: bar;
                dropdownWidth: 60 * parent.width / 100;
                dropdownHeight: dashboardGrid.implicitHeight + (bar.dropdownWidgetPadding * 2) - bar.barHeight;
                dropdownFilletRadius: 20;
                dropdownCornerRadius: 20
              }
            },
            State {
              name: "wallpaper_selector"
              PropertyChanges {
                target: bar;
                dropdownWidth: 50 * parent.width / 100;
                dropdownHeight: 10 * parent.height / 100;
                dropdownFilletRadius: 20;
                dropdownCornerRadius: 20
              }
            },
            State {
              name: "app_selector"
              PropertyChanges {
                target: bar;
                dropdownWidth: 30 * parent.width / 100;
                dropdownHeight: appSelectorWidget.totalHeight + (bar.dropdownWidgetPadding * 2) - bar.barHeight;
                dropdownFilletRadius: 20;
                dropdownCornerRadius: 20;
              }
            },
            State {
              name: "power_menu"
              PropertyChanges {
                target: bar;
                dropdownWidth: 35 * parent.width / 100;
                dropdownHeight: 12 * parent.height / 100;
                dropdownFilletRadius: 20;
                dropdownCornerRadius: 20;
              }
            }
          ]

          transitions: [
            Transition {
              NumberAnimation { target: bar; properties: "dropdownWidth,dropdownHeight,dropdownCornerRadius,dropdownFilletRadius"; duration: 100; easing.type: Easing.OutQuint }
            },
          ]
        }

        // Container for all the bar-exclusive widgets
        Item {
          id: barWidgetsContainer
          width: parent.width
          height: bar.barHeight

          // Workspaces on the left (per-monitor)
          Workspaces {
            monitorId: barWindow.monitorId
            anchors {
              left: parent.left
              verticalCenter: parent.verticalCenter
              leftMargin: 15
            }
          }

          // Music/Weather widget in center
          MusicWidget {
            anchors {
              horizontalCenter: parent.horizontalCenter
              verticalCenter: parent.verticalCenter
            }
          }

          // Clock widget
          Text {
            id: timeDisplay
            anchors {
              right: parent.right
              verticalCenter: parent.verticalCenter
              rightMargin: 20
            }

            color: "#cdd6f4"
            font.pixelSize: 14
            font.family: "Noto Sans"
            font.bold: true

            function updateTime() {
              text = Qt.formatDateTime(new Date(), "hh:mm:ss")
            }

            Component.onCompleted: updateTime()
          }

          Timer {
            interval: 500
            running: true
            repeat: true
            onTriggered: timeDisplay.updateTime()
          }

          // System widgets (battery, temp, cpu)
          RowLayout {
            anchors {
              right: timeDisplay.left
              verticalCenter: parent.verticalCenter
              rightMargin: 15
            }
            spacing: 8

            // Volume widget (click to mute)
            Item {
              implicitWidth: volumeRow.implicitWidth
              implicitHeight: volumeRow.implicitHeight
              
              RowLayout {
                id: volumeRow
                spacing: 5

                Text {
                  text: root.volumeIcon
                  color: "#cba6f7"
                  font.pixelSize: 14
                  font.family: "monospace"
                  font.bold: true
                }
                
                Text {
                  text: root.volumePercent + "%"
                  color: "#cba6f7"
                  font.pixelSize: 14
                  font.bold: true
                }
              }
              
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (Pipewire.defaultAudioSink?.audio) {
                    Pipewire.defaultAudioSink.audio.muted = !Pipewire.defaultAudioSink.audio.muted
                  }
                }
              }
            }

            Rectangle {
              implicitWidth: 2
              implicitHeight: parent.parent.height * 0.6
              color: "#6c7086"
            }

            RowLayout {
              spacing: 5
              Text {
                text: "󰘚"
                color: "#89b4fa"
                font.pixelSize: 14
                font.family: "monospace"
                font.bold: true
              }
              Text {
                text: parseFloat(root.cpuLoad).toFixed(0) + "%"
                color: "#89b4fa"
                font.pixelSize: 14
                font.bold: true
              }
            }

            Rectangle {
              implicitWidth: 2
              implicitHeight: parent.parent.height * 0.6
              color: "#6c7086"
            }

            RowLayout {
              spacing: 5
              Text {
                text: "󰔏"
                color: {
                  let temp = parseFloat(root.tempValue);
                  if (temp > 80) return "#f38ba8";
                  if (temp > 60) return "#fab387";
                  return "#94e2d5";
                }
                font.pixelSize: 14
                font.family: "monospace"
                font.bold: true
              }
              Text {
                text: parseFloat(root.tempValue).toFixed(0) + "°C"
                color: {
                  let temp = parseFloat(root.tempValue);
                  if (temp > 80) return "#f38ba8";
                  if (temp > 60) return "#fab387";
                  return "#94e2d5";
                }
                font.pixelSize: 14
                font.bold: true
              }
            }

            Rectangle {
              implicitWidth: 2
              implicitHeight: parent.parent.height * 0.6
              color: "#6c7086"
            }

            RowLayout {
              spacing: 5
              Text {
                text: root.batteryIcon
                color: {
                  let level = parseInt(root.batteryPercent);
                  if (level > 60) return "#a6e3a1";
                  if (level > 30) return "#f9e2af";
                  return "#f38ba8";
                }
                font.pixelSize: 14
                font.family: "monospace"
                font.bold: true
              }
              Text {
                text: root.batteryPercent + "%"
                color: {
                  let level = parseInt(root.batteryPercent);
                  if (level > 60) return "#a6e3a1";
                  if (level > 30) return "#f9e2af";
                  return "#f38ba8";
                }
                font.pixelSize: 14
                font.bold: true
              }
            }
          }
        }

        // Container for the 'dynamic island' dropdown widgets
        Item {
          id: dynamicWidgetsContainer
          width: bar.dropdownWidth
          height: bar.barHeight + bar.dropdownHeight

          anchors {
            top: parent.top
            horizontalCenter: parent.horizontalCenter
          }

          WallpaperSelectorWidget {}

          AppSelectorWidget {
              id: appSelectorWidget
          }

          PowerMenuWidget {}
          
          // Dashboard grid container (column-based layout)
          Item {
            id: dashboardGrid
            visible: bar.state === "dashboard"
            
            anchors {
              top: parent.top
              topMargin: bar.barHeight
              horizontalCenter: parent.horizontalCenter
            }
            
            width: parent.width - (bar.dropdownWidgetPadding * 2)
            
            property real widgetHeight: 160
            property real colSpacing: 10
            property real rowSpacing: 10
            property real topPad: 5
            property real bottomPad: 10
            
            implicitHeight: topPad + (widgetHeight * 3) + (rowSpacing * 2) + bottomPad
            
            RowLayout {
              anchors {
                fill: parent
                topMargin: dashboardGrid.topPad
                bottomMargin: dashboardGrid.bottomPad
              }
              spacing: dashboardGrid.colSpacing
              
              // Columns 1-2: Tailscale (2-tall) + SystemStats/MiscStats side by side
              ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredWidth: 2
                spacing: dashboardGrid.rowSpacing
                
                TailscaleWidget {
                  id: tailscaleWidget
                  Layout.fillWidth: true
                  Layout.preferredHeight: dashboardGrid.widgetHeight * 1.5 + dashboardGrid.rowSpacing * 0.5
                }
                
                RowLayout {
                  Layout.fillWidth: true
                  Layout.preferredHeight: dashboardGrid.widgetHeight * 1.5 + dashboardGrid.rowSpacing * 0.5
                  spacing: dashboardGrid.colSpacing
                  
                  SystemStatsWidget {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                  }
                  
                  MiscStatsWidget {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                  }
                }
              }
              
              // Column 3: 3 widgets stacked
              ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredWidth: 1
                spacing: dashboardGrid.rowSpacing
                
                QuoteWidget {
                  id: quoteWidget
                  Layout.fillWidth: true
                  Layout.preferredHeight: dashboardGrid.widgetHeight
                }
                
                WeatherWidget {
                  id: weatherWidget
                  Layout.fillWidth: true
                  Layout.preferredHeight: dashboardGrid.widgetHeight
                }
                
                NetworkStatsWidget {
                  Layout.fillWidth: true
                  Layout.preferredHeight: dashboardGrid.widgetHeight
                }
              }
              
              // Column 4: Profile card (2-tall) + empty space
              ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredWidth: 1
                spacing: dashboardGrid.rowSpacing
                
                ProfileWidget {
                  id: profileWidget
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                }
              }
            }
          }
        }
      }

      MultiEffect {
        source: main
        anchors.fill: main
        shadowEnabled: true
      }

      // Exclusion zone (per-screen)
      Scope {
        PanelWindow {
          screen: barWindow.modelData
          anchors.top: true
          implicitWidth: 0
          implicitHeight: bar.barHeight
        }
      }
    }
  }
}
