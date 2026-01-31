import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

Item {
  id: workspacesWidget
  implicitWidth: 300
  implicitHeight: parent.height

  // Read active monitor from the file Hyprland mon socket maintains
  FileView {
    id: activeMonitorFile
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/hypr/" + Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") + "/active_monitor"
  }

  property int activeMonitor: {
    let content = activeMonitorFile.text();
    return parseInt(content.trim()) || 0;
  }

  // Listen to Hyprland workspace changes
  Connections {
    target: Hyprland.focusedMonitor
    
    function onActiveWorkspaceChanged() {
      // Trigger a reload of the active monitor file
      activeMonitorFile.reload();
    }
  }

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
  
  // Periodically reload the active monitor file
  Timer {
    interval: 100
    running: true
    repeat: true
    onTriggered: activeMonitorFile.reload()
  }
}
