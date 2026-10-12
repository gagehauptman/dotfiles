// Music tab centrepiece: a turntable (MusicTurntable: the cover spins as the
// record's label, tonearm, progress ring, glow), track, transport and progress
// on top, a wide spectrum underneath (MusicLevels.wide, the same analyzer as the bar's
// little visualizer). Track data from NowPlaying (Cider / MPRIS), polled only
// while this card is on screen.

import QtQuick
import QtQuick.Layouts
import Quickshell.Widgets
import "templates"
import "themes"

Item {
  id: stage

  visible: bar.state === "dashboard"
  property var options: ({})

  readonly property real k: metrics.cardScale(width, height, 560, 600)
  function fs(px) { return Math.max(Math.round(px * k), Math.min(px, metrics.fontTiny)) }
  readonly property real pad: Math.round(metrics.spacingLarge * Math.min(k, 1.4))

  // Feeds this card keeps running while it is on screen
  readonly property bool shown: visible && width > 0
  readonly property bool vizActive: shown && NowPlaying.playing
  property bool npReg: false
  property bool vizReg: false
  function sync() {
    if (shown !== npReg) { npReg = shown; NowPlaying.users += shown ? 1 : -1; NowPlaying.clockUsers += shown ? 1 : -1 }
    if (vizActive !== vizReg) { vizReg = vizActive; MusicLevels.users += vizActive ? 1 : -1 }
  }
  onShownChanged: sync()
  onVizActiveChanged: sync()
  Component.onCompleted: sync()
  Component.onDestruction: {
    if (npReg) { NowPlaying.users -= 1; NowPlaying.clockUsers -= 1 }
    if (vizReg) MusicLevels.users -= 1
  }

  function time(s) {
    s = Math.max(0, Math.floor(s))
    return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0")
  }
  function mix(a, b, t) { return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1) }

  // Bass (lowest spectrum bands) for the turntable glow; 0 while paused
  readonly property real bass: vizActive ? Math.min(1, ((MusicLevels.wide[0] || 0) + (MusicLevels.wide[1] || 0) + (MusicLevels.wide[2] || 0)) / 3) : 0

  // Accent sampled from the cover once per track: the dominant colourful hue,
  // lifted to the theme's pastel lightness. Greyscale covers keep the theme pink.
  property color sampled: "transparent"
  onSampledChanged: NowPlaying.artAccent = sampled
  property color accent: sampled.a > 0 ? sampled : Theme.colors.pink
  Behavior on accent { enabled: !Theme.fading; ColorAnimation { duration: 700; easing.type: Easing.InOutQuad } }
  Canvas {
    id: sampler
    width: 24; height: 24
    opacity: 0.001          // must stay "visible" to paint
    property string url: NowPlaying.hasTrack ? NowPlaying.art : ""
    property string loaded: ""
    onUrlChanged: {
      if (loaded !== "") unloadImage(loaded)
      loaded = url
      if (url === "") stage.sampled = "transparent"
      else if (isImageLoaded(url)) requestPaint()
      else loadImage(url)
    }
    onImageLoaded: requestPaint()
    Component.onCompleted: if (url !== "") { loaded = url; loadImage(url) }
    onPaint: {
      if (url === "" || !isImageLoaded(url)) return
      let c = getContext("2d")
      c.clearRect(0, 0, width, height)
      c.drawImage(url, 0, 0, width, height)
      let px = c.getImageData(0, 0, width, height).data
      let bins = new Array(12).fill(0), sums = []
      for (let i = 0; i < 12; i++) sums.push({ r: 0, g: 0, b: 0 })
      let total = 0
      for (let i = 0; i < px.length; i += 4) {
        let col = Qt.rgba(px[i] / 255, px[i + 1] / 255, px[i + 2] / 255, 1)
        let s = col.hslSaturation, l = col.hslLightness, h = col.hslHue
        if (h < 0) continue
        let w = s * s * Math.max(0, 1 - Math.abs(l - 0.55) * 1.8)
        let b = Math.floor(h * 12) % 12
        bins[b] += w; total += w
        sums[b].r += col.r * w; sums[b].g += col.g * w; sums[b].b += col.b * w
      }
      let best = 0
      for (let i = 1; i < 12; i++) if (bins[i] > bins[best]) best = i
      // too little colour to call it (b/w or near-grey covers)
      if (bins[best] < 2.5) { stage.sampled = "transparent"; return }
      let w = bins[best]
      let avg = Qt.rgba(sums[best].r / w, sums[best].g / w, sums[best].b / w, 1)
      let light = Theme.colors.isDark ? 0.76 : 0.45
      stage.sampled = Qt.hsla(avg.hslHue, Math.min(0.85, Math.max(0.45, avg.hslSaturation)), light, 1)
    }
  }

  Rectangle {
    anchors.fill: parent
    color: Theme.colors.panel
    radius: metrics.radiusLarge
    border.width: Theme.cardFrameOpacity > 0 ? Theme.bw(1) : 0
    border.color: Theme.cardFrame

    ColumnLayout {
      anchors.fill: parent
      anchors.margins: stage.pad
      spacing: Math.round(metrics.spacingNormal * Math.min(stage.k, 1.4))

      // Title line: label left, source right
      RowLayout {
        Layout.fillWidth: true
        Text {
          Layout.fillWidth: true
          text: "󰎆  Now Playing"
          color: Theme.colors.textSecondary
          font.pixelSize: stage.fs(Math.round(metrics.fontNormal * 0.9))
          font.family: Theme.fonts.mono
          font.capitalization: Font.AllUppercase
          font.letterSpacing: Theme.titleTracking
          elide: Text.ElideRight
        }
        Text {
          text: NowPlaying.hasTrack ? (NowPlaying.player + " · " + (NowPlaying.playing ? "live" : "hold")).toUpperCase() : "NO SIGNAL"
          color: NowPlaying.playing ? Theme.colors.green : Theme.colors.textMuted
          font.pixelSize: stage.fs(metrics.fontTiny)
          font.family: Theme.fonts.mono
          font.letterSpacing: Theme.titleTracking
        }
      }

      Rectangle { Layout.fillWidth: true; height: bar.dividerThickness; color: Theme.colors.border }

      // Art + track + transport
      RowLayout {
        id: infoRow
        Layout.fillWidth: true
        readonly property real artSize: Math.round(Math.min(stage.width * 0.36, stage.height * 0.46))
        // explicit: the spacers inside would otherwise make this row take all the height
        Layout.fillHeight: false
        Layout.preferredHeight: artSize
        Layout.maximumHeight: artSize
        spacing: stage.pad

        MusicTurntable {
          Layout.preferredWidth: implicitWidth
          Layout.preferredHeight: infoRow.artSize
          art: NowPlaying.hasTrack ? NowPlaying.art : ""
          playing: NowPlaying.playing
          hasTrack: NowPlaying.hasTrack
          active: stage.shown
          progress: NowPlaying.progress
          level: stage.bass
          accent: stage.accent
          trackKey: NowPlaying.trackKey
        }

        ColumnLayout {
          id: trackInfo
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: Math.round(metrics.spacingTiny * Math.min(stage.k, 1.4))
          // new track: the text fades up into place
          transform: Translate { id: infoShift }
          Connections {
            target: NowPlaying
            function onTrackKeyChanged() { if (stage.shown && NowPlaying.trackKey !== "") infoIn.restart() }
          }
          ParallelAnimation {
            id: infoIn
            NumberAnimation { target: trackInfo; property: "opacity"; from: 0; to: 1; duration: 420; easing.type: Motion.easeIn }
            NumberAnimation { target: infoShift; property: "y"; from: metrics.s(10); to: 0; duration: 520; easing.type: Easing.OutBack }
          }

          Item { Layout.fillHeight: true }
          Text {
            Layout.fillWidth: true
            text: NowPlaying.hasTrack ? NowPlaying.title : "Nothing playing"
            color: NowPlaying.hasTrack ? Theme.colors.textPrimary : Theme.colors.textMuted
            font.pixelSize: stage.fs(metrics.fontXL * 0.85)
            font.family: Theme.fonts.display
            font.bold: true
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
          }
          Text {
            Layout.fillWidth: true
            visible: NowPlaying.hasTrack && NowPlaying.artist !== ""
            text: NowPlaying.artist
            color: stage.accent
            font.pixelSize: stage.fs(metrics.fontLarge)
            font.family: Theme.fonts.ui
            elide: Text.ElideRight
          }
          Text {
            Layout.fillWidth: true
            visible: NowPlaying.hasTrack && NowPlaying.album !== ""
            text: NowPlaying.album
            color: Theme.colors.textSecondary
            font.pixelSize: stage.fs(metrics.fontNormal)
            font.family: Theme.fonts.ui
            font.italic: true
            elide: Text.ElideRight
          }
          Item { Layout.fillHeight: true }

          // Transport: previous / play-pause / next, drawn as shapes
          Row {
            id: transport
            visible: NowPlaying.hasTrack
            spacing: metrics.spacingLarge
            readonly property real glyph: stage.fs(metrics.fontNormal)
            Repeater {
              model: ["previous", "toggle", "next"]
              Item {
                id: btn
                required property string modelData
                width: transport.glyph * 2
                height: transport.glyph * 2
                Rectangle {
                  anchors.fill: parent
                  radius: width / 2
                  color: btn.modelData === "toggle" ? Qt.rgba(stage.accent.r, stage.accent.g, stage.accent.b, btnMouse.containsMouse ? 0.28 : 0.16) : "transparent"
                  border.width: Theme.bw(1)
                  border.color: btnMouse.containsMouse ? stage.accent : Theme.cardFrame
                }
                PlayGlyph {
                  anchors.centerIn: parent
                  size: Math.round(transport.glyph * (btn.modelData === "toggle" ? 0.8 : 0.65))
                  kind: btn.modelData === "toggle" ? (NowPlaying.playing ? "pause" : "play") : btn.modelData
                  color: btnMouse.containsMouse ? Theme.colors.yellow : stage.accent
                }
                MouseArea {
                  id: btnMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: NowPlaying.control(btn.modelData)
                }
              }
            }
          }

          // Progress
          Item {
            Layout.fillWidth: true
            visible: NowPlaying.hasTrack && NowPlaying.length > 0
            implicitHeight: timeRow.implicitHeight + metrics.spacingSmall + track.height
            Rectangle {
              id: track
              width: parent.width
              height: Math.max(2, metrics.s(3))
              radius: height / 2
              color: Theme.colors.inset
              Rectangle {
                id: fill
                width: parent.width * Math.min(1, NowPlaying.progress)
                height: parent.height
                radius: parent.radius
                color: stage.accent
              }
              // play head: a soft halo around a dot at the end of the fill
              Rectangle {
                x: fill.width - width / 2; anchors.verticalCenter: parent.verticalCenter
                width: parent.height * 5; height: width; radius: width / 2
                color: stage.accent
                opacity: NowPlaying.playing ? 0.22 : 0
                Behavior on opacity { NumberAnimation { duration: Motion.std } }
              }
              Rectangle {
                x: fill.width - width / 2; anchors.verticalCenter: parent.verticalCenter
                width: parent.height * 2.6; height: width; radius: width / 2
                color: stage.accent
              }
            }
            Item {
              id: timeRow
              anchors.top: track.bottom
              anchors.topMargin: metrics.spacingSmall
              width: parent.width
              implicitHeight: elapsed.implicitHeight
              Text {
                id: elapsed
                text: stage.time(NowPlaying.position)
                color: Theme.colors.textSecondary
                font.pixelSize: stage.fs(metrics.fontTiny)
                font.family: Theme.fonts.mono
                font.features: { "tnum": 1, "lnum": 1 }
              }
              Text {
                anchors.right: parent.right
                text: "−" + stage.time(NowPlaying.length - NowPlaying.position)
                color: Theme.colors.textMuted
                font.pixelSize: stage.fs(metrics.fontTiny)
                font.family: Theme.fonts.mono
                font.features: { "tnum": 1, "lnum": 1 }
              }
            }
          }
        }
      }

      // Spectrum: bars rise from a baseline with a faint reflection below it and
      // slowly falling peak marks; falls flat on pause or when the feed goes quiet.
      Item {
        id: viz
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.minimumHeight: stage.height * 0.3
        Layout.topMargin: metrics.spacingSmall
        clip: true
        readonly property int n: MusicLevels.wideCount
        readonly property real gap: Math.max(2, Math.round(metrics.s(4) * Math.min(stage.k, 1.3)))
        readonly property real barW: Math.max(2, (width - gap * (n - 1)) / n)
        readonly property real base: Math.round(height * 0.78)

        // scale lines
        Repeater {
          model: 3
          Rectangle {
            required property int index
            y: Math.round(viz.base * (index + 1) / 4)
            width: viz.width
            height: 1
            color: Theme.cardFrame
            opacity: 0.6
          }
        }

        // fades the spectrum out (and back in) on pause/play rather than snapping it
        property real gain: stage.vizActive ? 1 : 0
        Behavior on gain { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }

        Repeater {
          model: viz.n
          Item {
            id: band
            required property int index
            readonly property real amp: viz.gain > 0 ? (MusicLevels.wide[index] || 0) * viz.gain : 0
            property real peak: 0
            onAmpChanged: peak = amp > 0 ? Math.max(amp, peak - 0.03) : 0
            // the cover's accent on the bass side, sliding to an analogous hue up the treble
            readonly property color tint: {
              let a = stage.accent, t = index / (viz.n - 1)
              return a.hslHue < 0 ? a : Qt.hsla((a.hslHue - 0.16 * t + 1) % 1, a.hslSaturation, a.hslLightness - 0.06 * t, 1)
            }
            readonly property real h: Math.max(2, band.amp * (viz.base - metrics.s(18)))
            x: index * (viz.barW + viz.gap)
            width: viz.barW
            height: viz.height

            Rectangle {
              x: 0; y: viz.base - band.h
              width: band.width; height: band.h
              radius: Math.min(2, width / 2)
              color: band.tint
              opacity: 0.45 + band.amp * 0.5
            }
            // reflection
            Rectangle {
              x: 0; y: viz.base + metrics.s(2)
              width: band.width; height: Math.min(viz.height - viz.base - metrics.s(2), band.h * 0.35)
              radius: Math.min(2, width / 2)
              color: band.tint
              opacity: 0.12
            }
            // peak mark
            Rectangle {
              visible: band.peak > 0.04
              x: 0; y: viz.base - Math.max(2, band.peak * (viz.base - metrics.s(18))) - metrics.s(4)
              width: band.width; height: Math.max(1, metrics.s(2))
              color: band.tint
              opacity: 0.8
            }
          }
        }
        // baseline
        Rectangle { y: viz.base; width: viz.width; height: 1; color: Theme.colors.border }
      }
    }
  }
}
