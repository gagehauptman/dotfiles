# Dotfiles

My Hyprland setup on Arch Linux: a Quickshell bar and dashboard, a theme per
wallpaper, and the scripts that hold it together.

## What is in here

| Path | What it is |
|---|---|
| `hypr/` | Hyprland config (Lua), hyprlock fallback, per-device template |
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
     ttf-nerd-fonts-symbols qt6ct papirus-icon-theme network-manager-applet
yay -S quickshell-git
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

## Per-device settings

Anything specific to one machine stays out of the repo:

- `hypr/perdevice.lua` (copy from `hypr/perdevice.example.lua`): monitors,
  `DEVICE.monitor_priority` on multi-monitor setups, extra startup commands,
  optional voice-assistant binds.
- `quickshell/presets.local.json`: dashboard preset overrides.
- `~/.config/nova-voice/env`: voice assistant settings (see
  `scripts/nova_voice.env.example`).

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
