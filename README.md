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
