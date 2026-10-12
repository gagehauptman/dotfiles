import QtQuick
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Quickshell
import Quickshell.Io
import "themes"

Item {
  id: profileWidget

  visible: bar.state === "dashboard"

  // Per-widget options from the active dashboard preset (unused so far).
  property var options: ({})
  property string username: ""
  property string hostname: ""

  // Fit: the picture takes whatever height the text leaves (up to a cap that
  // grows with the card); the palette dots, then the hostname, then the
  // picture are dropped as the card gets shorter.
  readonly property real k: metrics.cardScale(width, height, 360, 300)
  readonly property real pad: metrics.spacingNormal
  readonly property real gap: Math.round(metrics.spacingLarge * Math.min(k, 1.3) * (height < metrics.s(260) ? 0.6 : 1))
  readonly property bool showDots: height >= metrics.s(220) && width >= metrics.s(170)
  readonly property bool showHost: height >= metrics.s(130)
  readonly property real dotSize: Math.round(metrics.s(14) * k)
  readonly property real textH: Math.ceil(metrics.fontLarge * k * 1.3)
                               + (showHost ? Math.ceil(metrics.fontSmall * k * 1.3) + gap : 0)
                               + (showDots ? dotSize + gap : 0)
  readonly property real picSize: Math.floor(Math.min(width * 0.6, height - 2 * pad - textH - gap, metrics.profilePicSize * Math.max(1, k) * 1.4))
  readonly property bool showPic: picSize >= metrics.s(40)

  Process {
    id: usernameProc
    command: ["whoami"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: profileWidget.username = this.text.trim()
    }
  }

  Process {
    id: hostnameProc
    command: ["cat", "/etc/hostname"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: profileWidget.hostname = this.text.trim()
    }
  }

  Rectangle {
    anchors.fill: parent
    color: Theme.colors.panel
    radius: metrics.radiusLarge
    // Hairline frame (Theme.cardFrameOpacity)
    border.width: Theme.cardFrameOpacity > 0 ? Theme.bw(1) : 0
    border.color: Theme.cardFrame
    ColumnLayout {
      anchors.centerIn: parent
      width: Math.min(implicitWidth, parent.width - 2 * profileWidget.pad)
      spacing: profileWidget.gap

      // Profile picture
      Item {
        visible: profileWidget.showPic
        Layout.alignment: Qt.AlignHCenter
        implicitWidth: profileWidget.picSize
        implicitHeight: profileWidget.picSize

        // Fallback placeholder
        Rectangle {
          anchors.fill: parent
          radius: width / 2
          color: Theme.colors.inset
          border.color: Theme.colors.border
          border.width: Theme.bw(2)
          visible: pfpImage.status !== Image.Ready

          Text {
            anchors.centerIn: parent
            text: "󰀉"
            color: Theme.colors.textMuted
            font.pixelSize: Math.round(parent.height * 0.38)
            font.family: Theme.fonts.mono
          }
        }

        // Actual profile picture
        Image {
          id: pfpImage
          anchors.fill: parent
          source: "file://" + root.home + "/.face"
          // Fixed decode size (not picSize) so resizing never reloads the image
          sourceSize: Qt.size(metrics.s(256), metrics.s(256))
          fillMode: Image.PreserveAspectCrop
          visible: false
        }

        Rectangle {
          id: pfpMask
          anchors.fill: parent
          radius: width / 2
          visible: false
        }

        OpacityMask {
          anchors.fill: parent
          source: pfpImage
          maskSource: pfpMask
          visible: pfpImage.status === Image.Ready
        }
      }

      // Username
      Text {
        Layout.alignment: Qt.AlignHCenter
        Layout.maximumWidth: profileWidget.width - 2 * profileWidget.pad
        elide: Text.ElideRight
        text: profileWidget.username
        color: Theme.colors.textPrimary
        font.pixelSize: Math.round(metrics.fontLarge * profileWidget.k)
        font.bold: true
        font.family: Theme.fonts.mono
      }

      // Hostname
      Text {
        visible: profileWidget.showHost
        Layout.alignment: Qt.AlignHCenter
        Layout.maximumWidth: profileWidget.width - 2 * profileWidget.pad
        elide: Text.ElideRight
        text: profileWidget.hostname
        color: Theme.colors.textMuted
        font.pixelSize: Math.round(metrics.fontSmall * profileWidget.k)
        font.family: Theme.fonts.mono
      }

      // Color palette dots
      Row {
        visible: profileWidget.showDots
        Layout.alignment: Qt.AlignHCenter
        spacing: Math.round(metrics.spacingSmall * profileWidget.k)

        Repeater {
          model: [Theme.colors.red, Theme.colors.orange, Theme.colors.yellow, Theme.colors.green, Theme.colors.blue, Theme.colors.violet, Theme.colors.pink, Theme.colors.teal]
          Rectangle {
            width: profileWidget.dotSize
            height: profileWidget.dotSize
            radius: width / 2
            color: modelData
          }
        }
      }
    }
  }
}
