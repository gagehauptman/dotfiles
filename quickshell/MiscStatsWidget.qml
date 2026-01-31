import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

Item {
  id: miscWidget
  
  visible: bar.state === "dashboard"
  
  property string uptime: "..."
  property string loadAvg: "..."
  property int processCount: 0
  property string kernel: "..."
  property int userCount: 0
  
  implicitHeight: 190
  
  // Misc stats poller
  Process {
    id: miscProc
    command: ["bash", "/storage/git/dotfiles/scripts/polls/miscstatspoll.sh"]
    running: true
    
    stdout: StdioCollector {
      onStreamFinished: {
        let parts = this.text.trim().split('|')
        if (parts.length === 5) {
          miscWidget.uptime = parts[0]
          miscWidget.loadAvg = parts[1]
          miscWidget.processCount = parseInt(parts[2])
          miscWidget.kernel = parts[3]
          miscWidget.userCount = parseInt(parts[4])
        }
      }
    }
  }
  
  Timer {
    interval: 30000 // Poll every 30 seconds
    running: true
    repeat: true
    onTriggered: miscProc.running = true
  }
  
  Rectangle {
    anchors.fill: parent
    color: "#181825"
    radius: 15
    
    ColumnLayout {
      id: contentColumn
      anchors {
        top: parent.top
        left: parent.left
        right: parent.right
        margins: 18
      }
      spacing: 10
      
      // Title
      Text {
        text: "  System Info"
        color: "#cdd6f4"
        font.pixelSize: 14
        font.bold: true
        font.family: "monospace"
        Layout.fillWidth: true
      }
      
      // Separator
      Rectangle {
        Layout.fillWidth: true
        height: 1
        color: "#45475a"
      }
      
      // Stats grid
      GridLayout {
        Layout.fillWidth: true
        columns: 2
        columnSpacing: 10
        rowSpacing: 7
        
        // Uptime
        Text {
          text: "󰥔 Uptime"
          color: "#f9e2af"
          font.pixelSize: 12
          font.bold: true
          font.family: "monospace"
        }
        
        Text {
          text: miscWidget.uptime
          color: "#cdd6f4"
          font.pixelSize: 11
          Layout.fillWidth: true
          elide: Text.ElideRight
          wrapMode: Text.NoWrap
        }
        
        // Load average
        Text {
          text: "󰓅 Load Avg"
          color: "#fab387"
          font.pixelSize: 12
          font.bold: true
          font.family: "monospace"
        }
        
        Text {
          text: miscWidget.loadAvg
          color: "#cdd6f4"
          font.pixelSize: 11
          Layout.fillWidth: true
        }
        
        // Process count
        Text {
          text: "󰐾 Processes"
          color: "#94e2d5"
          font.pixelSize: 12
          font.bold: true
          font.family: "monospace"
        }
        
        Text {
          text: miscWidget.processCount.toString()
          color: "#cdd6f4"
          font.pixelSize: 11
          Layout.fillWidth: true
        }
        
        // Kernel
        Text {
          text: "󰒓 Kernel"
          color: "#b4befe"
          font.pixelSize: 12
          font.bold: true
          font.family: "monospace"
        }
        
        Text {
          text: miscWidget.kernel
          color: "#cdd6f4"
          font.pixelSize: 11
          Layout.fillWidth: true
          elide: Text.ElideRight
          wrapMode: Text.NoWrap
        }
        
        // Active users
        Text {
          text: "󰀄 Users"
          color: "#cba6f7"
          font.pixelSize: 12
          font.bold: true
          font.family: "monospace"
        }
        
        Text {
          text: miscWidget.userCount.toString()
          color: "#cdd6f4"
          font.pixelSize: 11
          Layout.fillWidth: true
        }
      }
    }
  }
  
  Component.onCompleted: {
    miscProc.running = true
  }
}
