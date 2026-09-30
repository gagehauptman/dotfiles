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

    // True while the colours fade to a new wallpaper's theme. Widgets with their
    // own `Behavior on color` turn it off meanwhile (enabled: !Theme.fading):
    // otherwise every frame of the fade restarts their animation, which costs
    // CPU and leaves them trailing the rest of the shell by their duration.
    property bool fading: false
    Timer {
        id: fadeEnd
        interval: root.colors.fade
        onTriggered: root.fading = false
    }

    // Font families: ui = body text, mono = numbers/terminal-ish (and the bar's
    // icons), display = clock/headings, icon = Nerd Font glyphs on their own.
    // Every family goes through pickFont(): a theme font that is not installed
    // falls back to the stock one, then to a generic family, never to whatever
    // Qt substitutes. Icons inside any family come from the fontconfig rule in
    // scripts/theme/fontconfig (every font falls back to Symbols Nerd Font).
    readonly property var installedFonts: Qt.fontFamilies()
    readonly property var fallbackFonts: ({
        ui: ["Noto Sans", "sans-serif"],
        mono: ["JetBrainsMono Nerd Font", "JetBrains Mono", "monospace"],
        display: ["Noto Sans", "sans-serif"]
    })
    function pickFont(role, wanted) {
        let chain = (wanted ? [wanted] : []).concat(fallbackFonts[role]);
        for (let i = 0; i < chain.length - 1; i++) {
            if (installedFonts.indexOf(chain[i]) >= 0) return chain[i];
            if (chain[i] === wanted) console.warn("theme: font \"" + wanted + "\" (" + role + ") is not installed, using a fallback");
        }
        return chain[chain.length - 1];  // generic family: fontconfig always resolves it
    }
    readonly property QtObject fonts: QtObject {
        property string ui: root.pickFont("ui", "")
        property string mono: root.pickFont("mono", "")
        property string display: root.pickFont("display", "")
        readonly property string icon: "Symbols Nerd Font"
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
        fading = true;
        fadeEnd.restart();
        for (let k in p)
            if (typeof colors[k] !== "undefined" && typeof p[k] === "string") colors[k] = p[k];
        let bar = t.bar || {};
        if (typeof bar.panelOpacity === "number" && p.panel) {
            let c = Qt.color(p.panel);
            colors.panel = Qt.rgba(c.r, c.g, c.b, bar.panelOpacity);
        }
        colors.name = t.name || "";
        colors.isDark = t.dark !== false;
        isDark = colors.isDark;
        name = t.name || "";
        stem = t.stem || "";
        let f = t.fonts || {};
        // A role the theme leaves out goes back to the stock font, not the previous wallpaper's.
        fonts.ui = pickFont("ui", f.ui);
        fonts.mono = pickFont("mono", f.mono);
        fonts.display = pickFont("display", f.display || f.ui);
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
