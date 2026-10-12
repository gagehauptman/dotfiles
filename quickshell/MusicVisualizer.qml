import QtQuick
import "themes"

// Tiny spectrum bars next to the bar track text (MusicWidget trackRow); same
// look as the VoiceBarWidget level bars. Levels from the MusicLevels singleton;
// falls flat on pause (and MusicLevels decays stale data), and the analyzer only
// runs while some visualizer is active.
Row {
  id: viz

  property bool playing: false
  property color tint: Theme.colors.pink
  readonly property bool active: visible && playing

  spacing: metrics.s(2)

  property bool registered: false
  function sync() {
    if (active === registered) return
    registered = active
    MusicLevels.users += active ? 1 : -1
  }
  onActiveChanged: sync()
  Component.onCompleted: sync()
  Component.onDestruction: if (registered) MusicLevels.users -= 1

  // Fades the bars out (and back in) on pause/play rather than snapping them
  property real gain: active ? 1 : 0
  Behavior on gain { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }

  Repeater {
    model: MusicLevels.barCount
    Rectangle {
      required property int index
      readonly property real amp: viz.gain > 0 ? (MusicLevels.values[index] || 0) * viz.gain : 0
      anchors.verticalCenter: parent.verticalCenter
      width: metrics.s(2)
      height: metrics.s(2) + amp * metrics.s(12)
      radius: 1
      color: viz.tint
      opacity: 0.25 + amp * 0.65
      // no height Behavior: the feed is already smoothed, and animating at the monitor
      // refresh rate (144 Hz here) costs far more than stepping at the feed rate
    }
  }
}
