# Quickshell config

The bar, the dashboard (`Super+N`), the launchers and the pop-ups for
Hyprland. This file explains the parts you configure: dashboard presets,
per-device overrides, writing widgets in QML or as Rust/Bevy apps, and the
optional voice assistant.

The per-device rule is the same as in `hypr/`: everything committed has to
work on any machine. Anything about one particular machine goes in a
gitignored file next to the committed one (`presets.local.json`,
`hypr/perdevice.lua`, `~/.config/nova-voice/env`).

## Requirements

Arch package names. The base set is enough for the bar and the dashboard;
the other groups are only needed for the feature they belong to.

| Group | Packages |
|---|---|
| Shell | `quickshell-git` (AUR, 0.3 or newer), `hyprland` (0.56 or newer, it reads `hyprland.lua` directly), `qt6-base`, `qt6-declarative`, `qt6-wayland`, `qt6-5compat`, `qt6ct` |
| Fonts | `noto-fonts` (Noto Sans and Noto Sans Mono), `ttf-nerd-fonts-symbols` (the icons) |
| Bar and dashboard widgets | `playerctl`, `bluez-utils`, `lm_sensors`, `acpi`, `jq`, `curl`, `hyprlock`, `libnotify`, `awww` (wallpapers), `wl-clipboard`, `grim`, `slurp`, `wf-recorder`, `ffmpeg` (screenshot and recording buttons). Optional: `brightnessctl` for the brightness slider on laptops, `tailscale` for the Tailscale row, `network-manager-applet` for the tray applet started with Hyprland |
| Bevy widgets | `rustup` (or `rust`), `cmake`, `ninja`, `gcc` or `clang`, `vulkan-headers`, `vulkan-icd-loader` and your Vulkan driver (`vulkan-radeon`, `vulkan-intel` or `nvidia-utils`) |
| Globe widget | `python-numpy`, `python-pillow`, `hdf5` (its `h5dump` reads the NOAA weather mosaic), plus the Bevy group |
| Voice assistant | `whisper-cpp`, `uv`, `pipewire`, `ffmpeg`, `libnotify`, `playerctl`, `openssh`. For offline speech, `piper` is not packaged: put the release binary in `~/.local/bin` (or install `piper-tts-bin` from the AUR) and a voice model in `~/.local/share/piper` |

`scripts/nova_voice.sh status` and the build script for Bevy both tell you
what is missing on a machine.

## Dashboard presets

The dashboard is built from a preset instead of hard-coded QML. Presets are
JSON because Quickshell reads JSON natively with `FileView` and `JSON.parse`;
there is no TOML parser in Quickshell or Qt.

| File | Tracked | Purpose |
|---|---|---|
| `presets.json` | yes | Committed defaults: `default`, `minimal`, `focus`, `bevy`. |
| `presets.local.json` | no (gitignored) | Optional per-device overrides, same schema. Presets merge over the committed ones by name, and its `active` wins over the committed one. |
| `~/.local/state/quickshell/dashboard.json` | outside the repo | Remembers the preset last chosen over IPC. Wins over both `active` keys. |

Both preset files are watched, so saving one re-renders the dashboard.
A missing or invalid `presets.json` logs an error (`qs log`) and falls back
to the built-in copy of `default` in `DashboardConfig.qml`. A broken preset or
widget entry is skipped with a warning and the rest still loads.

### Switching at runtime

```sh
qs ipc call dashboard setPreset minimal   # remembered across restarts
qs ipc call dashboard nextPreset          # cycle in file order
qs ipc call dashboard getPreset
qs ipc call dashboard listPresets
qs ipc call dashboard reload              # re-read both files, e.g. after creating presets.local.json
qs ipc call dashboard toggleFullscreen    # same as the toggleDashboardFullscreen shortcut
qs ipc call dashboard toggleOn DP-2             # open or close on a named monitor without moving focus
qs ipc call dashboard toggleFullscreenOn DP-2   # the same for fullscreen
```

### Fullscreen

`Super+Shift+N` (`quickshell:toggleDashboardFullscreen`) opens the dashboard
filling the monitor, or toggles the size while it is open. It works per
monitor like `Super+N`: only the focused monitor changes and each screen keeps
its own size. The pocket grows to the whole screen and the row height is
computed from the screen height, so the preset's rows and columns stretch to
fill it. The size is forgotten when the dashboard closes.

