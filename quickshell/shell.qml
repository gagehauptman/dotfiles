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

PanelWindow {
  id: root
  
  // Widget data properties
  property string tempValue: "0"
  property string batteryPercent: "0"
  property string batteryIcon: ""
  property string cpuLoad: "0"
  property string volumePercent: "0"
  property string volumeIcon: "󰕾"
  
  // PipeWire volume tracking
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
    // Initialize volume on startup
    if (Pipewire.defaultAudioSink?.audio) {
      let volume = Math.round(Pipewire.defaultAudioSink.audio.volume * 100)
      root.volumePercent = volume.toString()
      root.volumeIcon = Pipewire.defaultAudioSink.audio.muted ? "󰖁" : "󰕾"
    }
  }
  
  // Low battery warning state
  property int lowBatteryThreshold: 15
  property bool lowBatteryWarningShown: false
  
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.keyboardFocus: (bar.state === "wallpaper_selector" || bar.state === "app_selector" || bar.state === "power_menu")
        ? WlrKeyboardFocus.Exclusive 
        : WlrKeyboardFocus.None
  mask: Region {}

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
      layer.samples: 4 // Use 4 or 8 for very smooth edges

      property real barHeight: 2.5 * parent.height / 100

      property real dropdownWidth: 30 * parent.width / 100
      property real dropdownHeight: 10 * parent.height / 100
      property real dropdownFilletRadius: 10
      property real dropdownCornerRadius: 25
      property int dropdownWidgetPadding: 20  // spacing between widget and dropdown edge

      width: parent.width
      height: barHeight + dropdownHeight

      property int appSelectorCellHeightConst: 120
      property int appSelectorOffsetFromBar: 5
      property int appSelectorRowsPerPage: 5

      ShapePath {
        fillColor: "#11111b"
        strokeColor: "transparent"

        startX: 0; startY: 0

        // top edge
        PathLine { x: bar.width; y: 0 }

        // right side edge
        PathLine { x: bar.width; y: bar.barHeight }

        // bottom edge (right)
        PathLine { x: bar.dropdownWidth + (bar.width - bar.dropdownWidth)/2 + bar.dropdownFilletRadius; y: bar.barHeight }

        // right-side dropdown fillet
        PathArc {
          x: bar.dropdownWidth + (bar.width - bar.dropdownWidth)/2
          y: bar.barHeight + bar.dropdownFilletRadius
          radiusX: bar.dropdownFilletRadius
          radiusY: bar.dropdownFilletRadius
          direction: PathArc.Counterclockwise
        }

        // dropdown right side edge
        PathLine { x: bar.dropdownWidth + (bar.width - bar.dropdownWidth)/2; y: bar.height - bar.dropdownCornerRadius }

        // dropdown bottom-right corner
        PathArc {
          x: bar.dropdownWidth + (bar.width - bar.dropdownWidth)/2 - bar.dropdownCornerRadius
          y: bar.height
          radiusX: bar.dropdownCornerRadius
          radiusY: bar.dropdownCornerRadius
          direction: PathArc.Clockwise
        }

        // dropdown bottom edge
        PathLine { x: (bar.width - bar.dropdownWidth)/2 + bar.dropdownCornerRadius; y: bar.height }

        // dropdown bottom-left corner
        PathArc {
          x: (bar.width - bar.dropdownWidth)/2
          y: bar.height - bar.dropdownCornerRadius
          radiusX: bar.dropdownCornerRadius
          radiusY: bar.dropdownCornerRadius
          direction: PathArc.Clockwise
        }

        // dropdown left side edge
        PathLine { x: (bar.width - bar.dropdownWidth)/2; y: bar.barHeight + bar.dropdownFilletRadius }

        // right-side dropdown fillet
        PathArc {
          x: (bar.width - bar.dropdownWidth)/2 - bar.dropdownFilletRadius
          y: bar.barHeight
          radiusX: bar.dropdownFilletRadius
          radiusY: bar.dropdownFilletRadius
          direction: PathArc.Counterclockwise
        }

        // bottom edge (left)
        PathLine { x: 0; y: bar.barHeight }

        // left side edge
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
            dropdownWidth: 40 * parent.width / 100;
            dropdownHeight: dashboardGrid.implicitHeight;
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

      // Workspaces on the left
      Workspaces {
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

        // Function to format the time
        function updateTime() {
          text = Qt.formatDateTime(new Date(), "hh:mm:ss")
        }

        // Initial call
        Component.onCompleted: updateTime()
      }

      // Clock timer
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

        // Volume widget
        RowLayout {
          spacing: 5

          Text {
            text: root.volumeIcon
            color: "#cba6f7"  // Mauve
            font.pixelSize: 14
            font.family: "monospace"
            font.bold: true
          }
          
          Text {
            text: root.volumePercent + "%"
            color: "#cba6f7"  // Mauve
            font.pixelSize: 14
            font.bold: true
          }
        }

        // Separator
        Rectangle {
          implicitWidth: 2
          implicitHeight: parent.parent.height * 0.6
          color: "#6c7086"
        }

        // CPU widget
        RowLayout {
          spacing: 5

          Text {
            text: "󰘚"
            color: "#89b4fa"  // Blue
            font.pixelSize: 14
            font.family: "monospace"
            font.bold: true
          }
          
          Text {
            text: parseFloat(root.cpuLoad).toFixed(0) + "%"
            color: "#89b4fa"  // Blue
            font.pixelSize: 14
            font.bold: true
          }
        }

        // Separator
        Rectangle {
          implicitWidth: 2
          implicitHeight: parent.parent.height * 0.6
          color: "#6c7086"
        }

        // Temperature widget
        RowLayout {
          spacing: 5

          Text {
            text: "󰔏"
            color: {
              let temp = parseFloat(root.tempValue);
              if (temp > 80) return "#f38ba8";  // Red (hot)
              if (temp > 60) return "#fab387";  // Peach (warm)
              return "#94e2d5";  // Teal (cool)
            }
            font.pixelSize: 14
            font.family: "monospace"
            font.bold: true
          }
          
          Text {
            text: parseFloat(root.tempValue).toFixed(0) + "°C"
            color: {
              let temp = parseFloat(root.tempValue);
              if (temp > 80) return "#f38ba8";  // Red
              if (temp > 60) return "#fab387";  // Peach
              return "#94e2d5";  // Teal
            }
            font.pixelSize: 14
            font.bold: true
          }
        }

        // Separator
        Rectangle {
          implicitWidth: 2
          implicitHeight: parent.parent.height * 0.6
          color: "#6c7086"
        }

        // Battery widget
        RowLayout {
          spacing: 5

          Text {
            text: root.batteryIcon
            color: {
              let level = parseInt(root.batteryPercent);
              if (level > 60) return "#a6e3a1";  // Green
              if (level > 30) return "#f9e2af";  // Yellow
              return "#f38ba8";  // Red
            }
            font.pixelSize: 14
            font.family: "monospace"
            font.bold: true
          }
          
          Text {
            text: root.batteryPercent + "%"
            color: {
              let level = parseInt(root.batteryPercent);
              if (level > 60) return "#a6e3a1";  // Green
              if (level > 30) return "#f9e2af";  // Yellow
              return "#f38ba8";  // Red
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
      
      // Dashboard grid container
      ColumnLayout {
        id: dashboardGrid
        visible: bar.state === "dashboard"
        
        anchors {
          top: parent.top
          topMargin: bar.barHeight
          left: parent.left
          right: parent.right
          leftMargin: 20
          rightMargin: 20
        }
        
        property real topMargin: 5
        property real bottomMargin: 10
        property real widgetHeight: 190
        
        // Calculate implicit height from contents
        implicitHeight: topMargin + widgetHeight + spacing + widgetHeight + bottomMargin
        
        spacing: 10
        
        Item {
          Layout.fillWidth: true
          Layout.preferredHeight: dashboardGrid.topMargin
        }
        
        // Top row - Tailscale (2 units) + Quote (1 unit)
        RowLayout {
          id: topRowLayout
          Layout.fillWidth: true
          spacing: 10
          
          implicitHeight: dashboardGrid.widgetHeight
          
          TailscaleWidget {
            id: tailscaleWidget
            Layout.fillWidth: true
            Layout.preferredWidth: 2
            Layout.preferredHeight: dashboardGrid.widgetHeight
            Layout.maximumHeight: dashboardGrid.widgetHeight
            Layout.minimumHeight: dashboardGrid.widgetHeight
          }
          
          QuoteWidget {
            id: quoteWidget
            Layout.fillWidth: true
            Layout.preferredWidth: 1
            Layout.preferredHeight: dashboardGrid.widgetHeight
            Layout.maximumHeight: dashboardGrid.widgetHeight
            Layout.minimumHeight: dashboardGrid.widgetHeight
          }
        }
        
        // Bottom row - three columns
        RowLayout {
          id: bottomRowLayout
          Layout.fillWidth: true
          spacing: 10
          
          implicitHeight: dashboardGrid.widgetHeight
          
          SystemStatsWidget {
            Layout.fillWidth: true
            Layout.preferredWidth: 1
            Layout.preferredHeight: implicitHeight
          }
          
          MiscStatsWidget {
            Layout.fillWidth: true
            Layout.preferredWidth: 1
            Layout.preferredHeight: implicitHeight
          }
          
          NetworkStatsWidget {
            Layout.fillWidth: true
            Layout.preferredWidth: 1
            Layout.preferredHeight: implicitHeight
          }
        }
        
        Item {
          Layout.fillWidth: true
          Layout.preferredHeight: dashboardGrid.bottomMargin
        }
      }
    }
  }

  // Switch the 'dynamic island' to the Dashboard
  GlobalShortcut {
    name: "toggleDashboard"
    onPressed: {
      if (bar.state !== "dashboard") {
        bar.state = "dashboard"
      } else {
        bar.state = "normal"
      }
    }
  }

  // Switch the 'dynamic island' to the wallpaper selector 
  GlobalShortcut {
    name: "toggleWallpaperSelector"
    onPressed: {
      if (bar.state !== "wallpaper_selector") {
        bar.state = "wallpaper_selector"
      } else {
        bar.state = "normal"
      }
    }
  }

  // Switch the 'dynamic island' to the app selector
  GlobalShortcut {
    name: "toggleAppSelector"
    onPressed: {
      if (bar.state !== "app_selector") {
        bar.state = "app_selector"
      } else {
        bar.state = "normal"
      }
    }
  }

  // Switch the 'dynamic island' to the power menu
  GlobalShortcut {
    name: "togglePowerMenu"
    onPressed: {
      if (bar.state !== "power_menu") {
        bar.state = "power_menu"
      } else {
        bar.state = "normal"
      }
    }
  }

  MultiEffect {
    source: main
    anchors.fill: main
    shadowEnabled: true
  }

  Scope {
    PanelWindow {
      anchors.top: true
      implicitWidth: 0
      implicitHeight: bar.barHeight
    }
  }

  // Temperature updater
  Process {
    id: tempProc
    command: ["bash", "/storage/git/dotfiles/scripts/polls/temppoll.sh"]
    running: true

    stdout: StdioCollector {
      onStreamFinished: root.tempValue = this.text.trim()
    }
  }

  Timer {
    interval: 2000
    running: true
    repeat: true
    onTriggered: tempProc.running = true
  }

  // Battery percent updater
  Process {
    id: batteryPercentProc
    command: ["bash", "/storage/git/dotfiles/scripts/polls/batterypoll1.sh"]
    running: true

    stdout: StdioCollector {
      onStreamFinished: {
        let newPercent = this.text.trim()
        let prevPercent = parseInt(root.batteryPercent)
        root.batteryPercent = newPercent
        
        let currentPercent = parseInt(newPercent)
        
        // Reset warning flag if battery goes back above threshold + 5%
        if (currentPercent > root.lowBatteryThreshold + 5) {
          root.lowBatteryWarningShown = false
        }
        
        // Trigger warning if below threshold and not shown yet
        if (currentPercent <= root.lowBatteryThreshold && !root.lowBatteryWarningShown) {
          root.lowBatteryWarningShown = true
          lowBatteryPopup.show()
        }
      }
    }
  }

  Timer {
    interval: 5000
    running: true
    repeat: true
    onTriggered: batteryPercentProc.running = true
  }

  // Battery icon updater
  Process {
    id: batteryIconProc
    command: ["bash", "/storage/git/dotfiles/scripts/polls/batterypoll2.sh"]
    running: true

    stdout: StdioCollector {
      onStreamFinished: root.batteryIcon = this.text.trim()
    }
  }

  Timer {
    interval: 5000
    running: true
    repeat: true
    onTriggered: batteryIconProc.running = true
  }

  // CPU load updater
  Process {
    id: cpuProc
    command: ["bash", "/storage/git/dotfiles/scripts/polls/cpupoll.sh"]
    running: true

    stdout: StdioCollector {
      onStreamFinished: root.cpuLoad = this.text.trim()
    }
  }

  Timer {
    interval: 2000
    running: true
    repeat: true
    onTriggered: cpuProc.running = true
  }

  // Volume/mute now handled by PipeWire native tracking above
}