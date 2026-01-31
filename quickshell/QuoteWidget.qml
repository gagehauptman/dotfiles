import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

Item {
  id: quoteWidget
  
  implicitHeight: 190
  
  property string quoteText: ""
  property string quoteAuthor: ""
  
  // Quote fetcher - reads from local file
  Process {
    id: quoteProc
    command: ["bash", "-c", "shuf -n 1 /storage/git/dotfiles/quickshell/quotes.txt"]
    running: true
    
    stdout: StdioCollector {
      onStreamFinished: {
        let result = this.text.trim()
        if (result && result.includes('|')) {
          let parts = result.split('|')
          quoteWidget.quoteText = parts[0]
          quoteWidget.quoteAuthor = parts[1] || "Isaac Asimov"
        }
      }
    }
  }
  
  Timer {
    interval: 3600000 // Refresh every hour
    running: true
    repeat: true
    onTriggered: quoteProc.running = true
  }
  
  Rectangle {
    anchors.fill: parent
    color: "#181825"
    radius: 15
    clip: true
    
    ColumnLayout {
      id: quoteColumn
      anchors {
        fill: parent
        margins: 15
      }
      spacing: 10
      
      // Title
      Text {
        text: "  Quote of the Day"
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
      
      // Quote text
      Text {
        text: quoteWidget.quoteText || "Loading..."
        color: "#cdd6f4"
        font.pixelSize: 13
        font.italic: true
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
        Layout.fillHeight: true
        verticalAlignment: Text.AlignVCenter
      }
      
      // Author
      Text {
        visible: quoteWidget.quoteAuthor !== ""
        text: "— " + quoteWidget.quoteAuthor
        color: "#89b4fa"
        font.pixelSize: 12
        font.bold: true
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignRight
      }
    }
  }
  
  Component.onCompleted: {
    // Trigger initial fetch
    quoteProc.running = true
  }
}