### Schema

```jsonc
{
  "active": "default",            // optional; used when nothing is remembered
  "presets": {
    "<name>": {
      "columns": 4,               // equal-width columns when the bar is horizontal (default 4)
      "widthPercent": 60,         // pocket length as % of the bar's long axis (default 60)
      "portraitColumns": 2,       // columns for the automatic portrait reflow (default 2)
      "widgets": [ <widget>, ... ],
      "portrait": {               // optional explicit layout for rotated screens;
        "columns": 2,             // leave it out to get the automatic reflow
        "widgets": [ <widget>, ... ]
      }
    }
  }
}
```

A `<widget>` entry:

```jsonc
{
  "type": "weather",              // key in the registry in DashboardConfig.qml
  "col": 2, "row": 1,             // optional; leave both out to auto-flow in list order
  "colSpan": 1, "rowSpan": 1.5,   // default 1; rowSpan may be fractional
  "options": { "location": "Oslo" }   // optional; passed to the widget as `options`
}
```

Geometry: one row is `metrics.dashWidgetHeight` tall and rows are separated
by `metrics.spacingNormal`. Row *n* starts *n* pitches down, and a span of
*s* rows is *s* widget heights plus *s − 1* gaps, so `rowSpan: 1.5` gives the
height the old hand-built layout used for Services. Columns work the same
way.

Placement: entries with both `col` and `row` reserve their cells first. The
rest flow in list order into the lowest free spot (`col` alone pins the
column). Spans wider than `columns` are clamped. On a portrait screen the
`portrait` block is used if present, otherwise the landscape list is
re-packed into `portraitColumns` ignoring `col` and `row`.

### Widget types and options

| type | file | options |
|---|---|---|
| `services` | ServicesWidget.qml | – |
| `systemstats` | SystemStatsWidget.qml | `show`: subset of `["cpu","ram","disk","bluetooth","upgrade"]` |
| `miscstats` | MiscStatsWidget.qml | – |
| `quote` | QuoteWidget.qml | – |
| `weather` | WeatherWidget.qml | `location`: `"lat,lon"` or a place name (default: geolocate by IP), `label`: display name |
| `network` | NetworkStatsWidget.qml | – |
| `profile` | ProfileWidget.qml | – |
| `music` | MusicWidget.qml (card mode) | `size`: `"small"`, `"normal"`, `"large"` (text size) |
| `bevy` | BevyWidget.qml | `app`: an app under `bevy/apps/` (default `planet`), `title`. A Rust/Bevy scene running inside the shell; shows a hint if the module or the app is not built |
| `globe` | BevyWidget.qml (app `globe`) | Live weather, light pollution, aircraft and satellites on a vector globe with Natural Earth coastlines, borders, names, cities and airports by zoom level. Aircraft are filled airliner silhouettes coloured by altitude band, airports discs with a plane cut-out, cities dots (capitals ringed), satellites body-and-panels icons; all grow as you zoom in. Zoomed out only the high traffic shows, zoomed in each aircraft has a tail of recent positions and its callsign. Drag to orbit, wheel to zoom (out to the geostationary belt while orbits are on); click an aircraft for its flight, route and path, a satellite for its orbit and a Follow pill. Pills toggle Weather, Lights, Aircraft and Orbits, Home flies home. Options: see "Globe options" below. Starts its service (below) |

Per-device example: a laptop that wants a smaller dashboard with its own
weather location, without touching the committed file, gets a
`presets.local.json` like this:

```jsonc
{
  "active": "laptop",
  "presets": {
    "laptop": {
      "columns": 3, "widthPercent": 50,
      "widgets": [
        { "type": "systemstats", "rowSpan": 1.5, "options": { "show": ["cpu", "ram", "bluetooth"] } },
        { "type": "weather", "options": { "location": "59.91,10.75", "label": "Home" } },
        { "type": "quote" }
      ]
    }
  }
}
```

### Globe options

The gear at the end of the globe's pill row opens a short settings panel:
weather and lights opacity, the grid, which satellite groups to show and
which of those groups get orbit lines, the aircraft altitude cutoff, the
city size names start at and whether airports show. Changes apply at once and
are remembered per device in `$XDG_STATE_HOME/quickshell/bevy-globe.json`
(so are the pill toggles); "Reset to the preset" forgets them. Everything
else lives in the preset. All of it has a default, so `"options": {}`
works. A fuller example:

