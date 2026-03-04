// Generic bar widget: icon + value, expands with a draggable slider on hover.
// Slider expands LEFT so the icon+value stay pinned in place.

import QtQuick
import QtQuick.Layouts

Item {
  id: root

  property string icon: ""
  property real value: 0          // 0.0 – 1.0
  property string displayValue: ""
  property color accentColor: "#cba6f7"
  property bool mutable: true     // false = display-only, no slider

  signal moved(real newValue)
  signal clicked()

  // Internal: local value used during drag to avoid round-trip lag
  property bool dragging: sliderMouse.pressed
  property real dragValue: 0
  property real effectiveValue: dragging ? dragValue : value
  property real pendingEmit: -1

  Timer {
    id: emitThrottle
    interval: 50
    onTriggered: {
      if (root.pendingEmit >= 0) {
        root.moved(root.pendingEmit);
        root.pendingEmit = -1;
      }
    }
  }

  property bool expanded: hoverArea.containsMouse || dragging
  property real sliderTrackWidth: 80
  property real sliderHeight: 4
  property real knobSize: 10
  property real sliderWidth: (expanded && mutable) ? sliderTrackWidth + 8 : 0

  Behavior on sliderWidth {
    NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
  }

  implicitWidth: label.implicitWidth + sliderWidth
  implicitHeight: parent ? parent.height : 30
  clip: true

  MouseArea {
    id: hoverArea
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.NoButton
  }

  // Icon + value text, pinned to the right edge
  Row {
    id: label
    anchors {
      right: parent.right
      verticalCenter: parent.verticalCenter
    }
    spacing: 5

    Text {
      text: root.icon
      color: root.accentColor
      font.pixelSize: 14
      font.family: "monospace"
      font.bold: true
    }

    Text {
      text: root.displayValue
      color: root.accentColor
      font.pixelSize: 14
      font.bold: true
    }
  }

  MouseArea {
    anchors.fill: label
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }

  // Slider track, to the left of the label
  Item {
    id: sliderContainer
    visible: root.mutable
    width: root.sliderTrackWidth
    height: root.knobSize
    anchors {
      right: label.left
      rightMargin: 8
      verticalCenter: parent.verticalCenter
    }
    opacity: root.expanded ? 1.0 : 0.0

    Behavior on opacity {
      NumberAnimation { duration: 100 }
    }

    Rectangle {
      id: track
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width
      height: root.sliderHeight
      radius: root.sliderHeight / 2
      color: "#45475a"

      Rectangle {
        anchors {
          left: parent.left
          top: parent.top
          bottom: parent.bottom
        }
        width: parent.width * Math.max(0, Math.min(1, root.effectiveValue))
        radius: parent.radius
        color: root.accentColor
      }
    }

    Rectangle {
      id: knob
      width: root.knobSize
      height: root.knobSize
      radius: root.knobSize / 2
      color: "#cdd6f4"
      x: (sliderContainer.width - width) * Math.max(0, Math.min(1, root.effectiveValue))
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      id: sliderMouse
      anchors {
        fill: parent
        topMargin: -10
        bottomMargin: -10
      }
      cursorShape: Qt.PointingHandCursor

      onPressed: (mouse) => {
        let newVal = Math.max(0, Math.min(1, mouse.x / sliderContainer.width));
        root.dragValue = newVal;
        root.moved(newVal);
      }

      onPositionChanged: (mouse) => {
        if (pressed) {
          let newVal = Math.max(0, Math.min(1, mouse.x / sliderContainer.width));
          root.dragValue = newVal;
          root.pendingEmit = newVal;
          if (!emitThrottle.running) emitThrottle.start();
        }
      }

      onReleased: (mouse) => {
        emitThrottle.stop();
        if (root.pendingEmit >= 0) {
          root.moved(root.pendingEmit);
          root.pendingEmit = -1;
        }
      }
    }
  }
}
