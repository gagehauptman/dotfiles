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

### Widget services

A registry entry may declare `service: [command...]`. DashboardConfig runs
the command once per shell (shared by every screen) while the active preset
uses that widget type, restarts it if it exits, and marks it ready when it
prints `ready` on stdout. Widgets read `dashboardConfig.serviceReady[type]`.
This is for a widget that needs a long-running local helper, such as a cache
or a local server, so that one copy serves every screen. No committed widget
uses one at the moment.

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
- `apps/<name>/` holds one cdylib per app. `planet` is the demo and
  `apps/README.md` has the minimal template.
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

fn tick(input: Res<WidgetInput>) {
    // input.x, input.y: pointer over the card in 0..1; input.down while held;
    // input.width, input.height: card size in pixels
}
```

Files such as glTF models, textures and fonts go in `bevy/apps/myapp/assets/`
and load through `AssetServer` as usual. Keep the clear colour transparent so
the card shows through. Then build and install everything:

```sh
bevy/build.sh      # harness, every app and the Qt plugin, installed to
                   # ~/.config/quickshell/modules/Bevy/{qmldir, libbevyqml.so, apps/<name>/}
```

and point a card at it: `{ "type": "bevy", "options": { "app": "myapp", "title": "My app" } }`.
Different cards can run different apps, each with its own Bevy instance on
the shared device.

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
