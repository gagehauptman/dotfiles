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
    command: ["playerctl", "--follow", "metadata", "--player=spotifyd,%any", "--format", "{{playerName}}|||{{xesam:artist}} // {{xesam:title}}"]
    running: true
    
    stdout: SplitParser {
      onRead: data => {
        let lines = data.split('\n').filter(l => l.trim())
        if (lines.length > 0) {
          let parts = lines[lines.length - 1].trim().split("|||")
          if (parts.length >= 2) {
            musicWidget.musicPlayer = parts[0].trim().toLowerCase()
            musicWidget.musicText = parts[1].trim()
          } else {
            musicWidget.musicText = lines[lines.length - 1].trim()
          }
          musicWidget.hasMusic = true
        }
      }
    }
    
    onRunningChanged: {
      if (!running) {
        musicWidget.hasMusic = false
      }
    }
    
    onExited: (code, status) => {
      // Restart after delay when playerctl exits
      musicRestartTimer.start()
    }
  }
  
  Timer {
    id: musicRestartTimer
    interval: 3000
    repeat: false
    onTriggered: musicProc.running = true
  }
  
  // Status checker - detects when Spotify closes
  Process {
    id: statusProc
    command: ["playerctl", "status", "--player=spotifyd,%any"]
    
    stdout: SplitParser {
      onRead: data => {
        let status = data.trim()
        if (status !== "Playing" && status !== "Paused") {
          musicWidget.hasMusic = false
        }
      }
    }
    
    onExited: (code, status) => {
      // playerctl exits with error when no player exists
      if (code !== 0) {
        musicWidget.hasMusic = false
      }
    }
  }
  
  Timer {
    interval: 2000
    running: true
    repeat: true
    onTriggered: statusProc.running = true
  }
  
  // Launch data poller - uses Launch Library 2 API
  // Filter for Go/TBD/TBC status only (excludes completed launches)
  Process {
    id: launchProc
    command: ["curl", "-s", "https://ll.thespacedevs.com/2.2.0/launch/upcoming/?limit=5&mode=list"]
    running: true
    
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          let data = JSON.parse(this.text)
          if (data.results && data.results.length > 0) {
            // Find first launch that hasn't happened yet
            let now = new Date()
            let launch = data.results.find(l => {
              let net = new Date(l.net)
              // Must be in future AND not already successful/failed
              let status = l.status?.id
              return net > now && (status === 1 || status === 2 || status === 5 || status === 8)
            })
            
            if (!launch) launch = data.results.find(l => new Date(l.net) > now)
            if (!launch) launch = data.results[0]
            
            musicWidget.launchName = launch.name || "Unknown"
            musicWidget.launchTime = launch.net ? new Date(launch.net) : null
            musicWidget.launchProvider = launch.launch_service_provider?.name || ""
          }
        } catch (e) {
          musicWidget.launchName = "Launch data unavailable"
          musicWidget.launchTime = null
        }
      }
    }
  }
  
  Timer {
    interval: 600000 // 10 minutes
    running: true
    repeat: true
    onTriggered: launchProc.running = true
  }
  
  // Countdown update timer
  Timer {
    interval: 1000
    running: musicWidget.launchTime !== null
    repeat: true
    onTriggered: musicWidget.updateCountdown()
  }
  
  property string musicText: ""
  property string musicPlayer: ""
  property bool hasMusic: false
  
  property string launchName: "Loading launch data..."
  property var launchTime: null
  property string launchProvider: ""
  property string countdownText: ""
  
  function updateCountdown() {
    if (!launchTime) {
      countdownText = ""
      return
    }
    
    let now = new Date()
    let diff = launchTime.getTime() - now.getTime()
    
    if (diff <= 0) {
      countdownText = "Launching now!"
      return
    }
    
    let days = Math.floor(diff / (1000 * 60 * 60 * 24))
    let hours = Math.floor((diff % (1000 * 60 * 60 * 24)) / (1000 * 60 * 60))
    let mins = Math.floor((diff % (1000 * 60 * 60)) / (1000 * 60))
    let secs = Math.floor((diff % (1000 * 60)) / 1000)
    
    if (days > 0) {
      countdownText = "T-" + days + "d " + hours + "h " + mins + "m"
    } else if (hours > 0) {
      countdownText = "T-" + hours + "h " + mins + "m " + secs + "s"
    } else {
      countdownText = "T-" + mins + "m " + secs + "s"
    }
  }
  
  Rectangle {
    anchors.fill: parent
    color: "transparent"
    
    Text {
      anchors.centerIn: parent
      text: {
        if (musicWidget.hasMusic && musicWidget.musicText) {
          let icon = (musicWidget.musicPlayer.indexOf("spotify") !== -1) ? " " : "♫ "
          return icon + musicWidget.musicText
        } else if (musicWidget.launchName) {
          let display = "🚀 " + musicWidget.countdownText
          let name = musicWidget.launchName
          if (name.length > 40) name = name.substring(0, 37) + "..."
          return display + " • " + name
        }
        return "..."
      }
      color: musicWidget.hasMusic ? "#f5c2e7" : "#fab387"
      font.pixelSize: 13
      font.bold: false
      elide: Text.ElideRight
      width: parent.width - 20
      horizontalAlignment: Text.AlignHCenter
    }
  }
  
  Component.onCompleted: {
    launchProc.running = true
    updateCountdown()
  }
}
