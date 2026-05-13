local mainMod = "SUPER"

hl.config({
    general = {
        gaps_in     = 5,
        gaps_out    = 12,
        border_size = 2,
        col = {
            active_border   = { colors = { "0xFFcba6f7", "0xFF89b4fa" }, angle = 45 },
            inactive_border = "0xFF45475a",
        },
    },

    decoration = {
        rounding = 15,
        blur = {
            enabled = false,
            size    = 1,
            passes  = 1,
        },
    },

    xwayland = {
        force_zero_scaling = true,
    },

    debug = {
        damage_tracking = 0,
    },

    render = {
        cm_enabled = false,
    },
})

hl.config({
    input = {
        kb_layout  = "us",
        kb_variant = "altgr-intl",
        kb_model   = "",
        kb_options = "",
        kb_rules   = "",

        follow_mouse = 1,

        touchpad = {
            disable_while_typing = false,
            clickfinger_behavior = true,
            natural_scroll       = true,
        },
    },
})

hl.config({ animations = { enabled = true } })

hl.curve("UWU1", { type = "bezier", points = { {0.22, 1}, {0.36, 1} } })

hl.animation({ leaf = "windows",    enabled = true, speed = 5, bezier = "UWU1",    style = "slide" })
hl.animation({ leaf = "fade",       enabled = true, speed = 3, bezier = "default" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 4, bezier = "UWU1",    style = "slidevert" })

hl.on("hyprland.start", function()
    hl.exec_cmd("hyprpm reload -n")
    hl.exec_cmd("QT_QPA_PLATFORMTHEME=qt6ct quickshell")
    hl.exec_cmd("~/.config/scripts/init/wallpaper.sh")
    hl.exec_cmd("nm-applet")
    hl.exec_cmd("dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP")
end)

hl.env("GTK_THEME",                "Material-DeepOcean-Borderless")
hl.env("MOZ_ENABLE_WAYLAND",       "1")
hl.env("LIBVA_DRIVER_NAME",        "radeonsi")
hl.env("XDG_SESSION_TYPE",         "wayland")
hl.env("__GLX_VENDOR_LIBRARY_NAME","radeonsi")
hl.env("WLR_NO_HARDWARE_CURSORS",  "1")
hl.env("GDK_BACKEND",              "wayland,x11")
hl.env("QT_QPA_PLATFORM",          "wayland;xcb")

hl.bind(mainMod .. " + RETURN",       hl.dsp.exec_cmd("kitty"))
hl.bind(mainMod .. " + X",            hl.dsp.window.close())
hl.bind(mainMod .. " + SHIFT + X",    hl.dsp.exec_cmd("hyprctl kill"))
hl.bind(mainMod .. " + V",            hl.dsp.window.float({ action = "toggle" }))
hl.bind(mainMod .. " + Z",            hl.dsp.global("quickshell:togglePowerMenu"))
hl.bind(mainMod .. " + B",            hl.dsp.exec_cmd("floorp"))
hl.bind(mainMod .. " + D",            hl.dsp.exec_cmd("discord"))
hl.bind(mainMod .. " + F",            hl.dsp.window.fullscreen({ mode = "fullscreen" }))
hl.bind(mainMod .. " + SHIFT + F",    hl.dsp.window.fullscreen({ mode = "maximized" }))
hl.bind(mainMod .. " + Q",            hl.dsp.exec_cmd("~/.config/scripts/bar_toggle.sh"))
hl.bind(mainMod .. " + SHIFT + Q",    hl.dsp.exec_cmd("hyprctl reload"))
hl.bind(mainMod .. " + SHIFT + E",    hl.dsp.exit())
hl.bind(mainMod .. " + L",            hl.dsp.exec_cmd("hyprlock"))

hl.bind(mainMod .. " + code:60",      hl.dsp.exec_cmd("playerctl --player spotifyd,%any next"))
hl.bind(mainMod .. " + code:59",      hl.dsp.exec_cmd("playerctl --player spotifyd,%any previous"))
hl.bind(mainMod .. " + space",        hl.dsp.exec_cmd("playerctl --player spotifyd,%any play-pause"))

hl.bind("Print",                      hl.dsp.exec_cmd("~/.config/scripts/hyprland_capture_full.sh"))
hl.bind(mainMod .. " + Print",        hl.dsp.exec_cmd("~/.config/scripts/hyprland_capture_partial.sh"))
hl.bind("SHIFT + Print",              hl.dsp.exec_cmd("bash -c 'pgrep -x wf-recorder && bash /storage/git/dotfiles/scripts/hyprland_record_stop.sh || bash /storage/git/dotfiles/scripts/hyprland_record_full.sh'"))
hl.bind(mainMod .. " + SHIFT + Print",hl.dsp.exec_cmd("bash -c 'pgrep -x wf-recorder && bash /storage/git/dotfiles/scripts/hyprland_record_stop.sh || bash /storage/git/dotfiles/scripts/hyprland_record_region.sh'"))

hl.bind(mainMod .. " + left",         hl.dsp.focus({ direction = "left"  }))
hl.bind(mainMod .. " + right",        hl.dsp.focus({ direction = "right" }))
hl.bind(mainMod .. " + up",           hl.dsp.focus({ direction = "up"    }))
hl.bind(mainMod .. " + down",         hl.dsp.focus({ direction = "down"  }))

-- Push-to-talk: hold F4 to unmute mic, release to mute
hl.bind("F4",                         hl.dsp.exec_cmd("pactl set-source-mute @DEFAULT_SOURCE@ 0"))
hl.bind("F4",                         hl.dsp.exec_cmd("pactl set-source-mute @DEFAULT_SOURCE@ 1"), { release = true })
hl.bind(mainMod .. " + M",            hl.dsp.exec_cmd("pactl set-source-mute @DEFAULT_SOURCE@ 0"))

hl.bind("F1",                         hl.dsp.exec_cmd("pactl set-sink-mute   @DEFAULT_SINK@ toggle"))
hl.bind("F2",                         hl.dsp.exec_cmd("pactl set-sink-volume @DEFAULT_SINK@ -5%"))
hl.bind("F3",                         hl.dsp.exec_cmd("pactl set-sink-volume @DEFAULT_SINK@ +5%"))
hl.bind(mainMod .. " + F4",           hl.dsp.exec_cmd("pactl set-source-mute @DEFAULT_SOURCE@ toggle"))

hl.bind(mainMod .. " + N",            hl.dsp.global("quickshell:toggleDashboard"))
hl.bind(mainMod .. " + W",            hl.dsp.global("quickshell:toggleWallpaperSelector"))
hl.bind(mainMod .. " + R",            hl.dsp.global("quickshell:toggleAppSelector"))

hl.bind(mainMod .. " + mouse:272",    hl.dsp.window.drag(),   { mouse = true })
hl.bind(mainMod .. " + mouse:273",    hl.dsp.window.resize(), { mouse = true })

hl.config({
    plugin = {
        split_monitor_workspaces = {
            count                        = 10,
            keep_focused                 = 1,
            enable_notifications         = 0,
            enable_persistent_workspaces = 1,
        },
    },
})

local smw = hl.plugin.split_monitor_workspaces

for i = 0, 9 do
    local key = tostring(i)
    hl.bind(mainMod .. " + " .. key, function() return smw.workspace(i) end)
    hl.bind("ALT + " .. key, function()
        smw.move_to_workspace_silent(i)
        smw.workspace(i)
    end)
end

local perdevice = os.getenv("HOME") .. "/.config/hypr/perdevice.lua"
if io.open(perdevice, "r") then dofile(perdevice) end
