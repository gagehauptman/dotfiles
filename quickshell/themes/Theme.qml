// Shell theme singleton: colours, fonts and shape, all taken from the active
// wallpaper's theme (wallpapers/<stem>/theme.json). scripts/theme/apply.py
// resolves that and writes ~/.cache/wallpaper_theme/current.json whenever the
// wallpaper changes (wallpaper_select.sh calls it); this watches the file, so
// the whole shell re-skins live. Without the file it is Catppuccin Mocha.
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    readonly property string themeFile: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/wallpaper_theme/current.json"

    property string name: "Catppuccin Mocha"
    property string stem: ""
    property bool isDark: true

    readonly property DynamicTheme colors: DynamicTheme {}

    // Font families: ui = body text, mono = numbers/terminal-ish, display = clock/headings.
    readonly property QtObject fonts: QtObject {
        property string ui: "Noto Sans"
        property string mono: "monospace"
        property string display: "Noto Sans"
    }

    // Shape: 1 = the stock proportions. radius 0 = square, 2 = pills; border 0 = borderless.
    property real radiusScale: 1
    property real borderScale: 1
    function rs(n) { return n <= 0 ? 0 : Math.max(0, Math.round(n * radiusScale)); }
    function bw(n) { return n <= 0 ? 0 : (borderScale <= 0 ? 0 : Math.max(1, Math.round(n * borderScale))); }

    function apply(text) {
        let t;
        try { t = JSON.parse(text); } catch (e) { return; }  // half-written file: the next change event retries
        if (!t || !t.palette) return;
        console.log("theme: " + t.name + " (" + t.stem + ")");
        let p = t.palette;
        for (let k in p)
            if (typeof colors[k] !== "undefined" && typeof p[k] === "string") colors[k] = p[k];
        colors.name = t.name || "";
        colors.isDark = t.dark !== false;
        isDark = colors.isDark;
        name = t.name || "";
        stem = t.stem || "";
        let f = t.fonts || {};
        if (f.ui) fonts.ui = f.ui;
        if (f.mono) fonts.mono = f.mono;
        if (f.display) fonts.display = f.display;
        let s = t.style || {};
        if (typeof s.radius === "number") radiusScale = s.radius;
        if (typeof s.border === "number") borderScale = s.border;
    }

    FileView {
        path: root.themeFile
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.apply(text())
    }
}
