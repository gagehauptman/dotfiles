import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "templates"

ThreeRowWidget {
  id: quoteWidget

  title: "󰭺  Quote of the Day"

  property string quoteText: ""
  property string quoteAuthor: ""

  Process {
    id: quoteProc
    command: ["bash", "-c", "shuf -n 1 " + root.home + "/.config/quickshell/quotes.txt"]
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
    interval: 3600000
    running: true
    repeat: true
    onTriggered: quoteProc.running = true
  }

  middleContent: Component {
    Text {
      text: quoteWidget.quoteText || "Loading..."
      color: "#cdd6f4"
      font.pixelSize: 13
      font.italic: true
      wrapMode: Text.WordWrap
      verticalAlignment: Text.AlignVCenter
    }
  }

  footerContent: Component {
    Text {
      visible: quoteWidget.quoteAuthor !== ""
      text: "— " + quoteWidget.quoteAuthor
      color: "#89b4fa"
      font.pixelSize: 12
      font.bold: true
      horizontalAlignment: Text.AlignRight
    }
  }

  Component.onCompleted: {
    quoteProc.running = true
  }
}
