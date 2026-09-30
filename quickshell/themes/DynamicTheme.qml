// The live colour set: starts as Catppuccin Mocha, then Theme.qml overwrites
// the roles from the active wallpaper's theme (scripts/theme/apply.py). Every
// role eases to its new value, so a wallpaper change fades the whole shell.
import QtQuick

ColorTheme {
    id: dyn
    name: "Catppuccin Mocha"
    property color onAccent: "#1e1e2e"

    red: "#f38ba8"
    orange: "#fab387"
    yellow: "#f9e2af"
    green: "#a6e3a1"
    teal: "#94e2d5"
    cyan: "#89dceb"
    blue: "#89b4fa"
    indigo: "#74c7ec"
    violet: "#cba6f7"
    lavender: "#b4befe"
    pink: "#f5c2e7"
    background: "#1e1e2e"
    panel: "#181825"
    panelDeep: "#11111b"
    inset: "#313244"
    border: "#45475a"
    textPrimary: "#cdd6f4"
    textSecondary: "#a6adc8"
    textMuted: "#6c7086"
    accent: "#89b4fa"
    error: "#f38ba8"
    success: "#a6e3a1"
    warning: "#f9e2af"

    Behavior on red { ColorAnimation { duration: dyn.fade; easing.type: dyn.fadeEasing } }
    Behavior on orange { ColorAnimation { duration: dyn.fade; easing.type: dyn.fadeEasing } }
    Behavior on yellow { ColorAnimation { duration: dyn.fade; easing.type: dyn.fadeEasing } }
    Behavior on green { ColorAnimation { duration: dyn.fade; easing.type: dyn.fadeEasing } }
    Behavior on teal { ColorAnimation { duration: dyn.fade; easing.type: dyn.fadeEasing } }
    Behavior on cyan { ColorAnimation { duration: dyn.fade; easing.type: dyn.fadeEasing } }
    Behavior on blue { ColorAnimation { duration: dyn.fade; easing.type: dyn.fadeEasing } }
    Behavior on indigo { ColorAnimation { duration: dyn.fade; easing.type: dyn.fadeEasing } }
    Behavior on violet { ColorAnimation { duration: dyn.fade; easing.type: dyn.fadeEasing } }
    Behavior on lavender { ColorAnimation { duration: dyn.fade; easing.type: dyn.fadeEasing } }
    Behavior on pink { ColorAnimation { duration: dyn.fade; easing.type: dyn.fadeEasing } }
    Behavior on background { ColorAnimation { duration: dyn.fade; easing.type: dyn.fadeEasing } }
    Behavior on panel { ColorAnimation { duration: dyn.fade; easing.type: dyn.fadeEasing } }
    Behavior on panelDeep { ColorAnimation { duration: dyn.fade; easing.type: dyn.fadeEasing } }
    Behavior on inset { ColorAnimation { duration: dyn.fade; easing.type: dyn.fadeEasing } }
    Behavior on border { ColorAnimation { duration: dyn.fade; easing.type: dyn.fadeEasing } }
    Behavior on textPrimary { ColorAnimation { duration: dyn.fade; easing.type: dyn.fadeEasing } }
    Behavior on textSecondary { ColorAnimation { duration: dyn.fade; easing.type: dyn.fadeEasing } }
    Behavior on textMuted { ColorAnimation { duration: dyn.fade; easing.type: dyn.fadeEasing } }
    Behavior on accent { ColorAnimation { duration: dyn.fade; easing.type: dyn.fadeEasing } }
    Behavior on error { ColorAnimation { duration: dyn.fade; easing.type: dyn.fadeEasing } }
    Behavior on success { ColorAnimation { duration: dyn.fade; easing.type: dyn.fadeEasing } }
    Behavior on warning { ColorAnimation { duration: dyn.fade; easing.type: dyn.fadeEasing } }
    Behavior on onAccent { ColorAnimation { duration: dyn.fade; easing.type: dyn.fadeEasing } }
    // The wallpaper-change fade: every role eases to its new value over this
    // long. Each frame of it repaints everything drawn in theme colours, so the
    // shell's CPU cost per change grows with it (~0.5 s at 450 ms, ~0.2 s at
    // 200 ms). Front-loaded easing: most of the change lands in the first half.
    property int fade: 200
    property int fadeEasing: Easing.OutCubic
}
