// Interface a theme implements: define a palette, map it onto these roles.
import QtQuick

QtObject {
    property string name: "unnamed"
    property bool isDark: true

    // Accent hues
    property color red
    property color orange
    property color yellow
    property color green
    property color teal
    property color cyan
    property color blue
    property color indigo
    property color violet
    property color lavender
    property color pink

    // Surfaces, deepest to most raised
    property color background
    property color panel
    property color panelDeep
    property color inset
    property color border

    // Text
    property color textPrimary
    property color textSecondary
    property color textMuted

    // Intent
    property color accent: blue
    property color error: red
    property color success: green
    property color warning: yellow
}
