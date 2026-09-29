# Per-wallpaper themes

Every wallpaper owns a theme: colours, three fonts, corner rounding and
border weight. Changing the wallpaper (selector preview or commit, boot
restore) re-skins Quickshell live, plus kittys colours and Hyprlands window
borders.

## Layout

    wallpapers/
      clouds/clouds.png        the image (or <stem>.live descriptor)
      clouds/theme.json        palette, fonts, rounding, borders
      clouds/lock.toml         lock screen layout + text styling (scripts/lock/lockgen.py)
      clouds/bar.json          Quickshell tweaks (panelOpacity)
      clouds/kitty.conf        extra kitty settings appended to the generated colours
      clouds/meta.json         name, description, file index (informational)
      clouds.png -> clouds/clouds.png     symlink kept so the selector, the
                                          saved path in wpsave.txt and the
                                          lock screen still find it flat
      _presets/                shared themes others can inherit from:
        default.json           Catppuccin Mocha (used when a wallpaper has no theme)
        cat_bouquine.json      Cat Bouquine, dark: parchment ink, brass, oxblood, moss
        cat_bouquine_day.json  Cat Bouquine, paper variant

A new wallpaper: `mkdir wallpapers/<stem>`, put the image in, symlink it flat
(`ln -s <stem>/<file> wallpapers/<file>`) and add `theme.json`. A Cat Bouquine
wallpaper needs only `{"inherits": "cat_bouquine"}` (optionally with
`fonts`/`style`/`palette` overrides, which win).

## theme.json

    name, dark, inherits
    fonts   {ui, mono, display}  ui = body text, mono = numbers/labels, display = clock and quote
    style   {radius, border}     radius 1 = stock, 0 square, 2 pills; border 0 = borderless
    palette red orange yellow green teal cyan blue indigo violet lavender pink
            background panel panelDeep inset border textPrimary textSecondary
            textMuted accent error success warning onAccent
    extra   {accent2}            second accent (window-border gradient)

`themegen.py` holds the seed table (bg, fg, accent, accent2, fonts, shape) the
files were generated from; after that the JSON is the source of truth, edit it
directly. `themegen.py <stem>` regenerates one from its seed.

## How it switches

`wallpaper_select.sh` runs `apply.py <stem>` on every preview/apply. It writes
`~/.cache/wallpaper_theme/current.json`; `quickshell/themes/Theme.qml` watches
it, and the colours ease to the new values (`DynamicTheme.qml`). It also writes
`kitty/current-theme.conf` (kitty reloads on SIGUSR1; generated, gitignored)
and sets the Hyprland border gradient with `hyprctl eval`.
By hand: `scripts/theme/apply.py clouds`.

In QML: `Theme.colors.*` as before, `Theme.fonts.ui|mono|display`,
`Theme.rs(px)` for radii (metrics.radius* already go through it),
`Theme.bw(px)` for border widths.

## Fonts

`install-fonts.sh` (no sudo) fetches the OFL families the themes use into
`~/.local/share/fonts/wallpaper-themes` and writes a fontconfig rule so each
falls back to Symbols Nerd Font for the icon glyphs. Restart Quickshell once
afterwards (Qt reads the font list at start). Missing fonts just fall back to
the default sans, nothing breaks.

The lock screen reads `<stem>/lock.toml` from the same folder (falls back to
`scripts/lock/meta/<stem>.toml`, then `meta/default.toml` and `meta/layouts/`,
which stay shared). Not yet themed: Bevy widgets.
