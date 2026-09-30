# Per-wallpaper themes

Every wallpaper owns a theme: colours, three fonts, corner rounding and
border weight. Changing the wallpaper (selector commit once flipping pauses,
boot restore) re-skins Quickshell live, plus kittys colours and Hyprlands window
borders.

## Layout

    wallpapers/
      clouds/clouds.png        the image (or <stem>.live descriptor); every file of a
                               wallpaper lives in its own folder, nothing elsewhere
      clouds/theme.json        palette, fonts, rounding, borders
      clouds/lock.toml         lock screen layout + text styling (scripts/lock/lockgen.py)
      clouds/bar.json          Quickshell tweaks (panelOpacity)
      clouds/kitty.conf        extra kitty settings appended to the generated colours
      clouds/meta.json         name, description, file index (informational)
      _presets/                shared themes others inherit from:
        catppuccin_mocha|macchiato|frappe|latte.json   the four Catppuccin flavours
        default.json           = Catppuccin Mocha (used when a wallpaper has no theme)

Per-device wallpapers (`add`/`disable` in `wallpapers/local.conf`) can live outside the repo: a folder added there with this same layout is themed too.

A new wallpaper: `mkdir wallpapers/<stem>`, put the image in it as `<stem>.<ext>`
(a real file; no copies or symlinks elsewhere) and add `theme.json`. Catppuccin is
the house look: a new wallpaper needs only `{"inherits": "catppuccin_mocha",
"palette": {"accent": "#..."}}` (pick the flavour by brightness, the accent from
Catppuccin's own accent colours; `fonts`/`style`/`palette` overrides win).
Deviate from Catppuccin only when it clearly clashes with the image.

## theme.json

    name, dark, inherits
    fonts   {ui, mono, display}  ui = body text, mono = numbers/labels, display = clock and quote
    style   {radius, border}     radius 1 = stock, 0 square, 2 pills; border 0 = borderless
    palette red orange yellow green teal cyan blue indigo violet lavender pink
            background panel panelDeep inset border textPrimary textSecondary
            textMuted accent error success warning onAccent
    extra   {accent2}            second accent (window-border gradient)

Each wallpaper's theme.json keeps only what differs from its Catppuccin flavour (accent, accent2, display font).

## How it switches

`wallpaper_select.sh` runs `apply.py <wallpaper path>` on every apply (the
selector's previews while flipping skip it; its commit ~0.3 s after the last
step re-themes), one run at a time, dropping runs a newer one superseded. It writes
`~/.cache/wallpaper_theme/current.json`; `quickshell/themes/Theme.qml` watches
it, and the colours ease to the new values (`DynamicTheme.qml`). It also writes
`kitty/current-theme.conf` (kitty reloads on SIGUSR1; generated, gitignored)
and sets the Hyprland border gradient with `hyprctl eval`.
By hand: `scripts/theme/apply.py clouds`.

In QML: `Theme.colors.*` as before, `Theme.fonts.ui|mono|display|icon`,
`Theme.rs(px)` for radii (metrics.radius* already go through it),
`Theme.bw(px)` for border widths.

## Firefox

`apply.py` also calls `firefox.py`, which fills `templates/firefox-chrome.css` and
`templates/firefox-content.css` (about: pages) with the palette and writes them to the default
profile's `chrome/wallpaper-theme*.css`; `userChrome.css`/`userContent.css` just `@import` them.
Optional per-wallpaper `<stem>/firefox.css` and `<stem>/firefox-content.css` are appended.
It adds `toolkit.legacyUserProfileCustomizations.stylesheets` to `user.js` if no prefs file sets it
(edited files are backed up once as `*.bak-wallpaper-theme`). Firefox reads chrome CSS when a
window opens: new windows get the new colours, open ones keep theirs; restart once after the first run.
Does nothing when Firefox or its profile is absent.
Live colours (no restart) come from the `firefox-live/` extension; run
`scripts/theme/firefox-live/install-autoconfig.sh` once per machine (sudo) so Firefox loads it on every
start, see [firefox-live/README.md](firefox-live/README.md).

## Fonts

Packages: `ttf-nerd-fonts-symbols` (Symbols Nerd Font, the icons) and
`ttf-jetbrains-mono-nerd` (JetBrainsMono Nerd Font, the presets' mono font).
`install-fonts.sh` (no sudo) fetches the OFL families the themes use into
`~/.local/share/fonts/wallpaper-themes` and links
`fontconfig/60-nerd-symbols-fallback.conf` into `~/.config/fontconfig/conf.d`:
every font falls back to Symbols Nerd Font for the icon glyphs. Qt only uses
fallbacks fontconfig lists for the requested family, so without it Nerd Font
icons draw as boxes in most families. Restart Quickshell once afterwards (Qt
reads the font list and fontconfig rules at start).

Theme.qml checks each family against the installed fonts: one that is missing
falls back to the stock font for that role (Noto Sans; JetBrainsMono Nerd Font,
then JetBrains Mono, for mono) and logs `theme: font "X" ... is not installed`.
`Theme.fonts.icon` is Symbols Nerd Font, for text that is only an icon.

The lock screen reads `<stem>/lock.toml` from the same folder (falls back to
`scripts/lock/meta/<stem>.toml`, then `meta/default.toml` and `meta/layouts/`,
which stay shared). Not yet themed: Bevy widgets.
