import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

Item {
  id: tailscaleWidget
  
  implicitHeight: 190
  
  property var devices: []
  
  // Tailscale status poller
  Process {
    id: tailscaleProc
    command: ["bash", "/storage/git/dotfiles/scripts/polls/tailscalepoll.sh"]
    running: true
    
    stdout: StdioCollector {
      onStreamFinished: {
        let lines = this.text.trim().split('\n').filter(l => l.trim())
        let deviceList = []
        
        for (let i = 0; i < lines.length; i++) {
          let parts = lines[i].split('|')
          if (parts.length === 3) {
            deviceList.push({
              name: parts[0],
              status: parts[1],
              ping: parts[2]
            })
          }
        }
        
        tailscaleWidget.devices = deviceList
      }
    }
  }
  
  Timer {
    interval: 10000 // Poll every 10 seconds
    running: true
    repeat: true
    onTriggered: tailscaleProc.running = true
  }
  
  Rectangle {
    anchors.fill: parent
    color: "#181825"
    radius: 15
    clip: true
    
    ColumnLayout {
      id: deviceColumn
      anchors {
        top: parent.top
        left: parent.left
        right: parent.right
        margins: 15
      }
      spacing: 8
      
      // Title
      Text {
        text: "󰛳  Tailscale Network"
        color: "#cdd6f4"
        font.pixelSize: 16
        font.bold: true
        font.family: "monospace"
        Layout.fillWidth: true
      }
      
      // Separator
      Rectangle {
        Layout.fillWidth: true
        height: 2
        color: "#45475a"
      }
      
      // Device list
      Repeater {
        model: tailscaleWidget.devices
        
        RowLayout {
          Layout.fillWidth: true
          spacing: 10
          
          // Status indicator
          Rectangle {
            width: 10
            height: 10
            radius: 5
            color: modelData.status === "online" ? "#a6e3a1" : "#f38ba8"
          }
          
          // Device name
          Text {
            text: modelData.name
            color: "#cdd6f4"
            font.pixelSize: 14
            font.bold: true
            Layout.fillWidth: true
          }
          
          // Status text
          Text {
            text: modelData.status
            color: modelData.status === "online" ? "#a6e3a1" : "#6c7086"
            font.pixelSize: 13
            font.italic: true
          }
          
          // Ping time (if available)
          Text {
            visible: modelData.ping !== "N/A"
            text: "(" + modelData.ping + ")"
            color: {
              if (modelData.ping === "N/A") return "#6c7086"
              let pingValue = parseInt(modelData.ping)
              if (pingValue < 30) return "#a6e3a1"  // Green (good)
              if (pingValue < 100) return "#f9e2af"  // Yellow (ok)
              return "#f38ba8"  // Red (slow)
            }
            font.pixelSize: 12
          }
        }
      }
      
      // Empty state message
      Text {
        visible: tailscaleWidget.devices.length === 0
        text: "Loading devices..."
        color: "#6c7086"
        font.pixelSize: 13
        font.italic: true
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignHCenter
      }
    }
  }
  
  Component.onCompleted: {
    // Trigger initial fetch
    tailscaleProc.running = true
  }
}
