import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "templates"
import "themes"

ThreeRowWidget {
  id: quoteWidget

  title: "󰭺  Quote of the Day"
  // The quote fills the middle slot and shrinks its font to fit (Text.Fit).
  middleFills: true

  property string quoteText: ""
  property string quoteAuthor: ""

  PollProcess {
    id: quoteProc
    command: ["bash", "-c", "shuf -n 1 " + root.home + "/.config/quickshell/quotes.txt"]
    interval: 3600000
    shared: false   // each screen keeps drawing its own quote (PollHub would hand both the same one)
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
      font.family: Theme.fonts.display
      text: quoteWidget.quoteText || "Loading..."
      color: Theme.colors.textPrimary
      // Largest size that fits the slot, never below fontTiny; a tall slot allows bigger text
      font.pixelSize: Math.round(quoteWidget.fs(metrics.fontLarge) * (quoteWidget.middleHeight > metrics.s(150) ? 1.5 : 1))
      fontSizeMode: Text.Fit
      minimumPixelSize: metrics.fontTiny
      font.italic: true
      wrapMode: Text.WordWrap
      elide: Text.ElideRight
      verticalAlignment: Text.AlignVCenter
    }
  }

  footerContent: Component {
    Text {
      font.family: Theme.fonts.ui
      visible: quoteWidget.quoteAuthor !== ""
      text: "— " + quoteWidget.quoteAuthor
      color: Theme.colors.blue
      font.pixelSize: quoteWidget.fs(metrics.fontSmall)
      font.bold: true
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideLeft
    }
  }
}
