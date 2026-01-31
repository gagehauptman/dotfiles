# Dotfiles

My personal dotfiles for Hyprland on Arch Linux.

## Overview

```
dotfiles/
├── hypr/           # Hyprland window manager config
├── kitty/          # Kitty terminal config
├── quickshell/     # Quickshell bar/widgets (QML)
├── scripts/        # Various utility scripts
├── systemd/user/   # Systemd user services/timers
├── wallpapers/     # Wallpaper collection
```

## Dependencies

### Core

| [hyprland](https://hyprland.org/) | Tiling Wayland compositor |
| [quickshell](https://quickshell.outfoxxed.me/) | Qt6/QML shell toolkit |
| [kitty](https://sw.kovidgoyal.net/kitty/) | GPU-accelerated terminal |
| [swww](https://github.com/LGFae/swww) | Wallpaper daemon |
| [hyprlock](https://github.com/hyprwm/hyprlock) | Lock screen |

### Utilities

| [grim](https://sr.ht/~emersion/grim/) | Screenshot tool |
| [slurp](https://github.com/emersion/slurp) | Region selection |
| [wl-clipboard](https://github.com/bugaevc/wl-clipboard) | Clipboard utilities |
| [playerctl](https://github.com/altdesktop/playerctl) | Media player control |
| [brightnessctl](https://github.com/Hummer12007/brightnessctl) | Brightness control |
| [pipewire](https://pipewire.org/) | Audio server |

### GOES Earth Live Wallpaper

The `goes_earth_live` wallpaper fetches real-time satellite imagery from NOAA's GOES-West satellite.

**Requires:** [goes-imagery](https://github.com/ghauptman/goes-imagery)

The systemd timer (`goes-update.timer`) updates the wallpaper every 10 minutes.

## Installation

```bash
# Clone the repo
git clone https://github.com/ghauptman/dotfiles.git ~/dotfiles

# Symlink configs
ln -sf ~/dotfiles/hypr ~/.config/hypr
ln -sf ~/dotfiles/kitty ~/.config/kitty
ln -sf ~/dotfiles/quickshell ~/.config/quickshell
ln -sf ~/dotfiles/scripts ~/.config/scripts
ln -sf ~/dotfiles/wallpapers ~/.config/wallpapers

# Symlink systemd user units
mkdir -p ~/.config/systemd/user
ln -sf ~/dotfiles/systemd/user/goes-update.service ~/.config/systemd/user/
ln -sf ~/dotfiles/systemd/user/goes-update.timer ~/.config/systemd/user/

# Enable GOES wallpaper timer
systemctl --user daemon-reload
systemctl --user enable --now goes-update.timer
```

## Arch Packages

```bash
# Install all dependencies
pacman -S hyprland kitty swww hyprlock \
          grim slurp wl-clipboard playerctl brightnessctl \
          pipewire pipewire-pulse jq socat wireplumber \
          noto-fonts noto-fonts-cjk noto-fonts-emoji \
          noto-fonts-extra ttf-nerd-fonts-symbols

# Quickshell (AUR)
yay -S quickshell-git
```
