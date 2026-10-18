# Lone Sloop (sailboat) live wallpaper

A painted sloop alone off Daytona Beach. The sky follows the real sun, moon (position and phase), planets and the real
stars (Yale Bright Star Catalogue, 9,000 stars with true positions, magnitudes and colours) for the local time. The sea, the clouds, rain, lightning and the boat's trim and heel follow the real weather (Open-Meteo plus
Open-Meteo Marine, no key, refreshed every 10 min, cached in `~/.cache/sailboat/weather.env`). With no data it shows a
calm, light breeze.

Design doc: `~/.openclaw/workspace/plans/sailboat-wallpaper.md` (on vic-server).

## Where things live (dotfiles)
- `scripts/wallpaper/bins/sailboat/scene/`: `sailboat_scene` (no GPU API). `sailboat.wgsl` holds all passes,
  `lib.rs` the state, cameras, palette and waves, `astro.rs` the sun/moon/planets/sidereal maths (+ precession), `stars.rs` + `stars.bin` the real star catalogue (Yale BSC5,
  see `scene/tools/README.md` for source, licence and how it is baked and drawn), `weather.rs` with
  `fetch_weather.sh` the feed and overrides, and `boat.rs` the mesh.
- `scripts/wallpaper/bins/sailboat/run` + `.keep-warm`: a scene of the warm renderer (`layer_shell_bevy --scene sailboat`).
- `scripts/wallpaper/bins/spinning_globe/src/sailboat.rs`: the renderer side (wgpu 30), wired into `main.rs`.
- `bevy/apps/sailboat/`: the selector preview and lock-screen app (Bevy 0.16 / wgpu 24, same passes).
- `wallpapers/sailboat/`: `sailboat.live`, `meta.json`, `theme.json`, `bar.json`, `kitty.conf`, `lock.toml`.

## Previewing states (dev tool, nothing on screen)
`~/sailboat-wallpaper/shot/target/release/sailboat-shot` renders offscreen to PNG:

    sailboat-shot --time 21:30 --wind 25 --storm --out x.png
    sailboat-shot --date 2026-10-27 --time 20:20          # full moon over the sea
    sailboat-shot --calm | --gale-ish: --wind 30 --cloud 60 | --rain 5 | --wave 2 | --dir 45 | --gust 35
    sailboat-shot --storm --find-flash --secs 0.5          # catch a lightning bolt
    sailboat-shot --live                                   # the real weather cache
    sailboat-shot --bench 20 --fps 30                      # both monitor sizes, for GPU load
    SAILBOAT_DEBUG=foam sailboat-shot ...                  # foam/crest debug colours

The wallpaper itself and the Bevy app take the same overrides from the environment: `SAILBOAT_TIME=21:30` (or unix
seconds), `SAILBOAT_DATE`, `SAILBOAT_WIND`, `SAILBOAT_GUST`, `SAILBOAT_WIND_DIR`, `SAILBOAT_CLOUD` (0-100),
`SAILBOAT_RAIN` (mm/h), `SAILBOAT_STORM=1`, `SAILBOAT_WAVE` (m), and `SAILBOAT_OFFLINE=1` (no fetching).

## Rebuild after editing the scene
- `~/sailboat-wallpaper/sync.sh` copies the dev tree into dotfiles. Otherwise copy `scene/` → `bins/sailboat/scene/`,
  `host/sailboat.rs` → `spinning_globe/src/sailboat.rs` and `bevy-app/` → `bevy/apps/sailboat/`.
- The host rebuilds itself through `bins/sailboat/run` on the next launch. The Bevy app is built with
  `cd bevy && cargo build --release -p sailboat`; copy `target/release/libsailboat.so` to
  `~/.config/quickshell/modules/Bevy/apps/sailboat/` by rename (or run `bevy/build.sh`).

## Desktop integration (same as the other live wallpapers)
- Selector (Super+W): `wallpapers/sailboat/sailboat.live` is listed by `list.sh`; its preview is the Bevy app
  `bevy/apps/sailboat` (`libsailboat.so` in `~/.config/quickshell/modules/Bevy/apps/sailboat/`). Rebuild it after a scene
  change, or the selector and the lock screen show the old look.
- Theme: picking it runs `scripts/theme/apply.py`, which reads `wallpapers/sailboat/theme.json` (palette derived from the
  scene: deep-sea navy, sail cream, sunlit-cloud peach accent, sea-glass accent2; Space Grotesk display font; Neovim
  overrides in `extra.nvim`) plus `bar.json` and `kitty.conf`. By-hand time-of-day variants, nothing automatic:
  `theme sailboat_dawn|sailboat_day|sailboat_sunset|sailboat_night` (`wallpapers/_presets/sailboat_*.json`).
- Lock screen: `wallpapers/sailboat/lock.toml` + the same Bevy app (live scene at the monitor's refresh rate). Poster frames
  for the first frame live in `~/.cache/lockscreen/poster/sailboat-<W>x<H>.png` (the lock refreshes them itself 3 s into a lock).
- Warm renderer: `bins/sailboat/.keep-warm` + `run` (scene `sailboat` of `layer_shell_bevy`); `wallpaper_select.sh` shows and
  hides it through the FIFO like the globe, the shuttle, the free return and Sputnik.