```jsonc
{
  "title": "Globe",
  "layers": ["weather", "sats"],            // start on: weather, lp (lights), air (aircraft), sats
  "home": [48.86, 2.35],                    // or "Paris, France", or { "location": "...", "label": "Paris" }; default: geolocate by IP
  "view": { "type": "focus", "lat": 48.86, "lon": 2.35, "dist": 1.8 },
  // or { "type": "chase", "satellite": "ISS", "target": [48.86, 2.35], "standoff": 0.45 } (no target: home)
  "satellites": {
    "groups": ["stations", "visual", "weather", "gnss"],   // CelesTrak groups; also science, starlink
    "extra": [20580, "NOAA 19"],            // single objects: NORAD numbers or CelesTrak name searches
    "show": ["ISS", "HST", "group:gnss", "NOAA*"],   // only these (patterns); default everything loaded
    "hide": ["STARLINK*"],
    "track_groups": ["stations"],           // whole groups that get orbit lines (the panel's "Orbit lines")
    "tracks": ["NOAA 19"],                  // single satellites with an orbit line on top of that; default none
    "labels": ["ISS", "HST"],               // names; default the ISS, Tiangong and Hubble
    "track": { "orbits": 1.0, "points": 128, "alpha": 0.45 },
    "style": [                              // first match wins; colours are theme names or hex
      { "match": "ISS", "color": "pink", "size": 1.6 },
      { "match": "group:gnss", "color": "blue", "size": 0.8, "track_color": "lavender", "track_alpha": 0.3 }
    ],
    "size": 1.0                             // icon size multiplier (icons also grow with the zoom)
  },
  "weather": { "opacity": 0.75, "saturation": 0.55 },
  "lights": { "opacity": 0.8, "day": 0.25 },   // day: how much shows on the sunlit side
  "aircraft": { "min_speed": 40, "min_altitude": 500, "size": 1.0, "bands": [10000, 25000, 36000],
                "declutter": true,      // zoomed out only the high traffic shows
                "tails": true,          // a few minutes of positions behind each, when zoomed in
                "labels": true },       // callsigns beside them, when zoomed in
  "labels": { "countries": true, "regions": true, "cities": true, "airports": true, "min_population": 100000, "size": 1.0 },
  "graticule": { "show": true, "step": 15 },
  "colors": { "coast": "teal", "borders": "lavender", "regions": "textMuted", "grid": "#6c708648",
              "rim": "teal", "home": "pink", "fill": "panelDeep",
              "countries": "textPrimary", "region_names": "textPrimary", "cities": "textSecondary", "capitals": "textPrimary",
              "aircraft_low": "green", "aircraft_mid": "yellow", "aircraft_high": "orange", "aircraft_cruise": "blue" },
  "controls": true, "info": true
}
```

A satellite pattern is a NORAD number, `group:NAME`, or a case-insensitive
glob on the name (`*` any run, `?` one character); a bare word matches the
name or its first word, so `"ISS"` finds `ISS (ZARYA)`. `"satellites":
["stations", "visual"]` is shorthand for just the groups. Colours take a
theme name (`teal`, `textMuted`, ...), `#rrggbb` or `#rrggbbaa`. A `view`
control event switches camera rigs at runtime: `orbit`, `focus:lat,lon[,dist]`,
`chase:NAME[:lat,lon][:standoff]`; `select` with a hex or `sat:NAME` picks
an aircraft or satellite.

### Widget services

A registry entry may declare `service: [command...]`. DashboardConfig runs
the command once per shell (shared by every screen) while the active preset
uses that widget type, restarts it if it exits, and marks it ready when it
prints `ready` on stdout. Widgets read `dashboardConfig.serviceReady[type]`.
This is for a widget that needs a long-running local helper, such as a cache
or a local server, so that one copy serves every screen.

The `globe` widget uses one: `scripts/globeserver.py` listens on
`127.0.0.1:38471` and serves

