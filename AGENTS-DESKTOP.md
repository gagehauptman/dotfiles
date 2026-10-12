# Vic's desktop layout (read before touching vic-desktop / vic-laptop)

**Sync:** canonical copy = `/storage/git/dotfiles/AGENTS-DESKTOP.md` on vic-desktop (git repo, Vic reviews/pushes).
Copies: vic-server `~/.openclaw/workspace/DESKTOP.md` (Nova; pointer in AGENTS.md); vic-laptop `~/.claude/DESKTOP.md` (+ pointer in `~/.claude/CLAUDE.md`).
Update the canonical one, then `scp vic-desktop:/storage/git/dotfiles/AGENTS-DESKTOP.md <dest>` for the others. Verified 2026-10-09 on vic-desktop only; laptop facts are unverified (offline).

## Stack
Arch Linux, Hyprland (>=0.56, **Lua config**), Quickshell bar/dashboard/launchers, kitty, nvim (lazy.nvim), Firefox (Super+B), Discord. Audio: pipewire/wpctl, playerctl (`--player spotifyd,%any`; Cider shows up on MPRIS), Cider = Apple Music app. Tesla data via `scripts/polls/tessie*.sh` into the bar. Wallpaper daemon `awww` for stills.
Vic's live session: **TTY1 (loginctl session 2)**: zsh -> start-hyprland -> Hyprland -> all his apps.

