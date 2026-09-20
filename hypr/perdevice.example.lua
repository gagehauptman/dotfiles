-- Per-device Hyprland settings. Copy to ~/.config/hypr/perdevice.lua (gitignored)
-- and adjust; hyprland.lua loads it last if it exists. `DEVICE.mainMod` is the
-- main modifier ("SUPER").

-- Monitor layout (one hl.monitor per output)
hl.monitor({
    output   = "DP-1",
    mode     = "preferred",
    position = "0x0",
    scale    = 1,
})

-- Commands to run at start on this machine only, e.g. a game-streaming host
-- table.insert(DEVICE.startup, "systemctl --user start sunshine.service")

-- Voice assistant (off unless bound here; needs ~/.config/nova-voice/env,
-- see scripts/nova_voice.env.example and `nova_voice.sh setup`)
-- hl.bind(DEVICE.mainMod .. " + T",         hl.dsp.exec_cmd("~/.config/scripts/nova_voice.sh toggle"))
-- hl.bind(DEVICE.mainMod .. " + SHIFT + T", hl.dsp.exec_cmd("~/.config/scripts/nova_voice.sh cancel"))
