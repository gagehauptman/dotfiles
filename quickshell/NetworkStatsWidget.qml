import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

Item {
  id: networkWidget
  
  visible: bar.state === "dashboard"
  
  property string interfaceName: "..."
  property string rxTotal: "0B"
  property string txTotal: "0B"
  property string rxRate: "0B/s"
  property string txRate: "0B/s"
  
  implicitHeight: 190
  
  // Network stats poller
  Process {
    id: networkProc
    command: ["bash", "/storage/git/dotfiles/scripts/polls/networkpoll.sh"]
    running: true
    
    stdout: StdioCollector {
      onStreamFinished: {
        let parts = this.text.trim().split('|')
        if (parts.length === 5) {
          networkWidget.interfaceName = parts[0]
          networkWidget.rxTotal = parts[1]
          networkWidget.txTotal = parts[2]
          networkWidget.rxRate = parts[3]
          networkWidget.txRate = parts[4]
        }
      }
    }
  }
  
  Timer {
    interval: 2000 // Poll every 2 seconds for live rates
    running: true
    repeat: true
    onTriggered: networkProc.running = true
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
        margins: 15
      }
      spacing: 8
      
      // Title
      Text {
        text: "󰖟  Network (" + networkWidget.interfaceName + ")"
        color: "#cdd6f4"
        font.pixelSize: 14
        font.bold: true
        font.family: "monospace"
        Layout.fillWidth: true
        elide: Text.ElideRight
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
        columnSpacing: 20
        rowSpacing: 12
        
        // Download rate
        RowLayout {
          Layout.columnSpan: 2
          Layout.fillWidth: true
          spacing: 10
          
          Text {
            text: "󰇚"
            color: "#89dceb"
            font.pixelSize: 16
            font.family: "monospace"
          }
          
          ColumnLayout {
            Layout.fillWidth: true
            spacing: 2
            
            Text {
              text: "Download"
              color: "#89dceb"
              font.pixelSize: 11
              font.bold: true
            }
            
            RowLayout {
              spacing: 8
              
              Text {
                text: networkWidget.rxRate
                color: "#cdd6f4"
                font.pixelSize: 12
                font.bold: true
              }
              
              Text {
                text: "(" + networkWidget.rxTotal + " total)"
                color: "#6c7086"
                font.pixelSize: 10
              }
            }
          }
        }
        
        // Upload rate
        RowLayout {
          Layout.columnSpan: 2
          Layout.fillWidth: true
          spacing: 10
          
          Text {
            text: "󰕒"
            color: "#a6e3a1"
            font.pixelSize: 16
            font.family: "monospace"
          }
          
          ColumnLayout {
            Layout.fillWidth: true
            spacing: 2
            
            Text {
              text: "Upload"
              color: "#a6e3a1"
              font.pixelSize: 11
              font.bold: true
            }
            
            RowLayout {
              spacing: 8
              
              Text {
                text: networkWidget.txRate
                color: "#cdd6f4"
                font.pixelSize: 12
                font.bold: true
              }
              
              Text {
                text: "(" + networkWidget.txTotal + " total)"
                color: "#6c7086"
                font.pixelSize: 10
              }
            }
          }
        }
      }
    }
  }
  
  Component.onCompleted: {
    networkProc.running = true
  }
}
