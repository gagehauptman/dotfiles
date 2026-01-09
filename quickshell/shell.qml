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
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.keyboardFocus: (bar.state === "wallpaper_selector" || bar.state === "app_selector")
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
            dropdownHeight: 30 * parent.height / 100;
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
            dropdownHeight: bar.appSelectorCellHeightConst * bar.appSelectorRowsPerPage + bar.appSelectorOffsetFromBar;
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

      // Clock widget
      Text {
        id: timeDisplay
        anchors {
          right: parent.right
          verticalCenter: parent.verticalCenter
          rightMargin: 20
        }

        color: "white"
        font.pixelSize: parent.height * 0.5
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

      AppSelectorWidget {}
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
}