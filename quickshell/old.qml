import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import QtQuick.Effects
import Quickshell
import Quickshell.Services.Pipewire
import Quickshell.Widgets


PanelWindow {
    id: root
    property color mColor: "#ffffffff"
    property int rad: 20

    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    mask: Region {}

    PwObjectTracker {
        objects: [ Pipewire.defaultAudioSink ]
    }

    Connections {
        target: Pipewire.defaultAudioSink?.audio

        function onVolumeChanged() {
            dashboard.state = "volup"
            hideTimer.restart();
        }
    }

    Timer {
        id: hideTimer
        interval: 1000
        onTriggered: dashboard.state = "hidden"
    }

    anchors {
        left: true
        top: true
        right: true
        bottom: true
    }

    Item {
        id: thing
        anchors.fill: parent

        Rectangle {
            id: top
            implicitWidth: parent.width
            implicitHeight: 2.5 * parent.height / 100
        }

        // Corner {
        //     id: leftTopCorner
        //     x: left.implicitWidth
        //     y: top.implicitHeight
        // }
        //
        // Corner {
        //     id: rightTopCorner
        //     x: parent.width - radius
        //     y: top.implicitHeight
        //     rotation: 90
        // }

        Item {
            id: dashboard
            anchors.fill: parent
            state: "hidden"
            property int dashboard_rad: 20

            Rectangle {
                id: dashboard_rect
                implicitWidth: parent.width / 10
                y: parent.implicitHeight - implicitHeight
                x: 4 * parent.width / 5
                bottomLeftRadius: rad
                bottomRightRadius: rad
                implicitHeight: 35
            }

            Corner {
                x: dashboard_rect.x - radius
                y: dashboard_rect.y
                rotation: 90
                radius: dashboard.dashboard_rad
            }

            Corner {
                x: dashboard_rect.x + dashboard_rect.implicitWidth
                y: dashboard_rect.y
                radius: dashboard.dashboard_rad
            }

            states: [
                State {
                    name: "hidden"
                    PropertyChanges { target: dashboard_rect; y: top.implicitHeight - dashboard_rect.implicitHeight }
                    PropertyChanges { target: dashboard; dashboard_rad: 0 }   // <-- set on dashboard
                },
                State {
                    name: "volup"
                    PropertyChanges { target: dashboard_rect; y: top.implicitHeight }
                    PropertyChanges { target: dashboard; dashboard_rad: 20 }  // <-- set on dashboard
                },
                State {
                    name: "voldown"
                    PropertyChanges { target: dashboard_rect; y: top.implicitHeight }
                    PropertyChanges { target: dashboard; dashboard_rad: 20 }  // <-- set on dashboard
                }
            ]

            transitions: [
                Transition {
                    from: "hidden"; to: "volup"
                    NumberAnimation { target: dashboard_rect; properties: "y"; duration: 100; easing.type: Easing.InOutQuad }
                    NumberAnimation { target: dashboard; properties: "dashboard_rad"; duration: 100; easing.type: Easing.InOutQuad } // <-- animate correct target
                },
                Transition {
                    from: "volup"; to: "hidden"
                    NumberAnimation { target: dashboard_rect; properties: "y"; duration: 100; easing.type: Easing.InOutQuad }
                    NumberAnimation { target: dashboard; properties: "dashboard_rad"; duration: 100; easing.type: Easing.InOutQuad }
                }
            ]
        }
    }

    MultiEffect {
        source: thing
        anchors.fill: thing
        shadowEnabled: true
    }

    component Corner: Shape {
        id: corner
        preferredRendererType: Shape.CurveRenderer

        property real radius: 20

        ShapePath {
            strokeWidth: 0
            fillColor: root.mColor

            startX: corner.radius

            PathArc {
                relativeX: -corner.radius
                relativeY: corner.radius
                radiusX: corner.radius
                radiusY: corner.radius
                direction: PathArc.Counterclockwise
            }

            PathLine {
                relativeX: 0
                relativeY: -corner.radius
            }

            PathLine {
                relativeX: corner.radius
                relativeY: 0
            }
        }
    }

    Scope {
        PanelWindow {
            anchors.top: true
            implicitWidth: 0
            implicitHeight: top.implicitHeight
        }
    }
}
