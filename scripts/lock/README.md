# Lock screen

`lock.sh` (Super+L and the power-menu Lock button) is a real ext-session-lock-v1
client: a Quickshell `WlSessionLock` (`qs/shell.qml`, run as its own instance,
not the bar). It draws the current wallpaper's **live, animated Bevy scene**
itself through the `Bevy` QML module (same renderer the bar/wallpaper selector
use), so there is no workspace switching, no see-through lock, no snapshot, no
cat. It stays resident and hidden between locks (see Startup speed). PAM is Quickshell's `PamContext` on the `hyprlock` service (auth include
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
  Positions are `"x%, y%"` (+y up) from the `halign`/`valign` anchor. Per monitor:
  `[monitor."HDMI-A-3".clock]` (avoid: names differ per machine).
- **Alignment is by ink** (2026-09-29): an element's box is its glyphs' tight
  width x the font's cap height, not Qt's text box. The old box carried the side
  bearings (several px at 100pt+), the trailing letter spacing and the line's
  ascent/descent, so a big clock, a tracked uppercase date and the field never
  shared an edge; and vertical % offsets with fixed-px fonts made the gaps drift
  with every font size. Now left/right/center edges line up exactly.
- Groups instead of fixed rows: `below = "clock"` / `above = "input"` + `gap`
  (px) hangs an element off another, aligned to its edge (default: date under the
  clock, greeting over the field), so moving the clock moves the date with it.
  `below = ""` frees it. `offset = "x, y"` nudges.
- `font_size` takes points or `"N%"` of the screen height. Sizes, gaps and px
  offsets are designed for a 1440px-tall screen and scale with the screen (a
  laptop keeps the same composition); `[text] ui_scale = N` pins it.
- `relative_to = "subject"`: anchor to the box of the wallpaper's subject (from
  its foreground mask) instead of the screen, so a clock can sit on the subject
  whatever the monitor's crop.
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

## Depth (iPhone-style: clock between background and subject)

Stills can carry masks in `wallpapers/<stem>/lock/` (8-bit greyscale PNG, same
aspect as the image, white = selected):

```toml
[depth]
foreground = "lock/fg-mask.png"   # the subject: drawn over depth = "behind" text
background = "lock/bg-mask.png"   # the far plane (sky): the rest is drawn over depth = "far" text

[clock]
depth = "behind"                  # front (default) | behind | far
```

Planes, bottom to top: background + shade, `far` text, midground (image minus
the bg mask), `behind` text, foreground (image under the fg mask), front text
and the field. lockgen.py cuts the per-monitor layers out of the same
cover-cropped still with brightness and the top/bottom shade baked in (Pillow +
numpy; cached in `$XDG_RUNTIME_DIR/lockscreen/depth/`), so they match the
background pixel for pixel; QML only stacks images. Without Pillow/numpy, or on
live wallpapers, it draws without depth.

Masks are made locally by `masks.py` (BiRefNet through rembg, CPU, offline once
the model is cached; set-up in its docstring): `masks.py STEM` for a subject,
`masks.py --sky [--dark 0.1] STEM` for a skyline/treeline silhouette. 20
wallpapers use a foreground mask, canaveral1 and evening_light a sky mask.

**Crisp edges (2026-09-30).** The first masks were soft: BiRefNet only sees
1024x1024, its answer was stretched to 2560 px, blurred (Gaussian 0.6), then
stretched again (bilinear) to the monitor, so a 2-3 px model edge became a
6-10 px ramp on a 3440 px screen. Now masks.py upsamples it with a colour guided
filter onto the image's own edges, alpha-mattes a thin band along the edge (and
whatever the model was unsure of, e.g. wires) with KNN matting, and stores the
mask at the image's resolution (up to 3840 px), 0/1 everywhere else. lockgen.py
then scales it per monitor (Lanczos) and redraws the edge `[depth]
edge_softness` px wide (default 1.0: one antialiased pixel; 0 = the stored mask
as is). The cut-out's colour is never blurred: it is the same Lanczos
cover-crop as the background.

**Holes.** BiRefNet paints see-through gaps (a dish's missing panels, lattices,
gaps between struts) as subject. `holes = true` under `[depth]` (antenna) makes
masks.py run GrabCut (OpenCV, seeded with the mask, remove-only) to find them and
matte them, so the sky shows through and text behind the subject shows in the
gaps; thin members (wires, struts) survive the matting. Needs
`opencv-python-headless` in the masks venv. Old masks:
`~/lock-masks-bak-2026-09-30-crisp/`.

## Testing safely

- `lock.sh --preview [DIR]`: renders each monitor offscreen to `DIR/<monitor>.png`
  (default `$XDG_RUNTIME_DIR/lockscreen/preview`); nothing appears on screen, no
  PAM. `LOCK_WALLPAPER=~/.config/wallpapers/clouds/clouds.png lock.sh --preview`
  previews another wallpaper; `LOCK_PREVIEW_BOXES=1` outlines the alignment boxes.
  Live (Bevy) scenes show as their flat colour there.

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

## Startup speed (2026-09-30)

- **Resident lock.** `lock.sh --warm` (Hyprland start; also after any normal
  unlock of a fresh lock) runs `qs/shell.qml` with `LOCK_RESIDENT=1`: compiled,
  hidden, images decoded, 0% CPU, ~140-200 MB. Hidden is *not locked*: no lock
  object, no surfaces. Super+L runs lockgen, then IPC `engage`, which sets
  `WlSessionLock.locked`; lock.sh waits for `state` = `secure` (the compositor's
  `locked` event). No answer/no confirmation within ~3 s: it kills the resident
  and starts a fresh lock (hyprlock fallback as before). After an unlock the
  resident goes back to hidden instead of quitting. A wallpaper change
  (`wallpaper_select.sh --warm`, niced) only makes caches and has the resident
  re-read lock.json; it never starts one at nice 19.
- **Not possible: a warm, paused Bevy scene.** Quickshell creates the lock
  surfaces only when the lock is taken and destroys them on unlock
  (`WlSessionLock::unlock`), and each window has its own Vulkan device, so the
  Bevy app cannot outlive one lock without patching Quickshell. Instead the
  scene starts after the first frame (BevyView builds the app on the window's
  second frame) over a **poster**: a frame of the scene the lock saves to
  `~/.cache/lockscreen/poster/<stem>-WxH.png` 3 s into a lock (again when the app
  is rebuilt), cross-faded once the scene draws (`frameReady`).
- lockgen caches the depth result (`<key>.json` next to the cut-outs), so a
  cached lock does no image work (0.24 s -> 0.05 s); `--warm` makes the caches
  at login and on every wallpaper change.
- Images load synchronously (no black first frame), fade-in 250 ms (was 900).
- Timing: `lock.log` has "first frame <monitor> at N ms" and "live scene up";
  resident locks also "resident lock secure N ms after the key".
- Revert to a fresh process per lock: `kill $(cat $XDG_RUNTIME_DIR/lockscreen/resident.pid)`
  and drop the `lock.sh --warm` line from hypr/hyprland.lua (lock.sh will start
  one again after the next normal unlock unless that `exec "$0" --warm` goes too).
