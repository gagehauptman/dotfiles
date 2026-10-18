# Dotfiles

My Hyprland setup on Arch Linux: a Quickshell bar and dashboard, a theme per
wallpaper, and the scripts that hold it together.

## What is in here

| Path | What it is |
|---|---|
| `hypr/` | Hyprland config (Lua), personal and per-device templates, optional modules (`hypr/modules/`) |
| `quickshell/` | Bar, dashboard, launchers, power menu (QML). See [quickshell/README.md](quickshell/README.md) |
| `bevy/` | Rust/Bevy widgets (globe, planet, wallpaper scenes) rendered inside Quickshell |
| `wallpapers/` | One folder per wallpaper with its theme, lock screen layout and kitty overrides |
| `scripts/` | Wallpaper switching, theming ([README](scripts/theme/README.md)), lock screen ([README](scripts/lock/README.md)), status polls, screenshots, voice assistant |
| `kitty/`, `nvim/`, `zed/` | Terminal, Neovim (lazy.nvim), Zed |

Picking a wallpaper re-themes Quickshell, kitty, Hyprland borders, Zed, Firefox
and the lock screen together.

## Your own wallpapers (per device)

Add wallpapers or hide the repo ones without touching tracked files:

```bash
cp ~/.config/wallpapers/local.conf.example ~/.config/wallpapers/local.conf
```

`local.conf` is gitignored. One directive per line: `add <folder-or-image>`, `disable <name>`, `repo off` (hide all repo wallpapers), `active <name>` (pick at login). Details in the example file.

## Install

```bash
git clone git@github.com:gagehauptman/dotfiles.git ~/dotfiles
cd ~/dotfiles
for d in hypr kitty nvim quickshell scripts wallpapers zed; do
  ln -sfn "$PWD/$d" ~/.config/$d
done
```

Packages (Arch):

```bash
sudo pacman -S hyprland kitty awww hyprlock neovim \
     grim slurp wl-clipboard wf-recorder ffmpeg playerctl brightnessctl \
     pipewire pipewire-pulse wireplumber jq socat \
     noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra \
     ttf-nerd-fonts-symbols qt6ct papirus-icon-theme network-manager-applet \
     libvips python-pillow python-numpy
yay -S quickshell-git
```

Firefox live theming (once per machine, sudo; restart Firefox afterwards):

```bash
~/dotfiles/scripts/theme/firefox-live/install-autoconfig.sh
```

