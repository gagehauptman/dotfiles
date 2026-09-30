# Lock screen

`lock.sh` (Super+L and the power-menu Lock button) is a real ext-session-lock-v1
client: a Quickshell `WlSessionLock` (`qs/shell.qml`, run as its own instance,
not the bar). It draws the current wallpaper's **live, animated Bevy scene**
itself through the `Bevy` QML module (same renderer the bar/wallpaper selector
use), so there is no workspace switching, no see-through lock, no snapshot, no
cat. PAM is Quickshell's `PamContext` on the `hyprlock` service (auth include
login), so the login password works. If the client dies within 3s of starting,
`lock.sh` falls back to `hyprlock` (static `~/.config/hypr/hyprlock.conf`).

`lockgen.py` resolves each wallpaper's `wallpapers/<stem>/lock.toml` (old: `meta/<stem>.toml`, moved to ~/lock-meta-old-2026-09-29) for the current wallpaper into
`$XDG_RUNTIME_DIR/lockscreen/lock.json`, which the QML reads.

## Background

Live (`.live`) wallpaper with a Bevy app: the running scene, per monitor at its
native size. No app / `live = false`: a still next to the descriptor, else the
flat `[background] color`. Non-live wallpapers: the image, cover-cropped.

## Layout and text

- Placement: `wallpapers/<stem>/lock.toml` over `meta/default.toml`; a file lists
  only what it changes. `base = "left"` / `"right"` pulls in `meta/layouts/`.
  Positions are `"x%, y%"` (+y up). Per monitor: `[monitor."HDMI-A-3".clock]`.
- Elements: `[background]`, `[text]`, `[clock]`, `[date]`, `[greeting]`, `[input]`.
- **Text style is per wallpaper.** `[text]` in `meta/default.toml` is only the fallback
  (`color`, `accent`, `font_family`, `font_weight`, `font_style`, shadow); every
  `meta/<stem>.toml` sets its own look, per element (`[clock]`, `[date]`, `[greeting]`):
  `font_family`, `font_weight` (100-900), `font_size` (pt), `letter_spacing` (px),
  `uppercase`, `font_style`, `color`, `opacity`, `format`/`text`, `shadow_strength`
  (0 = none, 1 = normal, 2 = heavy; plus `shadow_size`/`shadow_color`), `position`.
  `[text] accent` becomes the password field's typing colour. The field takes `size`,
  `rounding`, `inner_color` (fill), `outer_color` (idle border), `highlight_color`
  (top sheen), `font_color`, `accent_color`. Bright scenes use dark colours with a
  light shadow (clouds, city, pluton, by_on_ramp).
  Fonts installed: Inter / Inter Display, Adwaita Sans / Mono, Noto Sans (+ Condensed,
  Mono), Noto Serif, Liberation Serif, Carlito.
- Preview any wallpaper's look without switching: `LOCK_WALLPAPER=~/.config/wallpapers/clouds/clouds.png lock.sh --test 8`
  (test mode only). `LOCK_TEST_KEYS="abc<<x!" [LOCK_TEST_KEY_MS=250]` types into the
  test lock (`<` = backspace, `!` = enter); `LOCK_FPS=1` logs frames really presented
  per screen every 2 s.

## Testing safely

- `lock.sh --test [SECS]`: same screens as overlay windows, NOT a lock, closes
  after SECS (default 15). PAM uses `pam/test` (accepts only "letmein").
  `LOCK_TEST_PASSWORD=letmein lock.sh --test` auto-types it.
- `lock.sh --try [SECS]`: real lock that unlocks itself after SECS (default 10),
  plus a watchdog.
- `python3 lockgen.py --check` validates the config per monitor.
- Real lock: keep a TTY open (Ctrl+Alt+F3). Unlock from it with
  `lock.sh --unlock`. If the client was killed and the screen shows "lock died":
  `lock.sh --recover`.

Revert: restore the `*.bak-2026-09-29-*` copies (`-live` = the earlier hyprlock/
xray version), and point Super+L / PowerMenuWidget back at `hyprlock`.

## Frame rate and look (2026-09-29)

- The live scene runs at the monitor's refresh rate (lockgen passes the app an
  `fps` option; `[background] live_fps = N` overrides). Before, it ran at the
  harness default of 30 fps. `bevy/qml/bevyview.cpp` now lets the `fps` option
  lift the harness pacing (rebuild the QML plugin via `bevy/build.sh` if it is
  ever reverted). GPU cost is roughly 3x the old 30 fps.
- UI: big light clock, uppercase spaced date, small greeting, a pill field with a
  blurred-glass panel (only behind the field; `[input] glass = false` drops it),
  lavender/yellow/red/green outline states, dot pop-in, shake + red hint on a
  wrong password, caps-lock hint (keyboard LEDs via `LOCK_CAPS_LEDS`), fade in,
  green success and fade-out on unlock. Palette: Catppuccin Mocha.
- Backups: `*.bak-2026-09-29-fps` (also `bevy/qml/bevyview.*.bak-2026-09-29-fps`).

## Polish (2026-09-29)

- Password field is faux glass (translucent fill, thin state-coloured border, top
  sheen, no glow ring); the blur behind it is gone, so nothing bleeds and the frame rate
  is higher than before. `[input] glass = false` drops the sheen.
- Dots: each has its own fade + scale (150-170 ms ease-out); the row re-centres by
  easing a fractional length, so add/delete slides smoothly; the placeholder
  cross-fades; the "checking" pulse no longer fights the fades.
- Every wallpaper has its own typography (font, weight, size, tracking, casing, colours,
  shadow, field shape) in `meta/<stem>.toml`.
- Backups: `*.bak-2026-09-29-polish`.
