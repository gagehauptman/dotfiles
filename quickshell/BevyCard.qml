// The part that needs the compiled module: a BevyView on one app library,
// plus the pointer feed.
import QtQuick
import Bevy

Item {
  property string library: ""
  readonly property string error: view.error
  BevyView {
    id: view
    anchors.fill: parent
    library: parent.library
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
      function feed(mouse) { view.pointer(mouse.x / Math.max(1, width), mouse.y / Math.max(1, height), pressed) }
      onPositionChanged: mouse => feed(mouse)
      onPressed: mouse => feed(mouse)
      onReleased: mouse => feed(mouse)
    }
  }
}