| path | what |
|---|---|
| `/geo.json` | home position by IP (cached) |
| `/weather.json`, `/weather/<t>.png`, `/weather/<t>/inset.png?z=&x0=&y0=&n=` | hourly frame times and the global cloud layer for one, 4096x2048 equirectangular, as cloud-top index plus coverage. The global layer is NOAA's GMGSI, NESDIS's hourly mosaic of every geostationary infrared imager (8 km, open data on AWS, about 40 minutes behind). The inset is a Mercator window at the satellites' best zoom from their own 10-minute imagery (NASA GIBS for GOES and Himawari, EUMETView for Meteosat), blended by viewing angle; the app asks for 16x16 tiles at zoom 6 around home |
| `/weather/lut.png` | the 256-entry palette the index is drawn through |
| `/lp.png`, `/lp/inset.png?z=&x0=&y0=&n=` | light pollution zones (Lorenz atlas) as an 8192x4096 index, and a window at atlas resolution (16x16 tiles at zoom 8 around home) |
| `/lp/lut.png?pal=&tint=` | the zone palette in the shell's colours |
| `/adsb.json` | every aircraft OpenSky knows about, dead-reckoned to one instant, plus adsb.lol detail near home |
| `/aircraft/<hex>.json` | one aircraft: state, type and registration, its route from adsbdb.com (origin, destination, airline) and its path (OpenSky's track of the flight plus positions seen locally) |
| `/tle.json?groups=&catnr=&names=` | two-line elements from CelesTrak for the named groups, single objects by NORAD number and name searches, refreshed every 12 hours |
| `/vectors.bin` | coastlines and borders at the 50m and 10m scales plus country, region, place and airport labels, from Natural Earth (public domain), simplified and packed once (about 49 MB downloaded, a 6 MB bundle) |

The app blends each inset over the global texture in the shader, so home
gets two zoom levels more than the rest of the globe. Tiles and built frames
are cached under `~/.cache/quickshell/globe`. OpenSky
works anonymously with a small request budget; put `OPENSKY_CLIENT_ID` and
`OPENSKY_CLIENT_SECRET` in `quickshell/secrets.env` (gitignored) for the
authenticated rate. The globe app polls the service in a background thread,
so a slow first weather frame never blocks the shell.

## Making a widget

### In QML

1. Create the QML file next to the others. `templates/DataWidget.qml` (title
   and content) and `templates/ThreeRowWidget.qml` (title, content, footer)
   already declare `property var options`; a standalone `Item` should declare
   `property var options: ({})`. Read settings from it with defaults, for
   example `options.location ?? ""`. `metrics` (per-monitor scale, fonts,
   spacing), `bar`, `root` and `Theme.colors` are in scope as in every other
   widget. The Loader's size is the cell's size, so use `anchors.fill: parent`.
2. Add one line to `registry` in `DashboardConfig.qml`:
   `"mywidget": { file: "MyWidget.qml" }`. Add `props: { ... }` for fixed
   initial properties and `service: [...]` for a helper process.
3. Reference it by type in a preset, or in `presets.local.json` for one
   machine.

### As a Rust (Bevy) app

A card can run a Bevy app inside the shell process on the GPU device the
scene graph already uses. Frames are not copied and there is no second
window. `bevy/` is a cargo workspace:

- `harness/` is the `quickshell-bevy` library. It takes Qt's Vulkan instance,
  physical device, device and graphics queue from `QSGRendererInterface`,
  hands them to wgpu (`device_from_raw`), owns the image the card shows,
  keeps the tagged camera aimed at it, submits two layout barriers per frame
  so wgpu and Qt agree on the image's state, and passes pointer input on.
  Its `widget!` macro exports the C entry points the Qt side looks up.
- `apps/<name>/` holds one cdylib per app. `planet` is the demo, `globe` is
  the weather and aircraft globe, and `apps/README.md` has the minimal
  template.
- `snapshot/` builds `bevy-snapshot`, which runs an app library on a Vulkan
  device of its own and writes a frame as PNG, for checking an app with no
  shell running.
- `qml/` is the Qt QML plugin with `BevyView`. It loads the app library a
  card names with `dlopen`, runs the app in `beforeRendering` on Qt's render
  thread so its queue work lands before Qt's own frame, and shows the same
  `VkImage` through `QSGVulkanTexture::fromNative`.

Writing an app:

```sh
cp -r bevy/apps/planet bevy/apps/myapp     # then rename the crate in Cargo.toml
```

```rust
// bevy/apps/myapp/src/lib.rs
use bevy::prelude::*;
use quickshell_bevy::prelude::*;

pub struct MyApp;
impl Plugin for MyApp {
    fn build(&self, app: &mut App) { app.add_systems(Startup, setup).add_systems(Update, tick); }
}
quickshell_bevy::widget!(MyApp);

fn setup(mut commands: Commands) {
    // Tag the camera; the harness keeps it pointed at the card. If you add
    // no camera you get a default transparent 3D one.
    commands.spawn((Camera3d::default(), WidgetCamera,
                    Camera { clear_color: ClearColorConfig::Custom(Color::NONE), ..default() },
                    Transform::from_xyz(0.0, 2.0, 6.0).looking_at(Vec3::ZERO, Vec3::Y)));
}

fn tick(input: Res<WidgetInput>, options: Res<WidgetOptions>) {
    // input.x, input.y: pointer over the card in 0..1; input.down while held;
    // input.scroll: wheel steps since the last frame; input.width, input.height:
    // card size in pixels. options.0 is the card's preset `options` object as
    // JSON, with a `theme` object of the shell's colours added (`#rrggbb`).
}
```

Controls and readouts: declare them in `WidgetUi` and the card draws them,
toggles and buttons as pills along the bottom, readouts as `label value` in
the title line, and settings (sliders, choices, multiple choices, text and
toggles, grouped in sections) behind a gear. Input arrives as
`WidgetEvent`s and the control's own state follows it. The card remembers
settings and toggles per device in `$XDG_STATE_HOME/quickshell/bevy-<app>.json`
and hands them back at the next start in the options as
`"settings": { id: value }`; a `settings.reset` button clears them.

```rust
fn setup(mut ui: ResMut<WidgetUi>) {
    ui.toggle("grid", "Grid", true).button("reset", "Reset").info("fps", "fps", "60");
    ui.setting("Look", Control::slider("glow", "Glow", 0.0, 1.0, 0.05, 0.3))
        .setting("Look", Control::select("style", "Style", &["flat", "shaded"], "flat"))
        .setting("", Control::button("settings.reset", "Reset"));
}

