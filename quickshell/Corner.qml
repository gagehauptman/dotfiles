import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import QtQuick.Effects
import Quickshell
import Quickshell.Services.Pipewire
import Quickshell.Widgets

Shape {
    id: corner
    preferredRendererType: Shape.CurveRenderer

    property real radius: 20
    property color color: "#181825"

    ShapePath {
        strokeWidth: 0
        fillColor: corner.color

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