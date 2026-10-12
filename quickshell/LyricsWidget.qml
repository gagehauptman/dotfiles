// Synced lyrics readout for the music tab (Lyrics.qml: Apple Music via Cider, else
// LRCLIB). The line being sung sits in the middle, large, bright and in the
// accent sampled from the cover (shared with the turntable through
// NowPlaying.artAccent); sung lines dim more than upcoming ones, and everything
// fades out towards the top and bottom edges. On a line change the lines glide
// up in a short cascade (each line eases on its own with a small stagger).
// Instrumental breaks show three dots that fill over the break. Unsynced lyrics
// scroll along with the song; otherwise a centred status (instrumental, no
// lyrics, ...). Nothing animates unless the card is showing and the track plays.

import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import "templates"
import "themes"

Item {
  id: lyricsCard

  visible: bar.state === "dashboard"
  property var options: ({})

  readonly property real k: metrics.cardScale(width, height, 560, 600)
  function fs(px) { return Math.max(Math.round(px * k), Math.min(px, metrics.fontTiny)) }
  readonly property real pad: Math.round(metrics.spacingLarge * Math.min(k, 1.4))
  // Highlight a touch early: a line reads better arriving with the voice than after it.
  readonly property real lead: options.lead ?? 0.25

  readonly property bool shown: visible && width > 0
  property bool registered: false
  function sync() {
    if (shown === registered) return
    registered = shown
    let d = shown ? 1 : -1
    NowPlaying.users += d
    NowPlaying.clockUsers += d
    Lyrics.users += d
  }
  onShownChanged: sync()
  Component.onCompleted: sync()
  Component.onDestruction: if (registered) { NowPlaying.users -= 1; NowPlaying.clockUsers -= 1; Lyrics.users -= 1 }

  readonly property bool synced: Lyrics.status === "synced"
  readonly property int index: synced ? Lyrics.indexAt(NowPlaying.position + lead) : -1
  // Motion runs only while this is on screen and the track plays
  readonly property bool animating: shown && NowPlaying.playing

  // Same colour as the turntable (cover-sampled), else the theme pink like it
  property color accent: NowPlaying.artAccent.a > 0 ? NowPlaying.artAccent : Theme.colors.pink
  Behavior on accent { enabled: !Theme.fading; ColorAnimation { duration: 700; easing.type: Easing.InOutQuad } }
  function tint(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  readonly property string sourceName: Lyrics.source === "apple" ? "APPLE MUSIC" : Lyrics.source !== "" ? "LRCLIB" : ""

  function smooth(x) { x = Math.max(0, Math.min(1, x)); return x * x * (3 - 2 * x) }

  Rectangle {
    anchors.fill: parent
    color: Theme.colors.panel
    radius: metrics.radiusLarge
    border.width: Theme.cardFrameOpacity > 0 ? Theme.bw(1) : 0
    border.color: Theme.cardFrame

    ColumnLayout {
      anchors.fill: parent
      anchors.margins: lyricsCard.pad
      spacing: Math.round(metrics.spacingNormal * Math.min(lyricsCard.k, 1.4))

      RowLayout {
        Layout.fillWidth: true
        spacing: metrics.spacingSmall
        Text {
          Layout.fillWidth: true
          text: "󰍡  Lyrics"
          color: Theme.colors.textSecondary
          font.pixelSize: lyricsCard.fs(Math.round(metrics.fontNormal * 0.9))
          font.family: Theme.fonts.mono
          font.capitalization: Font.AllUppercase
          font.letterSpacing: Theme.titleTracking
          elide: Text.ElideRight
        }
        // source chip: accent dot + "SYNCED · APPLE MUSIC"
        Rectangle {
          visible: chipText.text !== ""
          width: lyricsCard.fs(6); height: width; radius: width / 2
          color: lyricsCard.synced ? lyricsCard.accent : Theme.colors.textMuted
        }
        Text {
          id: chipText
          text: Lyrics.status === "loading" ? "ACQUIRING…"
              : Lyrics.status === "synced" ? "SYNCED · " + lyricsCard.sourceName
              : Lyrics.status === "plain" ? "UNSYNCED · " + lyricsCard.sourceName
              : ""
          color: lyricsCard.synced ? lyricsCard.accent : Theme.colors.textMuted
          font.pixelSize: lyricsCard.fs(metrics.fontTiny)
          font.family: Theme.fonts.mono
          font.letterSpacing: Theme.titleTracking
        }
      }

      Rectangle { Layout.fillWidth: true; height: bar.dividerThickness; color: Theme.colors.border }

      Item {
        id: body
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        // lines fade out over this much of the top and bottom
        readonly property real fadeZone: height * 0.26

        // Soft accent spotlight behind the centre, where the current line sits
        Shape {
          anchors.fill: parent
          visible: lyricsCard.synced
          opacity: lyricsCard.index >= 0 ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: Motion.slow; easing.type: Motion.easeAmbient } }
          ShapePath {
            strokeWidth: -1
            fillGradient: RadialGradient {
              centerX: body.width / 2; centerY: body.height / 2
              focalX: centerX; focalY: centerY
              centerRadius: Math.max(body.width * 0.62, 1)
              focalRadius: 0
              GradientStop { position: 0.0; color: lyricsCard.tint(lyricsCard.accent, 0.10) }
              GradientStop { position: 0.45; color: lyricsCard.tint(lyricsCard.accent, 0.035) }
              GradientStop { position: 1.0; color: "transparent" }
            }
            PathRectangle {
              x: body.width / 2 - body.width * 0.62; y: body.height / 2 - body.width * 0.62
              width: body.width * 1.24; height: width
            }
          }
          // squashed vertically into a wide oval
          transform: Scale { origin.x: body.width / 2; origin.y: body.height / 2; yScale: 0.4 }
        }

        // Synced, karaoke style. A Column of all lines (not a ListView) so every
        // line has a real position and wrapped two-line lyrics centre exactly.
        // On a line change contentY jumps to the new target and each nearby line
        // is shifted back to where it was, then eases home with a small stagger.
        Flickable {
          id: list
          anchors.fill: parent
          visible: lyricsCard.synced
          interactive: false
          contentWidth: width
          contentHeight: lyricCol.height
          readonly property int focusIndex: Math.max(0, lyricsCard.index)
          readonly property real basePx: lyricsCard.fs(metrics.fontLarge * 1.6)
          property int lastFocus: 0

          // contentY that puts line i's centre on the middle of the view
          function target(i) {
            let it = lyricRep.itemAt(i)
            return it ? Math.round(it.y + it.height / 2 - height / 2) : 0
          }
          function snap() {
            lastFocus = focusIndex
            for (let i = 0; i < lyricRep.count; i++) { let it = lyricRep.itemAt(i); if (it) it.settle() }
            contentY = target(focusIndex)
          }
          function glide() {
            let from = lastFocus
            lastFocus = focusIndex
            let y = target(focusIndex), d = y - contentY
            if (!lyricsCard.animating || Math.abs(focusIndex - from) > 4) { snap(); return }
            contentY = y
            if (Math.abs(d) < 0.5) return
            let dir = d > 0 ? 1 : -1
            let lo = Math.max(0, focusIndex - 10), hi = Math.min(lyricRep.count - 1, focusIndex + 12)
            for (let i = lo; i <= hi; i++) {
              let it = lyricRep.itemAt(i)
              if (it) it.glide(d, Math.max(0, Math.min(8, (i - focusIndex) * dir + 1)) * 34)
            }
          }
          onFocusIndexChanged: glide()
          onHeightChanged: snap()
          onVisibleChanged: snap()

          Connections {
            target: Lyrics
            // new track: start on the current line and fade the text up
            function onLinesChanged() { Qt.callLater(list.snap); fadeIn.restart() }
          }

          Column {
            id: lyricCol
            width: list.width
            // half a view of air above the first and below the last line
            topPadding: list.height / 2
            bottomPadding: list.height / 2
            spacing: Math.round(list.basePx * 0.62)
            onHeightChanged: Qt.callLater(list.snap)
            NumberAnimation { id: fadeIn; target: lyricCol; property: "opacity"; from: 0; to: 1; duration: 450; easing.type: Easing.OutCubic }

            Repeater {
              id: lyricRep
              model: lyricsCard.synced ? Lyrics.lines : []

              Item {
                id: line
                required property int index
                required property var modelData
                readonly property bool gap: modelData.gap === true
                readonly property int rel: index - list.focusIndex
                readonly property int dist: Math.abs(rel)
                readonly property bool live: index === lyricsCard.index
                width: lyricCol.width
                height: gap ? Math.round(list.basePx * 1.1) : lineText.height

                // glide: offset back to the old spot, then ease home after `delay`
                property real shift: 0
                transform: Translate { y: line.shift }
                function glide(d, delay) {
                  glideAnim.stop()
                  shift += d
                  hold.duration = delay
                  glideAnim.start()
                }
                function settle() { glideAnim.stop(); shift = 0 }
                SequentialAnimation {
                  id: glideAnim
                  PauseAnimation { id: hold; duration: 0 }
                  NumberAnimation { target: line; property: "shift"; to: 0; duration: 620; easing.type: Easing.OutCubic }
                }

                // focus look: sung lines dim more than the ones coming up
                property real focusOpacity: live ? 1
                    : rel < 0 ? Math.max(0.10, 0.30 - (dist - 1) * 0.05)
                    : Math.max(0.16, 0.52 - (dist - 1) * 0.08)
                Behavior on focusOpacity { NumberAnimation { duration: 450; easing.type: Easing.OutCubic } }
                // fade towards the top and bottom edges (where it is drawn, glide included)
                readonly property real viewY: y + shift + height / 2 - list.contentY
                readonly property real edge: lyricsCard.smooth(Math.min(viewY, list.height - viewY) / body.fadeZone)
                opacity: focusOpacity * edge

                transformOrigin: Item.Center
                scale: live ? 1 : 0.82
                Behavior on scale { NumberAnimation { duration: 520; easing.type: Easing.OutBack; easing.overshoot: 1.1 } }

                Text {
                  id: lineText
                  visible: !line.gap
                  anchors.horizontalCenter: parent.horizontalCenter
                  width: parent.width - lyricsCard.pad
                  text: line.gap ? "" : line.modelData.text
                  wrapMode: Text.WordWrap
                  horizontalAlignment: Text.AlignHCenter
                  lineHeight: 1.08
                  // one size and weight for every line so nothing reflows on a
                  // line change; the focus is drawn with scale, colour and opacity
                  font.pixelSize: list.basePx
                  font.family: Theme.fonts.ui
                  font.weight: Font.Bold
                  font.letterSpacing: -0.2
                  color: line.live ? lyricsCard.accent : Theme.colors.textPrimary
                  Behavior on color { enabled: !Theme.fading; ColorAnimation { duration: 380; easing.type: Easing.OutCubic } }
                }

                // Instrumental break: three dots that light up across the break
                Row {
                  id: dots
                  visible: line.gap
                  anchors.centerIn: parent
                  spacing: Math.round(list.basePx * 0.32)
                  readonly property real progress: line.live && line.modelData.e > line.modelData.t
                      ? Math.max(0, Math.min(1, (NowPlaying.position + lyricsCard.lead - line.modelData.t) / (line.modelData.e - line.modelData.t)))
                      : 0
                  SequentialAnimation on scale {
                    running: line.gap && line.live && lyricsCard.animating
                    loops: Animation.Infinite
                    alwaysRunToEnd: true
                    NumberAnimation { to: 1.14; duration: 1100; easing.type: Motion.easeAmbient }
                    NumberAnimation { to: 1.0; duration: 1100; easing.type: Motion.easeAmbient }
                  }
                  Repeater {
                    model: 3
                    Rectangle {
                      required property int index
                      width: Math.round(list.basePx * 0.34); height: width; radius: width / 2
                      color: line.live ? lyricsCard.accent : Theme.colors.textPrimary
                      opacity: line.live ? 0.25 + 0.75 * lyricsCard.smooth(dots.progress * 3 - index) : 0.6
                      Behavior on opacity { NumberAnimation { duration: 180 } }
                    }
                  }
                }
              }
            }
          }
        }

        // Unsynced: the whole text, drifting along with the song (scroll to take
        // over; it picks up again when the pointer leaves)
        Flickable {
          id: plainView
          anchors.fill: parent
          visible: Lyrics.status === "plain"
          contentHeight: plainCol.height
          boundsBehavior: Flickable.StopAtBounds
          HoverHandler { id: plainHover }
          Binding {
            target: plainView
            property: "contentY"
            when: plainView.visible && !plainView.moving && !plainHover.hovered && plainView.contentHeight > plainView.height
            value: Math.round(NowPlaying.progress * (plainView.contentHeight - plainView.height))
            restoreMode: Binding.RestoreNone
          }
          Column {
            id: plainCol
            width: plainView.width
            topPadding: body.fadeZone * 0.6
            bottomPadding: body.fadeZone * 0.6
            spacing: Math.round(metrics.spacingSmall * Math.min(lyricsCard.k, 1.4))
            Repeater {
              model: Lyrics.status === "plain" ? Lyrics.plain.split(/\r?\n/) : []
              Text {
                required property string modelData
                readonly property real viewY: y + height / 2 - plainView.contentY
                width: plainCol.width
                text: modelData === "" ? " " : modelData
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                color: Theme.colors.textPrimary
                opacity: 0.8 * lyricsCard.smooth(Math.min(viewY, plainView.height - viewY) / body.fadeZone)
                font.pixelSize: lyricsCard.fs(metrics.fontLarge * 1.1)
                font.family: Theme.fonts.ui
                font.weight: Font.DemiBold
              }
            }
          }
        }

        // Everything else: a quiet centred status
        Column {
          id: empty
          anchors.centerIn: parent
          width: parent.width
          visible: !lyricsCard.synced && Lyrics.status !== "plain"
          spacing: Math.round(metrics.spacingNormal * Math.min(lyricsCard.k, 1.4))
          readonly property string st: Lyrics.status
          readonly property real iconPx: lyricsCard.fs(metrics.fontHuge * 1.25)

          // icon in a soft accent halo
          Item {
            anchors.horizontalCenter: parent.horizontalCenter
            width: empty.iconPx * 2.3; height: width
            Rectangle {
              anchors.fill: parent
              radius: width / 2
              color: lyricsCard.tint(empty.st === "idle" || empty.st === "error" ? Theme.colors.textMuted : lyricsCard.accent, 0.10)
              border.width: Theme.bw(1)
              border.color: lyricsCard.tint(empty.st === "idle" || empty.st === "error" ? Theme.colors.textMuted : lyricsCard.accent, 0.22)
            }
            Text {
              id: emptyIcon
              anchors.centerIn: parent
              visible: empty.st !== "loading"
              text: ({ idle: "󰝛", instrumental: "󰎈", none: "󰍣", error: "󰖪" })[empty.st] ?? ""
              color: empty.st === "idle" || empty.st === "error" ? Theme.colors.textMuted : lyricsCard.accent
              font.pixelSize: empty.iconPx
              font.family: Theme.fonts.icon
              // the note bobs gently while an instrumental plays
              transform: Translate { id: bob }
              SequentialAnimation {
                running: empty.st === "instrumental" && lyricsCard.animating
                loops: Animation.Infinite
                alwaysRunToEnd: true
                NumberAnimation { target: bob; property: "y"; to: -empty.iconPx * 0.12; duration: 900; easing.type: Motion.easeAmbient }
                NumberAnimation { target: bob; property: "y"; to: 0; duration: 900; easing.type: Motion.easeAmbient }
              }
            }
            // loading: three dots in a wave
            Row {
              anchors.centerIn: parent
              visible: empty.st === "loading"
              spacing: Math.round(empty.iconPx * 0.18)
              Repeater {
                model: 3
                Rectangle {
                  id: ld
                  required property int index
                  width: Math.round(empty.iconPx * 0.22); height: width; radius: width / 2
                  color: lyricsCard.accent
                  opacity: 0.3
                  SequentialAnimation on opacity {
                    running: empty.st === "loading" && lyricsCard.shown
                    loops: Animation.Infinite
                    PauseAnimation { duration: ld.index * 160 }
                    NumberAnimation { to: 1; duration: 380; easing.type: Motion.easeAmbient }
                    NumberAnimation { to: 0.3; duration: 380; easing.type: Motion.easeAmbient }
                    PauseAnimation { duration: (2 - ld.index) * 160 }
                  }
                }
              }
            }
          }
          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: ({ idle: "NOTHING PLAYING", loading: "FINDING LYRICS", instrumental: "INSTRUMENTAL",
                     none: "NO LYRICS", error: "LYRICS UNAVAILABLE" })[empty.st] ?? ""
            color: Theme.colors.textSecondary
            font.pixelSize: lyricsCard.fs(metrics.fontNormal)
            font.family: Theme.fonts.mono
            font.letterSpacing: Theme.titleTracking
          }
          Text {
            width: parent.width - lyricsCard.pad * 2
            anchors.horizontalCenter: parent.horizontalCenter
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
            text: {
              let t = NowPlaying.title
              return ({ idle: "Play something and the words show up here",
                        loading: t !== "" ? "Looking up “" + t + "”" : "",
                        instrumental: "No words in this one. Just listen.",
                        none: t !== "" ? "Couldn't find words for “" + t + "”" : "",
                        error: "Apple Music and LRCLIB didn't answer; trying again shortly" })[empty.st] ?? ""
            }
            color: Theme.colors.textMuted
            font.pixelSize: lyricsCard.fs(metrics.fontSmall)
            font.family: Theme.fonts.ui
            font.italic: empty.st === "instrumental"
          }
        }
      }
    }
  }
}
