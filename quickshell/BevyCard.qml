// The part that needs the compiled module: a BevyView on one app library,
// the pointer and wheel feed, and the app's controls and readouts.
import QtQuick
import Bevy

Item {
  property string library: ""
  property string options: "{}"
  readonly property string error: view.error
  // What the app declared through WidgetUi: { controls: [{type, id, label, on}], info: [{id, label, value}] }
  readonly property var ui: {
    try { return JSON.parse(view.ui || "{}") } catch (e) { return ({}) }
  }
  // Press a control; a toggle takes "true"/"false", a button anything
  function send(id, value) { view.send(id, value === undefined ? "" : String(value)) }

  BevyView {
    id: view
    anchors.fill: parent
    library: parent.library
    options: parent.options
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
      function feed(mouse) { view.pointer(mouse.x / Math.max(1, width), mouse.y / Math.max(1, height), pressed) }
      onPositionChanged: mouse => feed(mouse)
      onPressed: mouse => feed(mouse)
      onReleased: mouse => feed(mouse)
      onWheel: wheel => view.scroll(wheel.angleDelta.y / 120)
    }
  }
}
