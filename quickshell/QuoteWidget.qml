import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "templates"
import "themes"

ThreeRowWidget {
  id: quoteWidget

  title: "󰭺  Quote of the Day"

  property string quoteText: ""
  property string quoteAuthor: ""

  PollProcess {
    id: quoteProc
    command: ["bash", "-c", "shuf -n 1 " + root.home + "/.config/quickshell/quotes.txt"]
    interval: 3600000
    onOutput: text => {
      if (text && text.includes('|')) {
        let parts = text.split('|')
        quoteWidget.quoteText = parts[0]
        quoteWidget.quoteAuthor = parts[1] || "Isaac Asimov"
      }
    }
  }

  middleContent: Component {
    Text {
      text: quoteWidget.quoteText || "Loading..."
      color: Theme.colors.textPrimary
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
      color: Theme.colors.blue
      font.pixelSize: 12
      font.bold: true
      horizontalAlignment: Text.AlignRight
    }
  }
}
