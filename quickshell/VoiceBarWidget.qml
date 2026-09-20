import QtQuick
import Quickshell
import Quickshell.Io
import "themes"

// Voice assistant indicator (scripts/nova_voice.sh, SUPER+T): lives in the bar's
// center slot (where the music player sits) while a voice turn is in flight, then
// hands the slot back. State comes from $XDG_RUNTIME_DIR/nova-voice/state.json
// via root.voiceState/voiceText/voiceReply.
Item {
  id: voiceBar

  property bool isVertical: false
  property bool showWidget: root.voiceEnabled && root.voiceActive && (bar.state === "normal" || bar.state === "dashboard")
  visible: showWidget
  implicitWidth: isVertical ? parent.width : metrics.s(400)
  implicitHeight: metrics.s(30)

  readonly property string st: root.voiceState
  readonly property bool live: st === "listening" || st === "speaking"
  readonly property color stateColor: {
    switch (st) {
    case "listening":    return Theme.colors.teal;
    case "transcribing": return Theme.colors.lavender;
    case "thinking":     return Theme.colors.violet;
    case "speaking":     return Theme.colors.blue;
    case "error":        return Theme.colors.red;
    default:             return Theme.colors.textMuted;
    }
  }
  readonly property string icon: {
    switch (st) {
    case "listening":    return "󰍬";
    case "transcribing": return "󰦨";
    case "thinking":     return "󰧑";
    case "speaking":     return "󰕾";
    case "error":        return "󰍭";
    default:             return "󰚩";
    }
  }
  readonly property string line: {
    switch (st) {
    case "listening":    return "listening";
    case "transcribing": return "decoding";
    case "thinking":     return root.voiceText.length > 0 ? root.voiceText : "thinking";
    case "speaking":     return root.voiceReply.length > 0 ? root.voiceReply : "speaking";
    case "error":        return "didn't catch that";
    default:             return root.voiceReply.length > 0 ? root.voiceReply : "";
    }
  }

  // ---- level feed: mic while listening, sink monitor while speaking ----
  property real level: 0
  property int barCount: 10
  property var history: new Array(10).fill(0)
  function pushLevel(v) { level = v; let h = history.slice(1); h.push(v); history = h }

  readonly property string meterPy: "import sys,struct,math\nb=sys.stdin.buffer\nwhile True:\n d=b.read(1600)\n if not d: break\n n=len(d)//2\n s=struct.unpack('<%dh'%n,d[:n*2])\n r=math.sqrt(sum(x*x for x in s)/max(n,1))/32768.0\n print(min(1.0,r*7))\n"

  Process {
    id: meterProc
    running: voiceBar.visible && voiceBar.live
    command: ["bash", "-c",
      (voiceBar.st === "speaking" ? "pw-record -P '{ stream.capture.sink = true }' " : "pw-record ")
      + "--format s16 --rate 16000 --channels 1 --latency 50ms - 2>/dev/null | python3 -u -c \"" + voiceBar.meterPy + "\""]
    stdout: SplitParser { onRead: data => { let v = parseFloat(data); if (!isNaN(v)) voiceBar.pushLevel(v) } }
    onRunningChanged: if (!running) voiceBar.level = 0
  }
  onStChanged: { if (meterProc.running) { meterProc.running = false; meterProc.running = Qt.binding(() => voiceBar.visible && voiceBar.live) } }

  // soft motion while decoding / thinking; decay otherwise
  Timer {
    interval: 80; repeat: true
    running: voiceBar.visible && (voiceBar.st === "thinking" || voiceBar.st === "transcribing")
    onTriggered: voiceBar.pushLevel(0.1 + 0.2 * (0.5 + 0.5 * Math.sin(Date.now() / 240)) + Math.random() * 0.05)
  }
  Timer {
    interval: 80; repeat: true
    running: voiceBar.visible && !voiceBar.live && voiceBar.st !== "thinking" && voiceBar.st !== "transcribing" && voiceBar.level > 0.01
    onTriggered: voiceBar.pushLevel(voiceBar.level * 0.7)
  }

  Row {
    anchors.centerIn: parent
    spacing: metrics.s(8)
    width: Math.min(implicitWidth, voiceBar.width - metrics.s(20))

    Text {
      id: iconText
      anchors.verticalCenter: parent.verticalCenter
      text: voiceBar.icon
      color: voiceBar.stateColor
      font.family: "monospace"
      font.pixelSize: metrics.fontSmall
      Behavior on color { ColorAnimation { duration: 250 } }
      SequentialAnimation on opacity {
        running: voiceBar.st === "listening" && voiceBar.visible
        loops: Animation.Infinite
        NumberAnimation { to: 0.35; duration: 800; easing.type: Easing.InOutSine }
        NumberAnimation { to: 1.0; duration: 800; easing.type: Easing.InOutSine }
      }
    }

    // tiny inline level bars
    Row {
      anchors.verticalCenter: parent.verticalCenter
      spacing: metrics.s(2)
      visible: !voiceBar.isVertical
      Repeater {
        model: voiceBar.barCount
        Rectangle {
          required property int index
          readonly property real amp: voiceBar.history[index] || 0
          anchors.verticalCenter: parent.verticalCenter
          width: metrics.s(2)
          height: metrics.s(2) + amp * metrics.s(12)
          radius: 1
          color: voiceBar.stateColor
          opacity: 0.25 + amp * 0.65
          Behavior on height { NumberAnimation { duration: 70 } }
        }
      }
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: !voiceBar.isVertical
      text: voiceBar.line
      color: voiceBar.st === "speaking" || voiceBar.st === "idle" ? Theme.colors.textSecondary : voiceBar.stateColor
      font.pixelSize: metrics.fontSmall
      elide: Text.ElideRight
      width: Math.min(implicitWidth, voiceBar.width - metrics.s(20) - iconText.width - metrics.s(8) - (voiceBar.barCount * metrics.s(4)) - metrics.s(8))
      Behavior on color { ColorAnimation { duration: 250 } }
    }
  }
}
