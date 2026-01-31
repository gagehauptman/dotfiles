import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

Item {
  id: systemWidget
  
  visible: bar.state === "dashboard"
  
  property real cpuUsage: 0
  property real ramUsed: 0
  property real ramTotal: 0
  property real ramPercent: 0
  property string diskUsed: "0G"
  property string diskTotal: "0G"
  property real diskPercent: 0
  
  implicitHeight: 190
  
  // System stats poller
  Process {
    id: systemProc
    command: ["bash", "/storage/git/dotfiles/scripts/polls/systempoll.sh"]
    running: true
    
    stdout: StdioCollector {
      onStreamFinished: {
        let parts = this.text.trim().split('|')
        if (parts.length === 7) {
          systemWidget.cpuUsage = parseFloat(parts[0])
          systemWidget.ramUsed = parseFloat(parts[1])
          systemWidget.ramTotal = parseFloat(parts[2])
          systemWidget.ramPercent = parseFloat(parts[3])
          systemWidget.diskUsed = parts[4]
          systemWidget.diskTotal = parts[5]
          systemWidget.diskPercent = parseFloat(parts[6])
        }
      }
    }
  }
  
  Timer {
    interval: 3000 // Poll every 3 seconds
    running: true
    repeat: true
    onTriggered: systemProc.running = true
  }
  
  Rectangle {
    anchors.fill: parent
    color: "#181825"
    radius: 15
    
    ColumnLayout {
      anchors {
        fill: parent
        margins: 15
      }
      spacing: 8
      
      // Title
      Text {
        text: "  System Resources"
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
      
      // CPU
      ColumnLayout {
        Layout.fillWidth: true
        spacing: 6
        
        RowLayout {
          Layout.fillWidth: true
          
          Text {
            text: "󰘚 CPU"
            color: "#89b4fa"
            font.pixelSize: 13
            font.bold: true
            font.family: "monospace"
            Layout.preferredWidth: 70
          }
          
          Text {
            text: systemWidget.cpuUsage.toFixed(1) + "%"
            color: "#cdd6f4"
            font.pixelSize: 12
            Layout.fillWidth: true
          }
        }
        
        Rectangle {
          Layout.fillWidth: true
          height: 8
          radius: 4
          color: "#313244"
          
          Rectangle {
            width: parent.width * (systemWidget.cpuUsage / 100)
            height: parent.height
            radius: 4
            color: {
              if (systemWidget.cpuUsage > 80) return "#f38ba8"
              if (systemWidget.cpuUsage > 50) return "#fab387"
              return "#89b4fa"
            }
            
            Behavior on width {
              NumberAnimation { duration: 200 }
            }
          }
        }
      }
      
      // RAM
      ColumnLayout {
        Layout.fillWidth: true
        spacing: 6
        
        RowLayout {
          Layout.fillWidth: true
          
          Text {
            text: "󰍛 RAM"
            color: "#a6e3a1"
            font.pixelSize: 13
            font.bold: true
            font.family: "monospace"
            Layout.preferredWidth: 70
          }
          
          Text {
            text: systemWidget.ramUsed.toFixed(1) + " / " + systemWidget.ramTotal.toFixed(1) + " GB (" + systemWidget.ramPercent.toFixed(0) + "%)"
            color: "#cdd6f4"
            font.pixelSize: 12
            Layout.fillWidth: true
          }
        }
        
        Rectangle {
          Layout.fillWidth: true
          height: 8
          radius: 4
          color: "#313244"
          
          Rectangle {
            width: parent.width * (systemWidget.ramPercent / 100)
            height: parent.height
            radius: 4
            color: {
              if (systemWidget.ramPercent > 80) return "#f38ba8"
              if (systemWidget.ramPercent > 50) return "#fab387"
              return "#a6e3a1"
            }
            
            Behavior on width {
              NumberAnimation { duration: 200 }
            }
          }
        }
      }
      
      // Disk
      ColumnLayout {
        Layout.fillWidth: true
        spacing: 6
        
        RowLayout {
          Layout.fillWidth: true
          
          Text {
            text: "󰋊 Disk"
            color: "#f5c2e7"
            font.pixelSize: 13
            font.bold: true
            font.family: "monospace"
            Layout.preferredWidth: 70
          }
          
          Text {
            text: systemWidget.diskUsed + " / " + systemWidget.diskTotal + " (" + systemWidget.diskPercent.toFixed(0) + "%)"
            color: "#cdd6f4"
            font.pixelSize: 12
            Layout.fillWidth: true
          }
        }
        
        Rectangle {
          Layout.fillWidth: true
          height: 8
          radius: 4
          color: "#313244"
          
          Rectangle {
            width: parent.width * (systemWidget.diskPercent / 100)
            height: parent.height
            radius: 4
            color: {
              if (systemWidget.diskPercent > 80) return "#f38ba8"
              if (systemWidget.diskPercent > 50) return "#fab387"
              return "#f5c2e7"
            }
            
            Behavior on width {
              NumberAnimation { duration: 200 }
            }
          }
        }
      }
    }
  }
  
  Component.onCompleted: {
    systemProc.running = true
  }
}
