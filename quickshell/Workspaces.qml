import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import "themes"

Item {
  id: workspacesWidget
  implicitWidth: 300
  implicitHeight: parent.height

  // Monitor ID this widget is bound to (set by parent bar instance)
  property int monitorId: 0

  // Find the Hyprland monitor object for this monitorId
  property var hyprMonitor: {
    let monitors = Hyprland.monitors.values
    for (let i = 0; i < monitors.length; i++) {
      if (monitors[i].id === monitorId) return monitors[i]
    }
    return null
  }

  // Sorted list of workspace objects belonging to this monitor.
  // With split-monitor-workspaces + enable_persistent_workspaces, this is the
  // single source of truth for both rendering dots and dispatching clicks.
  property var monitorWorkspaces: {
    let result = []
    let wsList = Hyprland.workspaces.values
    for (let i = 0; i < wsList.length; i++) {
      let ws = wsList[i]
      if (ws.monitor && ws.monitor.id === monitorId && ws.id > 0) {
        result.push(ws)
      }
    }
    result.sort((a, b) => a.id - b.id)
    return result
  }

  RowLayout {
    anchors.centerIn: parent
    spacing: 13

    Repeater {
      model: workspacesWidget.monitorWorkspaces

      Rectangle {
        id: dot
        required property var modelData

        property bool isActive: workspacesWidget.hyprMonitor?.activeWorkspace?.id === modelData.id
        property bool hasWindows: (modelData.toplevels?.values?.length ?? 0) > 0
        property bool isHovered: mouseArea.containsMouse

        implicitWidth: isActive ? 22 : 13
        implicitHeight: 13
        radius: 6.5

        color: {
          let base
          if (isActive && hasWindows) base = Theme.colors.blue
          else if (isActive) base = Theme.colors.indigo
          else if (hasWindows) base = Theme.colors.lavender
          else base = Theme.colors.border
          return isHovered ? Qt.lighter(base, 1.25) : base
        }

        opacity: {
          if (isActive) return 1.0
          if (hasWindows) return isHovered ? 0.75 : 0.5
          return isHovered ? 0.65 : 0.4
        }

        Behavior on implicitWidth {
          NumberAnimation {
            duration: 150
            easing.type: Easing.OutQuad
          }
        }

        Behavior on color {
          ColorAnimation {
            duration: 150
          }
        }

        Behavior on opacity {
          NumberAnimation {
            duration: 150
          }
        }

        MouseArea {
          id: mouseArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: dot.modelData.activate()
        }
      }
    }
  }
}
