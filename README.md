# Dotfiles

My personal dotfiles for Hyprland on Arch Linux.

## Overview

```
dotfiles/
├── hypr/           # Hyprland window manager config
├── kitty/          # Kitty terminal config
├── nvim/           # Neovim config (lazy.nvim)
├── quickshell/     # Quickshell bar/widgets (QML)
├── scripts/        # Utility scripts
└── wallpapers/     # Wallpaper collection
```

## Dependencies

### Core

| [hyprland](https://hyprland.org/) | Tiling Wayland compositor |
| [quickshell](https://quickshell.outfoxxed.me/) | Qt6/QML shell toolkit |
| [kitty](https://sw.kovidgoyal.net/kitty/) | GPU-accelerated terminal |
| [awww](https://github.com/LGFae/awww) | Wallpaper daemon |
| [hyprlock](https://github.com/hyprwm/hyprlock) | Lock screen |

### Utilities

| Package | Description |
|---------|-------------|
| [grim](https://sr.ht/~emersion/grim/) | Screenshot tool |
| [slurp](https://github.com/emersion/slurp) | Region selection |
| [wl-clipboard](https://github.com/bugaevc/wl-clipboard) | Clipboard utilities |
| [playerctl](https://github.com/altdesktop/playerctl) | Media player control |
| [brightnessctl](https://github.com/Hummer12007/brightnessctl) | Brightness control |
| [pipewire](https://pipewire.org/) | Audio server |
| [neovim](https://neovim.io/) | Text editor |

## Installation

```bash
# Clone the repo
git clone https://github.com/gagehauptman/dotfiles.git ~/dotfiles

# Symlink configs
ln -sf ~/dotfiles/hypr ~/.config/hypr
ln -sf ~/dotfiles/kitty ~/.config/kitty
ln -sf ~/dotfiles/zed ~/.config/zed
ln -sf ~/dotfiles/quickshell ~/.config/quickshell
ln -sf ~/dotfiles/nvim ~/.config/nvim
ln -sf ~/dotfiles/scripts ~/.config/scripts
ln -sf ~/dotfiles/wallpapers ~/.config/wallpapers

```

### Hyprland Plugins

**[split-monitor-workspaces](https://github.com/Duckonaut/split-monitor-workspaces)** - Gives each monitor its own independent workspace namespace (1-10 per monitor instead of shared global workspaces). Essential for multi-monitor setups.

```bash
# Install via hyprpm (Hyprland's built-in plugin manager)
hyprpm update
hyprpm add https://github.com/Duckonaut/split-monitor-workspaces
hyprpm enable split-monitor-workspaces

# Verify it's loaded
hyprpm list
```

> **Note:** Plugins must be rebuilt after every Hyprland update. Run `hyprpm update` after upgrading Hyprland.

## Arch Packages

```bash
# Install all dependencies
pacman -S hyprland kitty awww hyprlock neovim \
          grim slurp wl-clipboard playerctl brightnessctl \
          pipewire pipewire-pulse jq socat wireplumber \
          noto-fonts noto-fonts-cjk noto-fonts-emoji \
          noto-fonts-extra ttf-nerd-fonts-symbols meson \
          qt6ct papirus-icon-theme

# Quickshell (AUR)
yay -S quickshell-git
```
