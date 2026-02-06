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
        
        implicitWidth: isActive ? 22 : 13
        implicitHeight: 13
        radius: 6.5
        
        color: isActive ? "#89b4fa" : "#45475a"
        
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