Hyprland needs to be 0.56 or newer (it reads `hyprland.lua` directly).
Optional groups (Bevy widgets, globe, voice assistant) list their extra
packages in [quickshell/README.md](quickshell/README.md#requirements).

### Bevy widgets

Needed for the live wallpaper previews, the globe and the lock screen scene:

```bash
~/dotfiles/bevy/build.sh
```

### Workspace plugin

[split-monitor-workspaces](https://github.com/zjeffer/split-monitor-workspaces)
gives each monitor its own workspaces (1-10, 11-20, ...). `hyprland.lua`
requires it from `hypr/plugins/` (gitignored):

```bash
mkdir -p ~/.config/hypr/plugins && cd ~/.config/hypr/plugins
git clone https://github.com/zjeffer/split-monitor-workspaces
cd split-monitor-workspaces
git checkout release/0.56.x   # match your Hyprland release; stay on main for hyprland-git
```

Pull it again (and switch release branch) after Hyprland updates.

### Without the plugin

If `hypr/plugins/split-monitor-workspaces` is missing, `hyprland.lua` logs it
and falls back to plain workspaces 1-10 shared by all monitors (same keys).

## Generic, per-device and personal

`main` is the generic setup, usable as is on anyone's machine: bar,
dashboard, launchers, wallpapers and themes, lock screen, screenshots.
Nothing personal or machine-specific is tracked. Those parts live in local
files that are gitignored (or outside the repo), and the features they
switch on are simply absent without them: no errors, empty widgets or dead
keybinds.

### Local overlay files

| File | Scope | What it holds | Template |
|---|---|---|---|
| `hypr/personal.lua` | shared | Personal Hyprland layer, the same on all of your machines; mainly optional modules (`DEVICE.module("nova")`). Loaded before `perdevice.lua` | `hypr/personal.example.lua` |
| `hypr/perdevice.lua` | host | Monitors, `DEVICE.monitor_priority`, extra startup commands (`DEVICE.startup`, e.g. Sunshine), `DEVICE.amd_env`, overrides | `hypr/perdevice.example.lua` |
| `wallpapers/local.conf` | host | Extra/disabled wallpapers, the one picked at login | `wallpapers/local.conf.example` |
| `quickshell/presets.local.json` | host | Dashboard preset overrides | see [quickshell/README.md](quickshell/README.md) |
| `quickshell/secrets.env` | shared | Optional OpenSky client id/secret for the globe's aircraft layer | `OPENSKY_CLIENT_ID=` / `OPENSKY_CLIENT_SECRET=` lines |
| `~/.config/nova-voice/env` | host | Voice assistant config (gateway, token, mic) | `scripts/nova_voice.env.example` |
| `~/.config/nova-voice/speakers.json` | shared | Voice assistant speaker names | `nova_voice.sh setup` |
| `~/.config/tessie.key` | shared | Tessie API key (Tesla) | the key on one line |

The list lives in `scripts/dotlocal.manifest`. The AMD driver env
(`radeonsi`) is set only when the `amdgpu` kernel module is loaded (override
with `DEVICE.amd_env`).

### Enabling the personal modules

| Module | Turned on by | Pieces |
|---|---|---|
| Nova voice assistant + chat panel | `~/.config/nova-voice/env` (`nova_voice.sh setup`), plus `DEVICE.module("nova")` in `hypr/personal.lua` (or `perdevice.lua` for one machine only) for the keybinds in `hypr/modules/nova.lua`: Super+T, Super+Shift+T, Super+A | `quickshell/Nova*.qml`, `NovaQuiz.js`, `NovaLatex.js`, `VoiceBarWidget.qml`, `assets/nova-lynx/`, `scripts/nova_voice.{sh,py}`, `scripts/polls/agentpoll.sh`. Needs an [openclaw](https://openclaw.ai) gateway and the nova client (`NOVA_CLIENT`); details in [quickshell/README.md](quickshell/README.md) |
| Tesla (Tessie) | an API key in `~/.config/tessie.key` | Car row on the Services card (`scripts/polls/tessie*.sh`), drives on the globe (`scripts/globeserver.py`) |

Without `nova-voice/env`, the chat panel's toggle and the voice indicator do
nothing. Without `tessie.key`, the Services card shows Tailscale only. Other
optional pieces just stay idle when their app is missing: Tailscale, Cider
(lyrics, the music card's Cider source), Sunshine.

### Keeping the overlay in sync (`scripts/dotlocal.sh`)

The canonical copies of the overlay files sit in a store outside the repo,
`~/.config/dotlocal/` (mode 700, never committed):

```
~/.config/dotlocal/
  shared/<name>          same on all of your machines (personal.lua, keys, speakers.json)
  hosts/<host>/<name>    one machine only, <host> = `uname -n` (perdevice.lua, nova-voice/env)
```

```bash
dotlocal.sh status              # store vs live files on this machine
dotlocal.sh capture             # live -> store, after editing a live file
dotlocal.sh -n apply            # dry run: what store -> live would change (secrets are not printed)
dotlocal.sh apply               # store -> live; replaced files are kept as <file>.bak-dotlocal-<time>
dotlocal.sh -n sync vic-laptop  # dry run: exchange shared/ and hosts/vic-laptop/ with that machine
dotlocal.sh sync vic-laptop     # newer copy of each file wins (rsync -u), no deletions
ssh vic-laptop '~/.config/scripts/dotlocal.sh -n apply'   # then apply there
```

`push`/`pull`/`sync` only move store files; the other machine's live config
changes only when `apply` runs there. A machine's own `hosts/<host>/` is
never sent anywhere except to that machine.

**A friend's machine:** nothing beyond the install steps; optionally
`hypr/perdevice.lua` for monitors. **Vic's machines:** the store above;
`dotlocal.sh apply` after cloning.

## Configuration

Everything is plain files; nothing needs a rebuild except the Rust parts
(Bevy widgets, wallpaper scenes). Tracked files hold the generic defaults,
per-machine changes go in the gitignored overlay files from
[Generic, per-device and personal](#generic-per-device-and-personal).

### Hyprland (`hypr/`)

- `hyprland.lua` is the shared config: gaps, borders, animations, input
  (`kb_layout` / `kb_variant`), startup (`hyprland.start`) and every keybind
  (`hl.bind(mainMod .. " + KEY", ...)`). Reload with `Super+Shift+Q`.
- `perdevice.lua` (copy of `perdevice.example.lua`, gitignored, loaded last):
  monitors (`hl.monitor`), `DEVICE.monitor_priority` (which monitor owns
  workspaces 1-10, 11-20, ...), `DEVICE.startup` (extra start commands),
  `DEVICE.amd_env`, and any override of the defaults above.
- `personal.lua` (copy of `personal.example.lua`, gitignored, loaded before
  `perdevice.lua`): settings shared by all of your machines, mainly
  `DEVICE.module("nova")` to load `hypr/modules/nova.lua`.
- Window border colours are rewritten by the theme script on every wallpaper
  change; do not edit them by hand.

### Kitty (`kitty/kitty.conf`)

Font (`font_family`, `font_size`), padding, opacity and bell are set in
`kitty.conf`. Colours come from `include current-theme.conf`, a generated,
gitignored file written on every wallpaper change from the wallpaper's
`theme.json`. Per-wallpaper kitty tweaks go in `wallpapers/<stem>/kitty.conf`
and are appended to the generated colours.

### Neovim (`nvim/`)

`init.lua` bootstraps lazy.nvim, sets options (indent, numbers, clipboard,
search) and loads `lua/plugins/*.lua` (one spec file per area: `editor`,
`treesitter`, `init`, `lsp`). Language servers are configured in `lua/lsp.lua`
with the native `vim.lsp.config` / `vim.lsp.enable` (nvim 0.11+; rust-analyzer
is set up, add servers there and install their binaries). Plugin versions are
pinned in `lazy-lock.json` (`:Lazy restore` / `:Lazy update`). Colours follow
the wallpaper theme through the `extra.nvim` block of its `theme.json`.

### Quickshell bar and widgets (`quickshell/`)

- The dashboard is data: `quickshell/presets.json` (committed) plus
  `quickshell/presets.local.json` (gitignored, merged by preset name). Each
  preset lists widgets with `type`, grid position and `options`. Switch with
  `qs ipc call dashboard setPreset <name>` or `nextPreset`; both files are
  watched. Schema and every widget's options (weather `location`/`label`,
  systemstats `show`, globe options, ...) are in
  [quickshell/README.md](quickshell/README.md#dashboard-presets).
- Sizes, spacing and fonts come from `Theme` / `metrics` in the QML, and
  colours from the current wallpaper's theme; per-wallpaper bar tweaks such as
  `panelOpacity` live in `wallpapers/<stem>/bar.json`.
- `quickshell/secrets.env` (gitignored, in the repo folder) holds optional
  `OPENSKY_CLIENT_ID` / `OPENSKY_CLIENT_SECRET` lines for the globe's aircraft
  layer. Never commit it.
- Bevy widgets are built with `bevy/build.sh` into
  `~/.config/quickshell/modules/`. Rebuild one after editing its Rust app, e.g.
  `cd bevy && cargo build --release -p sailboat`, then `bevy/build.sh` (or
  copy the `.so` in place by rename).
- Changes to QML take effect on a Quickshell reload (`qs` restarts the shell);
  do not reload while the lock screen or a voice turn is in use.

### Poll scripts (`scripts/polls/`)

Each widget feeds from a small shell script that prints one `|`-separated line
(`cpupoll.sh`, `systempoll.sh`, `weatherpoll.sh`, `networkpoll.sh`,
`batterypoll*.sh`, `calendarpoll.sh`, `ciderpoll.sh`, `tessiepoll.sh`, ...).
Identical commands are shared between widgets (`PollHub`), so adding another
widget with the same poll costs nothing. Parameters are passed as arguments
from the preset options (`weatherpoll.sh <location> <label>`) or read from the
environment / small files:

| Script | Configured by |
|---|---|
| `weatherpoll.sh` | `location` / `label` widget options (default: geolocate by IP); cache `/tmp/weather_cache*`, 5 min |
| `calendarpoll.sh` | calro over ssh: `CALRO_SSH` (env or `~/.config/calro/env`), else `NOVA_GATEWAY_SSH`; `fixture` option for sample data |
| `tessiepoll.sh`, `tessiecmd.sh` | `~/.config/tessie.key` (see Tesla below) |
| `agentpoll.sh` | the Nova gateway (`~/.config/nova-voice/env`) |
| the rest | no config; they read `/proc`, `nmcli`, `bluetoothctl`, `pactl`, `playerctl`, `/var/log/pacman.log` |

To change how often something refreshes, edit the interval on its
`PollProcess` in the widget's QML.

### Wallpapers and themes (`wallpapers/`, `scripts/theme/`)

One folder per wallpaper: the image or a `<stem>.live` descriptor,
`theme.json` (palette, fonts, rounding, borders; inherits a Catppuccin flavour
from `_presets/`), `bar.json`, `kitty.conf`, `lock.toml` and `meta.json`.
Pick one with `Super+W`. `theme <preset>` applies a theme by hand (for example
`theme sailboat_dawn|sailboat_day|sailboat_sunset|sailboat_night`); nothing
switches time-of-day variants automatically. Per-machine additions,
exclusions and the login wallpaper go in `wallpapers/local.conf`. Full format:
[scripts/theme/README.md](scripts/theme/README.md).

Live scenes (globe, space shuttle, free return, Sputnik, sailboat) are scenes
of one warm renderer, `scripts/wallpaper/bins/spinning_globe` (binary
`layer_shell_bevy --scene <stem>`), started through each scene's `run` and
`.keep-warm`. It rebuilds itself through cargo on the next launch.

#### Sailboat (Lone Sloop) tunables

The sailboat scene is tuned through `SAILBOAT_*` environment variables, read by
both the wallpaper renderer and the Bevy app that previews it and draws the
lock screen. Unset values keep the defaults; set them in the environment that
starts the renderer.

| Variable | Default | Meaning |
|---|---|---|
| `SAILBOAT_HEAVE` | `1.0` | how much of the wave height the hull follows (vertical) |
| `SAILBOAT_PITCH` | `0.25` | fraction of the wave slope the bow pitches |
| `SAILBOAT_ROLL` | `0.25` | fraction of the wave slope the hull rolls |
| `SAILBOAT_GULL_SPEED` | `1.0` | multiplier on the speed the gulls circle at |
| `SAILBOAT_SCALE` | `0.6` above 800 px tall, else `1.0` | resolution fraction of the sea and sky pass (0.1-1) |
| `SAILBOAT_SKY_HZ` | `10` | how often the clouds are redrawn |
| `SAILBOAT_STATE_FILE` | `$XDG_RUNTIME_DIR/sailboat/sim.state` | animation state shared by wallpaper and lock screen (same sea and boat on both) |
| `SAILBOAT_NO_SYNC` | off | `1` stops the sharing |
| `SAILBOAT_WEATHER_FILE` | `~/.cache/sailboat/weather.env` | weather cache (Open-Meteo, no key, refreshed every 10 min) |

Weather and time overrides for previews: `SAILBOAT_TIME` (`HH:MM` or unix
seconds), `SAILBOAT_DATE`, `SAILBOAT_WIND`, `SAILBOAT_GUST`,
`SAILBOAT_WIND_DIR`, `SAILBOAT_CLOUD` (0-100), `SAILBOAT_RAIN` (mm/h),
`SAILBOAT_STORM=1`, `SAILBOAT_WAVE` (m), `SAILBOAT_OFFLINE=1`.
`SAILBOAT_DEBUG=foam` and `SAILBOAT_PROFILE=noboat|nocomp` are development
aids. The location is `LAT` / `LON` in `scene/src/lib.rs`, the look (palette,
text layout) in `wallpapers/sailboat/{theme.json,lock.toml}`. More in
[scripts/wallpaper/bins/sailboat/README.md](scripts/wallpaper/bins/sailboat/README.md).

### Lock screen (`scripts/lock/`)

`Super+L` runs `lock.sh`, a Quickshell `WlSessionLock` client that draws the
wallpaper's live scene. Layout and text style are per wallpaper in
`wallpapers/<stem>/lock.toml` (`[clock]`, `[date]`, `[greeting]`, `[input]`,
positions as `"x%, y%"`, fonts, colours), falling back to `scripts/lock/meta/default.toml`.
`lockgen.py` resolves the file into `$XDG_RUNTIME_DIR/lockscreen/lock.json`.
Poster frames are cached in `~/.cache/lockscreen/poster/` and regenerated when
older than `POSTER_MAX_AGE` (20 min) in `lockgen.py`. If the lock client dies
at start, `lock.sh` falls back to `hyprlock`. Details and tuning:
[scripts/lock/README.md](scripts/lock/README.md).

### Nova voice assistant and chat (opt-in)

`~/.config/nova-voice/env` (from `scripts/nova_voice.env.example`, created by
`nova_voice.sh setup`) holds the gateway URL and token, identity, TTS provider
and keys, and listening options. It lives outside the repo and is synced by
`dotlocal.sh`. Enable the keybinds with `DEVICE.module("nova")`. The chat
panel renders replies with `quickshell/NovaMd.js` (markdown, LaTeX) and
`NovaHl.js` (code highlighting), coloured from the live theme.

### Tesla (Tessie)

Needs only a Tessie API key on one line in `~/.config/tessie.key` (mode 600,
outside the repo, listed in `scripts/dotlocal.manifest`). `scripts/polls/_tessie.sh` reads it,
picks the account's first vehicle and caches its VIN in `/tmp/tessie_vin_$UID`
for 5 minutes. `tessiepoll.sh` feeds the Services card (the car row is hidden
without the key), `tessiecmd.sh` sends lock, climate and media commands, and
`scripts/globeserver.py` shows drives on the globe. No key is ever stored in
the repo.

## Keybinds

`Super` is the main modifier.

| Keys | Action |
|---|---|
| `Return` | Terminal (kitty) |
| `X` / `Shift+X` | Close / kill window |
| `F` / `Shift+F` | Fullscreen / maximize |
| `V` | Toggle floating |
| `B` / `D` | Firefox / Discord |
| `R` | App launcher |
| `W` | Wallpaper selector |
| `N` / `Shift+N` | Dashboard / fullscreen dashboard |
| `Z` | Power menu |
| `L` | Lock screen |
| `1`-`0` | Workspace on the current monitor (`Shift` moves the window) |
| `Print` | Screenshot (`Super` for a region, `Shift` to record) |
| `Shift+Q` | Reload Hyprland |
| `C` | Control center (notifications, quick settings) |
| `Tab` / `Shift+Tab` | Next / previous dashboard tab |
| `T` / `Shift+T`, `A` | Nova voice / cancel, Nova chat (only with `DEVICE.module("nova")` in `personal.lua`) |
