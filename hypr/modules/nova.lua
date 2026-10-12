-- Nova voice assistant and chat panel binds. Enable on a machine with
-- DEVICE.module("nova") in perdevice.lua. Needs ~/.config/nova-voice/env
-- (scripts/nova_voice.env.example, `nova_voice.sh setup`); without it the
-- chat panel stays shut and nova_voice.sh only prints what is missing.
hl.bind(DEVICE.mainMod .. " + T",         hl.dsp.exec_cmd("~/.config/scripts/nova_voice.sh toggle"))
hl.bind(DEVICE.mainMod .. " + SHIFT + T", hl.dsp.exec_cmd("~/.config/scripts/nova_voice.sh cancel"))
hl.bind(DEVICE.mainMod .. " + A",         hl.dsp.global("quickshell:toggleNovaChat"))
