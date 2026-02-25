import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland

Item {
  id: workspacesWidget
  implicitWidth: 300
  implicitHeight: parent.height

  // Monitor ID this widget is bound to (set by parent bar instance)
  property int monitorId: 0
  property int workspaceCount: 10

  // Find the Hyprland monitor object for this monitorId
  property var hyprMonitor: {
    let monitors = Hyprland.monitors.values
    for (let i = 0; i < monitors.length; i++) {
      if (monitors[i].id === monitorId) return monitors[i]
    }
    return null
  }

  // Detect the base workspace ID for this monitor from actual workspace state.
  // The split-monitor-workspaces plugin assigns sequential IDs per monitor
  // (e.g. monitor 0 = 1-10, monitor 1 = 11-20). We find the lowest workspace
  // ID assigned to our monitor to compute the base.
  property var workspacesList: Hyprland.workspaces.values
  property int baseWorkspaceId: {
    let wsList = workspacesWidget.workspacesList
    let minId = 999999
    for (let i = 0; i < wsList.length; i++) {
      let ws = wsList[i]
      if (ws.monitor && ws.monitor.id === monitorId && ws.id > 0 && ws.id < minId) {
        minId = ws.id
      }
    }
    return minId === 999999 ? 1 : minId
  }

  RowLayout {
    anchors.centerIn: parent
    spacing: 13

    Repeater {
      model: workspacesWidget.workspaceCount

      Rectangle {
        required property int index

        property int workspaceId: workspacesWidget.baseWorkspaceId + index
        property bool isActive: workspacesWidget.hyprMonitor?.activeWorkspace?.id === workspaceId

        // Check if workspace has windows
        property bool hasWindows: {
          let wsList = workspacesWidget.workspacesList
          for (let i = 0; i < wsList.length; i++) {
            if (wsList[i].id === workspaceId) {
              return wsList[i].toplevels.values.length > 0
            }
          }
          return false
        }

        implicitWidth: isActive ? 22 : 13
        implicitHeight: 13
        radius: 6.5

        color: {
          if (isActive && hasWindows) return "#89b4fa"   // Blue - active with windows
          if (isActive) return "#74c7ec"                  // Sapphire - active but empty
          if (hasWindows) return "#b4befe"               // Lavender - has windows
          return "#45475a"                                // Surface1 - empty
        }

        opacity: {
          if (isActive) return 1.0
          if (hasWindows) return 0.5
          return 0.4
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
          anchors.fill: parent
          onClicked: {
            Hyprland.dispatch("workspace " + parent.workspaceId);
          }
        }
      }
    }
  }
}
