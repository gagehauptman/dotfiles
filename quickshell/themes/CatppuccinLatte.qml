// Catppuccin Latte — https://catppuccin.com/palette
import QtQuick

ColorTheme {
    name: "Catppuccin Latte"
    isDark: false

    // palette
    readonly property QtObject ctp: QtObject {
        readonly property color rosewater: "#dc8a78"
        readonly property color flamingo:  "#dd7878"
        readonly property color pink:      "#ea76cb"
        readonly property color mauve:     "#8839ef"
        readonly property color red:       "#d20f39"
        readonly property color maroon:    "#e64553"
        readonly property color peach:     "#fe640b"
        readonly property color yellow:    "#df8e1d"
        readonly property color green:     "#40a02b"
        readonly property color teal:      "#179299"
        readonly property color sky:       "#04a5e5"
        readonly property color sapphire:  "#209fb5"
        readonly property color blue:      "#1e66f5"
        readonly property color lavender:  "#7287fd"
        readonly property color text:      "#4c4f69"
        readonly property color subtext1:  "#5c5f77"
        readonly property color subtext0:  "#6c6f85"
        readonly property color overlay2:  "#7c7f93"
        readonly property color overlay1:  "#8c8fa1"
        readonly property color overlay0:  "#9ca0b0"
        readonly property color surface2:  "#acb0be"
        readonly property color surface1:  "#bcc0cc"
        readonly property color surface0:  "#ccd0da"
        readonly property color base:      "#eff1f5"
        readonly property color mantle:    "#e6e9ef"
        readonly property color crust:     "#dce0e8"
    }

    // → roles
    red:           ctp.red
    orange:        ctp.peach
    yellow:        ctp.yellow
    green:         ctp.green
    teal:          ctp.teal
    cyan:          ctp.sky
    blue:          ctp.blue
    indigo:        ctp.sapphire
    violet:        ctp.mauve
    lavender:      ctp.lavender
    pink:          ctp.pink

    background:    ctp.base
    panel:         ctp.mantle
    panelDeep:     ctp.crust
    inset:         ctp.surface0
    border:        ctp.surface1

    textPrimary:   ctp.text
    textSecondary: ctp.subtext0
    textMuted:     ctp.overlay0
}
