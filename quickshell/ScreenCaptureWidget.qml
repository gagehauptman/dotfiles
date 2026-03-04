import QtQuick
import QtQuick.Layouts
import Quickshell.Io

Item {
  id: root

  property string monitorName: ""
  property bool isRecording: false

  // Poll wf-recorder process to sync state (catches keybind-triggered recordings)
  Process {
    id: recordingPollProc
    command: ["pgrep", "-x", "wf-recorder"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        root.isRecording = (this.text.trim().length > 0)
      }
    }
  }
  Timer { interval: 1000; running: true; repeat: true; onTriggered: recordingPollProc.running = true }

  implicitWidth: row.implicitWidth
  implicitHeight: parent ? parent.height : 30

  property string screenshotDir: "/home/v1k/Pictures/Screenshots"
  property string recordingDir: "/home/v1k/Videos/Recordings"

  Process {
    id: screenshotProc
    command: ["bash", "/storage/git/dotfiles/scripts/hyprland_capture_full.sh"]
    running: false
  }

  Process {
    id: screenshotRegionProc
    command: ["hyprctl", "dispatch", "exec", "bash /storage/git/dotfiles/scripts/hyprland_capture_partial.sh"]
    running: false
  }

  Process {
    id: recordStartFullProc
    command: ["hyprctl", "dispatch", "exec", "bash /storage/git/dotfiles/scripts/hyprland_record_full.sh"]
    running: false
  }

  Process {
    id: recordStartRegionProc
    command: ["hyprctl", "dispatch", "exec", "bash /storage/git/dotfiles/scripts/hyprland_record_region.sh"]
    running: false
  }

  Process {
    id: recordStopProc
    command: ["bash", "/storage/git/dotfiles/scripts/hyprland_record_stop.sh"]
    running: false
    onRunningChanged: {
      if (!running) {
        root.isRecording = false
      }
    }
  }

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    spacing: 8

    Text {
      id: screenshotBtn
      text: "\uf030"
      color: screenshotMouse.containsMouse ? "#89dceb" : "#a6adc8"
      font.pixelSize: 14
      font.family: "monospace"
      font.bold: true
      anchors.verticalCenter: parent.verticalCenter

      Behavior on color { ColorAnimation { duration: 100 } }

      MouseArea {
        id: screenshotMouse
        anchors.fill: parent
        anchors.margins: -4
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor

        onClicked: (mouse) => {
          if (mouse.button === Qt.RightButton) {
            screenshotRegionProc.running = true
          } else {
            screenshotProc.running = true
          }
        }
      }
    }

    Text {
      id: recordBtn
      text: root.isRecording ? "\uf04d" : "\uf111"
      color: {
        if (root.isRecording) return pulseAnim.pulseColor
        return recordMouse.containsMouse ? "#f38ba8" : "#a6adc8"
      }
      font.pixelSize: root.isRecording ? 14 : 10
      font.family: "monospace"
      font.bold: true
      anchors.verticalCenter: parent.verticalCenter

      Timer {
        id: pulseAnim
        property color pulseColor: "#f38ba8"
        property bool bright: true
        interval: 700
        running: root.isRecording
        repeat: true
        onTriggered: {
          bright = !bright
          pulseColor = bright ? "#f38ba8" : "#7f1d2d"
        }
        onRunningChanged: {
          if (running) { bright = true; pulseColor = "#f38ba8" }
        }
      }

      Behavior on color { ColorAnimation { duration: 200 } }

      MouseArea {
        id: recordMouse
        anchors.fill: parent
        anchors.margins: -4
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor

        onClicked: (mouse) => {
          if (root.isRecording) {
            recordStopProc.running = true
          } else {
            root.isRecording = true
            if (mouse.button === Qt.RightButton) {
              recordStartRegionProc.running = true
            } else {
              recordStartFullProc.running = true
            }
          }
        }
      }
    }
  }
}
