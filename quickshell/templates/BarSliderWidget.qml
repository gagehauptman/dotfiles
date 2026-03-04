// Generic bar widget: icon + value, expands with a draggable slider on hover.
// Props: icon, value (0-1), displayValue, color, onMoved(real newValue)

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

  implicitWidth: labelRow.implicitWidth + (expanded && mutable ? sliderTrackWidth + 12 : 0)
  implicitHeight: parent ? parent.height : 30
  clip: true

  Behavior on implicitWidth {
    NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
  }

  MouseArea {
    id: hoverArea
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.NoButton
  }

  RowLayout {
    anchors.verticalCenter: parent.verticalCenter
    spacing: 6
    height: parent.height

    // Icon + label (always visible)
    RowLayout {
      id: labelRow
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

    // Slider track
    Item {
      id: sliderContainer
      visible: root.mutable
      implicitWidth: root.sliderTrackWidth
      implicitHeight: root.knobSize
      opacity: root.expanded ? 1.0 : 0.0

      Behavior on opacity {
        NumberAnimation { duration: 100 }
      }

      // Track background
      Rectangle {
        id: track
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        height: root.sliderHeight
        radius: root.sliderHeight / 2
        color: "#45475a"

        // Fill
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

      // Knob
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
          root.moved(newVal);  // immediate on first press
        }

        onPositionChanged: (mouse) => {
          if (pressed) {
            let newVal = Math.max(0, Math.min(1, mouse.x / sliderContainer.width));
            root.dragValue = newVal;  // visual updates instantly
            root.pendingEmit = newVal;
            if (!emitThrottle.running) emitThrottle.start();
          }
        }

        onReleased: (mouse) => {
          // flush final value immediately on release
          emitThrottle.stop();
          if (root.pendingEmit >= 0) {
            root.moved(root.pendingEmit);
            root.pendingEmit = -1;
          }
        }
      }
    }

    // Click target over the label area
    MouseArea {
      id: labelClick
      anchors.fill: labelRow
      cursorShape: Qt.PointingHandCursor
      onClicked: root.clicked()
    }
  }
}