fn presses(mut events: EventReader<WidgetEvent>, ui: Res<WidgetUi>) {
    for e in events.read() {
        match e.id.as_str() {
            "grid" => { let on = e.on(); /* same as ui.is_on("grid") */ }
            "reset" => {}
            _ => {}
        }
    }
}
```

`ui.info(...)` with an unchanged value costs nothing, so it is fine to call
every frame. A preset can hide the pills or the readouts of any Bevy card
with `"controls": false` or `"info": false` in its options.

Camera rigs: `quickshell_bevy::rig` has `above(dir, dist)` for looking
straight down at a point of a body at the origin, `chase(subject, target,
standoff)` for a view from behind one object towards another, `on_sphere(lat,
lon)` and `approach(current, goal, dt, tau)` to glide between poses. They
are plain functions over `Transform`, so an app keeps its own input handling
around them; the globe's Home button and Follow pill are built on them.

Files such as glTF models, textures and fonts go in `bevy/apps/myapp/assets/`
and load through `AssetServer` as usual. Keep the clear colour transparent so
the card shows through. Then build and install everything:

```sh
bevy/build.sh      # harness, every app and the Qt plugin, installed to
                   # ~/.config/quickshell/modules/Bevy/{qmldir, libbevyqml.so, apps/<name>/}
```

and point a card at it: `{ "type": "bevy", "options": { "app": "myapp", "title": "My app" } }`.
Different cards can run different apps, each with its own Bevy instance on
the shared device. An app that deserves its own widget type gets a registry
entry with `props: { app: "myapp" }`, as `globe` does, which is also where a
`service` goes.

To look at an app without the shell (or on a locked screen):

```sh
bevy/target/release/bevy-snapshot ~/.config/quickshell/modules/Bevy/apps/myapp/libmyapp.so out.png \
    --size 1400x900 --seconds 10 --bg 1e1e2e --scroll 2 --drag 0.5,0.5,0.6,0.5 \
    --send grid=false --options '{"theme": {"teal": "#94e2d5"}}'
