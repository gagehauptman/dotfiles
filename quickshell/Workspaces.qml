import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland

Item {
  id: workspacesWidget
  implicitWidth: 300
  implicitHeight: parent.height

  // Get active monitor ID directly from Hyprland (0-indexed)
  property int activeMonitor: Hyprland.focusedMonitor?.id ?? 0

  // Track workspace changes for reactivity
  property var workspacesList: Hyprland.workspaces.values

  RowLayout {
    anchors.centerIn: parent
    spacing: 13

    Repeater {
      model: [1, 2, 3, 4, 5, 6, 7, 8, 9, 0]
      
      Rectangle {
        required property int modelData
        
        // Calculate workspace ID: [monitor][digit]
        property int workspaceId: (workspacesWidget.activeMonitor + 1) * 10 + modelData
        property bool isActive: Hyprland.focusedMonitor?.activeWorkspace?.id === workspaceId
        
        // Reactive: re-evaluate when workspacesList changes
        property bool hasWindows: {
          let wsList = workspacesWidget.workspacesList
          for (let i = 0; i < wsList.length; i++) {
            if (wsList[i].id === workspaceId) {
              return wsList[i].toplevels.values.length > 0
            }
          }
          return false
        }
        
        // Check if workspace has urgent windows
        property bool isUrgent: {
          let wsList = workspacesWidget.workspacesList
          for (let i = 0; i < wsList.length; i++) {
            if (wsList[i].id === workspaceId) {
              return wsList[i].urgent
            }
          }
          return false
        }
        
        implicitWidth: isActive ? 22 : 13
        implicitHeight: 13
        radius: 6.5
        
        color: {
          if (isUrgent) return "#f38ba8"                  // Red - urgent
          if (isActive && hasWindows) return "#89b4fa"   // Blue - active with windows
          if (isActive) return "#74c7ec"                  // Sapphire - active but empty
          if (hasWindows) return "#b4befe"               // Lavender - has windows
          return "#45475a"                                // Surface1 - empty
        }
        
        // Pulse animation for urgent workspaces
        SequentialAnimation on opacity {
          running: isUrgent
          loops: Animation.Infinite
          NumberAnimation { to: 0.4; duration: 400; easing.type: Easing.InOutQuad }
          NumberAnimation { to: 1.0; duration: 400; easing.type: Easing.InOutQuad }
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
            // Switch to this workspace
            Hyprland.dispatch("workspace " + parent.workspaceId);
          }
        }
      }
    }
  }
}
