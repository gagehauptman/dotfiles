import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

Item {
  id: musicWidget
  
  property bool showWidget: bar.state === "normal" || bar.state === "dashboard"
  property bool isDashboard: bar.state === "dashboard"
  
  visible: showWidget
  implicitWidth: isDashboard ? 600 : 400
  implicitHeight: 30
  
  Behavior on implicitWidth {
    NumberAnimation {
      duration: 100
      easing.type: Easing.OutQuint
    }
  }
  
  // Music listener
  Process {
    id: musicProc
    command: ["playerctl", "--follow", "metadata", "--player=spotify", "--format", "{{xesam:artist}} // {{xesam:title}}"]
    running: true
    
    stdout: SplitParser {
      onRead: data => {
        let lines = data.split('\n').filter(l => l.trim())
        if (lines.length > 0) {
          musicWidget.musicText = lines[lines.length - 1].trim()
          musicWidget.hasMusic = true
        }
      }
    }
    
    onRunningChanged: {
      if (!running) {
        // playerctl stopped, no music
        musicWidget.hasMusic = false
      }
    }
  }
  
  // Weather poller
  Process {
    id: weatherProc
    command: ["bash", "/storage/git/dotfiles/scripts/polls/weatherpoll.sh"]
    running: true
    
    stdout: StdioCollector {
      onStreamFinished: musicWidget.weatherText = this.text.trim()
    }
  }
  
  Timer {
    interval: 300000 // 5 minutes
    running: true
    repeat: true
    onTriggered: weatherProc.running = true
  }
  
  property string musicText: ""
  property string weatherText: "Loading weather..."
  property bool hasMusic: false
  
  Rectangle {
    anchors.fill: parent
    color: "transparent"
    
    Text {
      anchors.centerIn: parent
      text: {
        if (musicWidget.hasMusic && musicWidget.musicText) {
          return "♫ " + musicWidget.musicText
        } else if (musicWidget.weatherText) {
          return musicWidget.weatherText
        }
        return "..."
      }
      color: musicWidget.hasMusic ? "#f5c2e7" : "#89dceb"  // Pink for music, Sky blue for weather
      font.pixelSize: 13
      font.bold: false
      elide: Text.ElideRight
      width: parent.width - 20
      horizontalAlignment: Text.AlignHCenter
    }
  }
  
  Component.onCompleted: {
    // Trigger initial weather fetch
    weatherProc.running = true
  }
}