```

`--send id=value` presses a control the app declares, and the controls and
readouts are printed when the frame is written.

Quickshell must run on the Vulkan backend with the module path set.
`hypr/hyprland.lua` starts it as
`QSG_RHI_BACKEND=vulkan QML2_IMPORT_PATH=$HOME/.config/quickshell/modules quickshell`.
Without the module or the app the card shows a hint instead of failing. A
rebuilt app or plugin needs a Quickshell restart because loaded libraries
stay for the life of the process. Apps use the Bevy version pinned in the
workspace (0.16 with wgpu 24).

## Voice assistant (`Super+T`, opt-in)

Push-to-talk conversation with an [openclaw](https://openclaw.ai) agent.
`scripts/nova_voice.sh` records the mic until you stop talking (Silero VAD),
transcribes locally with whisper.cpp, streams the reply from the openclaw
gateway and speaks it sentence by sentence while the rest is still arriving.
While a turn is in flight `VoiceBarWidget.qml` takes the music slot in the
bar and shows the state, a level meter and the text. It reads
`$XDG_RUNTIME_DIR/nova-voice/state.json`, which the engine rewrites as the
turn progresses.

It is off by default and nothing about a machine is in the repo. A machine
turns it on with two per-device files, described below.

### Setup

1. **Gateway.** You need an openclaw gateway this machine can reach, usually
   the one on your server over Tailscale or the LAN, with its OpenAI-style
   endpoint enabled. The engine posts to `$NOVA_GATEWAY_URL/v1/chat/completions`
   with `Authorization: Bearer $NOVA_GATEWAY_TOKEN`, addresses the agent as
   `openclaw/<NOVA_AGENT>` (`main` by default) and can pin a model with
   `NOVA_MODEL`. Take the URL and a gateway token from your openclaw config.
2. **Config file.** `scripts/nova_voice.sh setup` creates the Python venv
   (Python 3.12 through `uv`, since `onnxruntime` has no wheels for the
   newest Python yet), downloads the Silero VAD model and writes
   `~/.config/nova-voice/env` from `scripts/nova_voice.env.example`. Fill in
   `NOVA_GATEWAY_URL` and `NOVA_GATEWAY_TOKEN`; everything else has a default.
   The presence of this file is also what makes the bar indicator exist on
   the machine.
3. **Speech to text.** `scripts/nova_voice.sh setup whisper` downloads a
   whisper.cpp model and installs `nova-whisper.service` (from
   `scripts/nova-whisper.service.example`) as a user service running
   `whisper-server` on `127.0.0.1:8178`. Edit the unit if you prefer the
   `small.en` model to `base.en`.
4. **Text to speech.** With no further config the reply is spoken by
   [piper](https://github.com/rhasspy/piper) (`NOVA_PIPER_BIN` and a voice in
   `NOVA_PIPER_VOICE`). For better voices set either `NOVA_ELEVENLABS_API_KEY`
   and `NOVA_ELEVENLABS_VOICE` (streamed directly, the fastest option) or
   `NOVA_GATEWAY_SSH`, an SSH host where openclaw runs, in which case the reply
   is voiced there with `openclaw gateway call tts.speak` and the key never
   leaves the server. `NOVA_TTS` forces one backend; `auto` tries them in
   that order.
5. **Keybinds.** Add to `~/.config/hypr/perdevice.lua` (see
   `hypr/perdevice.example.lua`), then `hyprctl reload`:

   ```lua
   hl.bind(DEVICE.mainMod .. " + T",         hl.dsp.exec_cmd("~/.config/scripts/nova_voice.sh toggle"))
   hl.bind(DEVICE.mainMod .. " + SHIFT + T", hl.dsp.exec_cmd("~/.config/scripts/nova_voice.sh cancel"))
   ```

6. `scripts/nova_voice.sh status` shows what is configured and reachable
   plus the timings of the last turns. `nova_voice.sh ask "…"` and
   `nova_voice.sh say "…"` test the pipeline without the mic.

### Using it

`Super+T` starts listening. The turn ends by itself when you stop talking, or
press again to send right away. Pressing while it thinks or speaks
interrupts and listens again, and after a reply it keeps listening for a
follow-up for a few seconds (`NOVA_CONVERSE`). `Super+Shift+T` cancels.
Media playing through `playerctl` is paused for the duration of a turn.
Turns and timings go to `~/.local/state/nova-voice/conversation.log`, the
engine's own output to `engine.log` next to it. The agent sees the request
as coming from `[voice, <NOVA_DEVICE>]` (the hostname by default) with the
gateway user `<NOVA_DEVICE>-voice`, so one agent can tell your machines
apart.
