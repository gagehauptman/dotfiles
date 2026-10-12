import QtQuick
import QtQuick.Shapes
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "templates"
import "themes"

Item {
  id: musicWidget
  
  // also while the control center is open: its pocket sits at the far end under the clock, not over this slot
  property bool showWidget: (bar.state === "normal" || bar.state === "dashboard" || bar.state === "control_center") && !root.voiceActive
  property bool isDashboard: bar.state === "dashboard"
  // Vertical bar is too thin for the scrolling text; show an icon only there.
  property bool isVertical: false

  // Dashboard card mode (set through the "music" entry of the widget registry
  // in DashboardConfig.qml): draws a panel with title/track/launch rows
  // instead of the bare bar text. The grid sizes the card; only the text
  // size is configurable: options.size = "small" | "normal" | "large".
  property bool card: false
  property var options: ({})
  readonly property real cardFontSize: options.size === "large" ? metrics.fontXL
                                     : options.size === "small" ? metrics.fontSmall
                                     : metrics.fontLarge
  // Card fit: text scales with the cell (designed for 2 columns x 1.5 rows in
  // the minimal preset); the player line, then the launch line, are dropped
  // when it gets short, and the track takes the lines that are left.
  readonly property real k: card ? metrics.cardScale(width, height, 490, 250) : 1
  readonly property bool cardShowStatus: height >= metrics.s(170)
  readonly property bool cardShowLaunch: height >= metrics.s(130)

  visible: card ? isDashboard : showWidget
  // Bar mode: capped to a share of the bar so it can't run into the side clusters on small screens
  implicitWidth: isVertical ? parent.width : Math.min(isDashboard ? metrics.s(600) : metrics.s(400), metrics.barLength * (isDashboard ? 0.3 : 0.22))
  implicitHeight: metrics.s(30)
  
  Behavior on implicitWidth {
    NumberAnimation {
      duration: 100
      easing.type: Easing.OutQuint
    }
  }
  
  function resetMusicState() {
    activePlayer = ""
    playbackStatus = ""
    musicText = ""
    hasMusic = false
  }
  
  // A reading of "nothing playing" only takes effect after it has held for a few
  // seconds: Cider's API stalls past ciderpoll's timeout now and then, and MPRIS
  // reports Stopped/empty between tracks; switching at once flashed the launch countdown.
  Timer {
    id: musicGrace
    interval: 4000
    onTriggered: musicWidget.resetMusicState()
  }
  function noMusic() {
    if (!hasMusic) resetMusicState()
    else if (!musicGrace.running) musicGrace.start()
  }

  property string musicFieldSeparator: "<QSMUSIC>"
  
  function updateMusicState(line) {
    let parts = line.split(musicFieldSeparator)
    if (parts.length < 4) {
      noMusic()
      return
    }
    
    let player = parts[0].trim()
    // Cider (Electron) shows up as "chromium" with empty MPRIS metadata; read its API instead.
    ciderActive = player === "chromium" || player === "Cider"
    if (player === "chromium") {
      ciderProc.running = true
      return
    }
    let status = parts[1].trim()
    let artist = parts[2].trim()
    let title = parts.slice(3).join(musicFieldSeparator).trim()
    if (!player || (status !== "Playing" && status !== "Paused")) {
      noMusic()
      return
    }
    musicGrace.stop()
    let textParts = []
    
    if (artist) textParts.push(artist)
    if (title) textParts.push(title)
    
    activePlayer = player
    playbackStatus = status
    musicText = textParts.length > 0 ? textParts.join(" // ") : player
    hasMusic = player.length > 0 && (status === "Playing" || status === "Paused")
  }
  
  // Music listener
  Process {
    id: musicProc
    command: ["playerctl", "--follow", "metadata", "--player=spotifyd,%any", "--format", "{{playerName}}<QSMUSIC>{{status}}<QSMUSIC>{{xesam:artist}}<QSMUSIC>{{xesam:title}}"]
    running: true
    
    stdout: SplitParser {
      onRead: data => {
        let lines = data.split('\n').filter(l => l.trim())
        if (lines.length > 0) {
          musicWidget.updateMusicState(lines[lines.length - 1].trim())
        }
      }
    }
    
    onRunningChanged: {
      if (!running) {
        musicWidget.noMusic()
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
  
  // Cider now-playing poller; only used while Cider is the active player.
  PollProcess {
    id: ciderProc
    command: ["bash", root.home + "/.config/scripts/polls/ciderpoll.sh"]
    interval: 3000
    poll: musicWidget.ciderActive
    onOutput: text => {
      if (!musicWidget.ciderActive) return
      if (text) musicWidget.updateMusicState(text)
      else musicWidget.noMusic()
    }
  }
  
  Process {
    id: togglePlaybackProc
    command: musicWidget.activePlayer === "Cider"
      ? ["curl", "-s", "-X", "POST", "http://127.0.0.1:10767/api/v1/playback/playpause"]
      : ["playerctl", "--player=" + (musicWidget.activePlayer || "spotifyd,%any"), "play-pause"]
  }
  
  // Launch data poller - uses Launch Library 2 API
  // Filter for Go/TBD/TBC status only (excludes completed launches)
  PollProcess {
    id: launchProc
    command: ["curl", "-s", "https://ll.thespacedevs.com/2.2.0/launch/upcoming/?limit=5&mode=list"]
    interval: 600000 // 10 minutes
    onOutput: text => {
      try {
        let data = JSON.parse(text)
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
        }
      } catch (e) {
        musicWidget.launchName = "Launch data unavailable"
        musicWidget.launchTime = null
      }
    }
  }
  
  // Countdown update timer
  Timer {
    interval: 1000
    running: musicWidget.launchTime !== null
    repeat: true
    onTriggered: musicWidget.updateCountdown()
  }
  
  property string musicText: ""
  readonly property bool showTrack: hasMusic && musicText !== ""
  property string activePlayer: ""
  property string playbackStatus: ""
  property bool hasMusic: false
  property bool ciderActive: false
  
  property string launchName: "Loading launch data..."
  property var launchTime: null
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
    color: musicWidget.card ? Theme.colors.panel : "transparent"
    radius: musicWidget.card ? metrics.radiusLarge : 0
    clip: musicWidget.card
    
    MouseArea {
      id: musicMouse
      anchors.fill: parent
      enabled: musicWidget.hasMusic
      hoverEnabled: musicWidget.hasMusic
      acceptedButtons: Qt.LeftButton
      cursorShape: musicWidget.hasMusic ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: togglePlaybackProc.running = true
    }
    
    Text {
      font.family: Theme.fonts.ui
      visible: !musicWidget.card && !musicWidget.showTrack
      anchors.centerIn: parent
      text: {
        if (musicWidget.launchName) {
          if (musicWidget.isVertical) return "🚀"
          let display = "🚀 " + musicWidget.countdownText
          let name = musicWidget.launchName
          if (name.length > 40) name = name.substring(0, 37) + "..."
          return display + " • " + name
        }
        return musicWidget.isVertical ? "" : "..."
      }
      color: musicWidget.hasMusic ? (musicMouse.containsMouse ? Theme.colors.yellow : Theme.colors.pink) : Theme.colors.orange
      font.pixelSize: metrics.fontSmall
      font.bold: false
      elide: Text.ElideRight
      width: parent.width - (musicWidget.isVertical ? metrics.s(4) : metrics.s(20))
      horizontalAlignment: Text.AlignHCenter
    }

    // Bar track line: the play/pause icon is drawn as shapes in a fixed-size slot
    // (font glyphs fall back to different fonts with different metrics, which
    // shifted the text).
    Row {
      id: trackRow
      visible: !musicWidget.card && musicWidget.showTrack
      anchors.centerIn: parent
      spacing: metrics.s(6)
      readonly property real maxW: musicWidget.width - (musicWidget.isVertical ? metrics.s(4) : metrics.s(20))
      readonly property color tint: musicWidget.hasMusic ? (musicMouse.containsMouse ? Theme.colors.yellow : Theme.colors.pink) : Theme.colors.orange
      readonly property real lineH: Math.ceil(metrics.fontSmall * 1.4)
      readonly property real iconSize: Math.round(metrics.fontSmall * 0.8)
      Item {
        id: trackIcon
        width: trackRow.iconSize
        height: trackRow.lineH
        Shape {
          anchors.centerIn: parent
          width: trackRow.iconSize
          height: trackRow.iconSize
          visible: musicWidget.playbackStatus === "Paused"
          ShapePath {
            fillColor: trackRow.tint
            strokeColor: "transparent"
            startX: trackRow.iconSize * 0.1; startY: 0
            PathLine { x: trackRow.iconSize; y: trackRow.iconSize / 2 }
            PathLine { x: trackRow.iconSize * 0.1; y: trackRow.iconSize }
            PathLine { x: trackRow.iconSize * 0.1; y: 0 }
          }
        }
        Row {
          anchors.centerIn: parent
          spacing: Math.max(2, Math.round(trackRow.iconSize * 0.2))
          visible: musicWidget.playbackStatus !== "Paused"
          Rectangle { width: Math.max(2, Math.round(trackRow.iconSize * 0.3)); height: trackRow.iconSize; color: trackRow.tint }
          Rectangle { width: Math.max(2, Math.round(trackRow.iconSize * 0.3)); height: trackRow.iconSize; color: trackRow.tint }
        }
      }
      Text {
        visible: !musicWidget.isVertical
        height: trackRow.lineH
        verticalAlignment: Text.AlignVCenter
        width: Math.min(implicitWidth, Math.max(0, trackRow.maxW - trackIcon.width - trackRow.spacing - (musicViz.visible ? musicViz.width + trackRow.spacing : 0)))
        font.family: Theme.fonts.ui
        font.pixelSize: metrics.fontSmall
        font.bold: false
        elide: Text.ElideRight
        text: musicWidget.musicText
        color: trackRow.tint
      }
      // live spectrum bars (flat while paused); see MusicVisualizer.qml
      MusicVisualizer {
        id: musicViz
        visible: !musicWidget.isVertical
        anchors.verticalCenter: parent.verticalCenter
        playing: musicWidget.playbackStatus === "Playing"
        tint: trackRow.tint
      }
    }

    // Card layout (dashboard presets only)
    ColumnLayout {
      visible: musicWidget.card
      anchors {
        verticalCenter: parent.verticalCenter
        left: parent.left
        right: parent.right
        margins: metrics.spacingLarge
      }
      spacing: metrics.spacingSmall

      Text {
        text: "󰎆  Now Playing"
        color: Theme.colors.textPrimary
        font.pixelSize: Math.round(metrics.fontLarge * musicWidget.k)
        font.bold: true
        font.family: Theme.fonts.mono
        Layout.fillWidth: true
        elide: Text.ElideRight
      }

      Rectangle {
        Layout.fillWidth: true
        height: bar.dividerThickness
        color: Theme.colors.border
      }

      Text {
        font.family: Theme.fonts.ui
        Layout.fillWidth: true
        text: (musicWidget.hasMusic && musicWidget.musicText) ? musicWidget.musicText : "Nothing playing"
        color: musicWidget.hasMusic ? (musicMouse.containsMouse ? Theme.colors.yellow : Theme.colors.pink) : Theme.colors.textMuted
        font.pixelSize: Math.round(musicWidget.cardFontSize * musicWidget.k)
        font.bold: true
        wrapMode: Text.WordWrap
        maximumLineCount: musicWidget.height < metrics.s(150) ? 1 : musicWidget.height < metrics.s(220) ? 2 : 3
        elide: Text.ElideRight
      }

      Text {
        font.family: Theme.fonts.ui
        visible: musicWidget.hasMusic && musicWidget.cardShowStatus
        Layout.fillWidth: true
        elide: Text.ElideRight
        text: (musicWidget.playbackStatus === "Paused" ? "▶ Paused" : "⏸ Playing") + " · " + musicWidget.activePlayer
        color: Theme.colors.textSecondary
        font.pixelSize: Math.round(metrics.fontSmall * musicWidget.k)
      }

      Rectangle {
        visible: musicWidget.cardShowLaunch
        Layout.fillWidth: true
        height: bar.dividerThickness
        color: Theme.colors.border
      }

      Text {
        font.family: Theme.fonts.ui
        visible: musicWidget.cardShowLaunch
        Layout.fillWidth: true
        text: "🚀 " + musicWidget.countdownText + " • " + musicWidget.launchName
        color: Theme.colors.orange
        font.pixelSize: Math.round(metrics.fontSmall * musicWidget.k)
        elide: Text.ElideRight
      }
    }
  }
  
  Component.onCompleted: updateCountdown()
}
