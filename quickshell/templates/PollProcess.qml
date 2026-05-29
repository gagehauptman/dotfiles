// A Process that re-runs itself on a fixed interval and hands its trimmed
// stdout to an `onOutput` handler. Replaces the repeated pattern of a
// `Process { running: true }` paired with a `Timer { onTriggered: proc.running = true }`
// (and a redundant `Component.onCompleted` re-trigger) used by the polling widgets.
//
//   PollProcess {
//     command: ["bash", root.home + "/.config/scripts/polls/foo.sh"]
//     interval: 3000
//     onOutput: text => { /* parse text */ }
//   }
//
// `running` is aliased to the inner Process, so manual re-polls still work:
//   onExited: someProc.running = true   // force an immediate refresh
//
// Note: this is a (non-visual) wrapper rather than a Process subclass because
// Quickshell's Process has no default property to hold the Timer as a child.

import QtQuick
import Quickshell.Io

Item {
  id: root

  property var command: []
  // Polling interval in milliseconds.
  property int interval: 3000
  // Set false to pause polling. The initial run still happens.
  property bool poll: true

  // Force an immediate (re)run by setting this true, e.g. after an action command.
  property alias running: proc.running

  // Emitted with trimmed stdout after each run completes.
  signal output(string text)

  Process {
    id: proc
    command: root.command
    running: true
    stdout: StdioCollector {
      onStreamFinished: root.output(this.text.trim())
    }
  }

  Timer {
    interval: root.interval
    running: root.poll
    repeat: true
    onTriggered: proc.running = true
  }
}