## Dotfiles map
Repo `/storage/git/dotfiles` (origin `git@github.com:gagehauptman/dotfiles.git`, branch main, often dirty/ahead: Vic's WIP; never reset/clean/push).
`~/.config/{hypr,kitty,nvim,quickshell,scripts,wallpapers,zed}` are **plain symlinks** into the repo (no stow). So `~/.config/scripts/lock/` and `/storage/git/dotfiles/scripts/lock/` are the same directory, not two copies. Editing either edits the repo.
Not in repo: `~/.config/nova-voice/env`, `hypr/perdevice.lua` (per-device, gitignored), `wallpapers/local.conf`, `quickshell/presets.local.json`.

## Hyprland
Config: `~/.config/hypr/hyprland.lua` (Lua). Per-device: `hypr/perdevice.lua` (template `perdevice.example.lua`); optional modules in `hypr/modules/` (`DEVICE.module("nova")`). Generic/per-device/personal split: repo README. Plugin: split-monitor-workspaces (`hypr/plugins/`, loaded via hyprpm). Monitors on desktop: **DP-4** Samsung S34CG50 3440x1440@100 left (workspaces 1-10), **HDMI-A-3** Samsung LS27R75 2560x1440@144 right (11-20; also the Sunshine/Moonlight stream).
Binds (mainMod=Super): Return kitty, B firefox, D discord, L lock, Z power menu, W wallpaper selector, Shift+Q `hyprctl reload`, T/Shift+T nova voice, A Nova chat, Print screenshots, Space/media keys playerctl.
hyprctl syntax is Lua now:
- `hyprctl dispatch "hl.dsp.exec_cmd(\"/path/cmd\")"`
- `hyprctl dispatch "hl.dsp.dpms({ action = \"off\" })"`
- `hyprctl eval 'hl.config({misc={...}})'`
Old `hyprctl dispatch exec foo` style does not apply.

## Quickshell
Config `~/.config/quickshell/` (= repo `quickshell/`): `shell.qml`, widgets as `*Widget.qml` (Music*, Weather, Calendar, SystemStats, NetworkStats, Tesla/services, Workspaces, PowerMenu, WallpaperSelector, NovaChat, Lyrics...), `modules/` (Bevy QML module), `presets.json` (dashboard), `README.md` (read it). Started at login by hyprland.lua (`quickshell`, env QSG_RHI_BACKEND=vulkan). Polls in `scripts/polls/`, listeners in `scripts/listeners/`. Nova voice: clients append to `$XDG_RUNTIME_DIR/nova-voice/events.jsonl`, shell.qml tails it for the chat panel; control via `scripts/nova_voice.sh`.
Process list shows two quickshells: the bar (`quickshell`) and the lock (`quickshell -p /storage/git/dotfiles/scripts/lock/qs`). Both are normal.
Perf pass 2026-10-10 (Nova): every `PollProcess` with the same command is shared across screens through `quickshell/templates/PollHub.qml` (`shared: false` opts out); `scripts/polls/cpupoll.sh` and `systempoll.sh` read `/proc/stat` instead of running `top`; `shell.qml`'s shadow `MultiEffect` layer (`main`) is sized to the bar strip + pocket instead of the whole screen. Originals: `*.bak-2026-10-10` beside each file. Quickshell live-reloads on QML edits (`qs log -i <instance>` shows "Reloading configuration" / errors).

## Wallpapers
Each wallpaper lives in `wallpapers/<stem>/` (image or `<stem>.live`, plus `theme.json`, `bar.json`, `kitty.conf`, `lock.toml`, `meta.json`). Picking one re-themes Quickshell, kitty, Hyprland borders, Zed, Firefox and the lock screen.
- Switch: `~/.config/scripts/wallpaper/wallpaper_select.sh [--preview] <path>`; GUI selector = Super+W. List: `scripts/wallpaper/list.sh`. Saved choice: `scripts/wallpaper/wpsave.txt`; login applies via `scripts/init/wallpaper.sh`. Per-device: `wallpapers/local.conf`.
- Live scenes: wgpu/Bevy host binary named `layer_shell_bevy` (`scripts/wallpaper/bins/spinning_globe/target/release/`), scenes via `--scene <stem>` (globe, space_shuttle, free_return, sputnik...), kept warm and shown/hidden via a FIFO. Bevy widget apps are in `bevy/apps/`.
- The `starbase` scene was deleted on 2026-10-09 at Vic's request (no wallpaper dir, no bin). Do not rebuild it unless asked.

## Lock screen
Script `~/.config/scripts/lock/lock.sh` (header and `README.md` beside it explain everything). It is an **ext-session-lock client built in Quickshell** (`qs/shell.qml`, `WlSessionLock`) that draws the current wallpaper's live scene. A resident hidden instance is started at login (`lock.sh --warm`); Super+L only shows it. `lockgen.py` reads `wallpapers/<stem>/lock.toml`.
**Why "hyprlock" appears:** (1) the PAM service is named `hyprlock` (`/etc/pam.d/hyprlock` = `auth include login`, left over from the old package), the Quickshell lock just uses that name to check the login password; (2) `lock.sh` falls back to the real `hyprlock` binary (static `~/.config/hypr/hyprlock.conf`) only if the Quickshell lock dies at startup. The `hyprlock` program is NOT installed (`which hyprlock` fails) and `hypr/hyprlock.conf` does not exist, so that fallback cannot run today: if the Quickshell lock dies, there is no backup lock.
State: `$XDG_RUNTIME_DIR/lockscreen/` (`lock.log`, `lock.json`, `resident.pid`).

| Command | Safe? |
|---|---|
| `lock.sh --preview [DIR]` | Safest: offscreen PNGs, nothing on screen |
| `lock.sh --test [SECS]` | Safe: overlay windows, not a lock, pass "letmein" |
| `lock.sh --try [SECS]` | Real lock that self-unlocks (default 10 s). Only if Vic asked |
| `lock.sh --warm` | Harmless, login/wallpaper-change refresh |
| `lock.sh` (bare) | REAL LOCK. Only when Vic explicitly asks |
| `lock.sh --unlock` / `--recover` | Unlock / clear the red "lock died" screen |

Stuck locked: Ctrl+Alt+F3 to a TTY, run `~/.config/scripts/lock/lock.sh --unlock`.
**Incident 2026-10-09:** an agent ran `lock.sh` directly over SSH without Hyprland's env. lock.log: "the resident lock did not lock; starting a fresh one", then "wl_display error 0: invalid object 43"; the lock failed and left stray quickshell processes. The retry through `hyprctl dispatch "hl.dsp.exec_cmd(\"/home/v1k/.config/scripts/lock/lock.sh\")"` worked ("resident lock secure ... after the key").

## Remote-agent rules (ssh, no graphical env)
```
export XDG_RUNTIME_DIR=/run/user/$(id -u) WAYLAND_DISPLAY=wayland-1
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t $XDG_RUNTIME_DIR/hypr | head -1)
```
- Drive GUI things through `hyprctl dispatch "hl.dsp.exec_cmd(...)"`; do not launch GUI/lock binaries straight from ssh.
- Read `lock.log` and confirm "secure" before doing anything else after a lock. Never DPMS monitors off right after locking without that check.
- Prefer `--preview`/`--test` for any lock work.

## Laptop differences (vic-laptop) — UNVERIFIED
Offline from vic-server on 2026-10-09 (Tailscale: offline, last seen 1d; ssh timed out). Unknown: monitors, Hyprland socket, whether `/storage/git/dotfiles` exists, perdevice.lua. Per the repo, per-device config belongs in `hypr/perdevice.lua`; lock scales to laptop screens; `brightnessctl` is used there. Re-verify when it is online. Rule from Vic: SharePoint needs Firefox on the laptop: `ssh vic-laptop`, set the env above (check the real socket name), then `hyprctl dispatch focuswindow class:firefox` / reopen the page there.

## Don't-do list
- NEVER kill tty1 processes, Hyprland, start-hyprland, or the session without Vic's explicit confirmation.
- Don't kill/restart quickshell, layer_shell_bevy or the resident lock "to clean up".
- Don't run a bare `lock.sh`, `--try`, or DPMS-off unless Vic asked.
- Don't edit lock scripts, hyprland.lua or Quickshell QML unless asked; the repo has Vic's uncommitted work (no `git reset/checkout/clean/stash`, no push).
- Don't install or reference `hyprlock` as if it were the lock.
- `*.bak-*` files are Vic's/agents' snapshots; leave them.

## Recipe: lock + monitors off from a remote agent (worked 2026-10-09, Vic confirmed)
Only when Vic explicitly asks to lock / turn monitors off.
1. Set the env from "Remote-agent rules" above (XDG_RUNTIME_DIR, HYPRLAND_INSTANCE_SIGNATURE).
2. Truncate the log, then lock THROUGH Hyprland (same path as the Super+L keybind), never by running lock.sh from the ssh shell:
   `: > $XDG_RUNTIME_DIR/lockscreen/lock.log; hyprctl dispatch "hl.dsp.exec_cmd(\"/home/v1k/.config/scripts/lock/lock.sh\")"`
3. Read `$XDG_RUNTIME_DIR/lockscreen/lock.log`. Two outcomes both ended up locked:
   - "resident lock secure N ms after the key": the resident lock took it.
   - "the resident lock (PID) did not lock; starting a fresh one": the fresh lock client (`quickshell -p /storage/git/dotfiles/scripts/lock/qs`, new PID) then took over; "secure" was NOT logged, so a missing "secure" line is not proof of failure. Check that the fresh `quickshell -p .../lock/qs` process is alive, and ask Vic if still unsure.
   A genuine failure is a wl_display protocol error with no lock client afterwards (that was the bare-over-ssh run).
4. Only after the lock is confirmed: `hyprctl dispatch "hl.dsp.dpms({ action = \"off\" })"`; verify with `hyprctl monitors | grep dpmsStatus` (0 = off; monitors: DP-4 and HDMI-A-3). Waking: any key/mouse input (or `hl.dsp.dpms({ action = "on" })`).
5. The old syntax `hyprctl dispatch dpms off` only prints a Lua-shorthand note and does nothing.
