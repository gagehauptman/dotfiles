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
// Set `running = true` to force an immediate re-run, e.g. after an action command:
//   onExited: someProc.running = true
//
// Shared by default (2026-10-10): every PollProcess with the same command is
// served by one process and one timer in PollHub.qml, whichever screen's
// widget it sits in, so a second monitor doesn't double every poll. Each
// subscriber still gets every output. `shared: false` gives a widget its own
// private process again (the quote card uses it: each screen draws its own).
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
  // One process per distinct command across the whole shell (see PollHub.qml).
  property bool shared: true

  // Set true to force an immediate (re)run; resets itself.
  property bool running: false

  // Emitted with trimmed stdout after each run completes.
  signal output(string text)

  // PollHub bookkeeping
  property string hubKey: ""

  onRunningChanged: {
    if (!running) return
    if (shared) PollHub.run(root)
    else proc.running = true
    running = false
  }
  onPollChanged: if (hubKey !== "") PollHub.update(root)
  onIntervalChanged: if (hubKey !== "") PollHub.update(root)
  onCommandChanged: if (hubKey !== "") PollHub.resubscribe(root)

  Component.onCompleted: {
    if (shared) PollHub.subscribe(root)
    else proc.running = true
  }
  Component.onDestruction: if (hubKey !== "") PollHub.unsubscribe(root)

  // Private process and timer: only used with shared: false.
  Process {
    id: proc
    command: root.command
    running: false
    stdout: StdioCollector {
      onStreamFinished: root.output(this.text.trim())
    }
  }

  Timer {
    interval: root.interval
    running: !root.shared && root.poll
    repeat: true
    onTriggered: proc.running = true
  }
}
