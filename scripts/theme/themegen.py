#!/usr/bin/env python3
"""Generate wallpapers/<stem>/theme.json from the seed table below.

Development tool: the theme.json files it writes are the source of truth once
generated; edit those by hand (or edit a seed here and re-run to regenerate
one). Nothing at runtime imports this.

    themegen.py                 write every theme (and wallpapers/_presets/*)
    themegen.py clouds night    only these stems

A seed is: name, dark, bg, fg, accent, accent2, ui/mono/display font,
r (corner radius scale, 1 = the stock look, 0 = square, 2 = pills),
b (border width scale, 0 = borderless), and optionally hue (how far the
semantic hues red/green/blue... lean toward the accent, default 0.3) and
sat (saturation multiplier).
"""
import colorsys, json, sys
from pathlib import Path

WALLPAPERS = Path(__file__).resolve().parents[2] / "wallpapers"

def hx(s):
    s = s.lstrip("#"); return tuple(int(s[i:i+2], 16) / 255 for i in (0, 2, 4))
def tohex(c): return "#%02x%02x%02x" % tuple(max(0, min(255, round(v * 255))) for v in c)
def mix(a, b, t): return tuple(x + (y - x) * t for x, y in zip(hx(a), hx(b)))
def mixh(a, b, t): return tohex(mix(a, b, t))
def hls(c): return colorsys.rgb_to_hls(*hx(c))

# Semantic hue slots: (hue degrees, saturation) — tinted toward the accent.
SLOTS = {
    "red": (352, .75), "orange": (24, .85), "yellow": (44, .85), "green": (132, .55),
    "teal": (172, .55), "cyan": (190, .70), "blue": (215, .80), "indigo": (234, .65),
    "violet": (266, .65), "lavender": (250, .70), "pink": (322, .70),
}

def lean(h, target, t):
    d = ((target - h + 180) % 360) - 180
    return (h + max(-25, min(25, d * t))) % 360

def palette(s):
    dark = bool(s["dark"]); bg, fg, acc, acc2 = s["bg"], s["fg"], s["accent"], s["accent2"]
    tint = s.get("hue", .3); sat = s.get("sat", 1.0)
    ah = hls(acc)[0] * 360
    L = .74 if dark else .40
    if not dark: sat *= .72
    p = {}
    for name, (h, sa) in SLOTS.items():
        t = 0 if name == "red" else tint
        r = colorsys.hls_to_rgb(lean(h, ah, t) / 360, L + (.04 if name in ("yellow", "cyan", "orange") else 0) * (1 if dark else -1), min(1, sa * sat))
        p[name] = tohex(r)
    if dark:
        p.update(background=bg, panel=mixh(bg, "#000000", .28), panelDeep=mixh(bg, "#000000", .5),
                 inset=mixh(bg, fg, .10), border=mixh(bg, fg, .20))
    else:
        p.update(background=bg, panel=mixh(bg, "#000000", .05), panelDeep=mixh(bg, "#000000", .10),
                 inset=mixh(bg, "#000000", .07), border=mixh(bg, "#000000", .18))
    p.update(textPrimary=fg, textSecondary=mixh(fg, bg, .28), textMuted=mixh(fg, bg, .55),
             accent=acc, lavender=acc2 if hls(acc2)[1] > .3 else p["lavender"])
    p["error"] = p["red"]; p["success"] = p["green"]; p["warning"] = p["yellow"]
    # contrast of text on the accent (for filled accent buttons)
    p["onAccent"] = bg if hls(acc)[1] > .5 else fg
    return p

def theme(stem, s):
    return {
        "name": s["name"], "stem": stem, "dark": bool(s["dark"]),
        "inherits": s.get("inherits"),
        "fonts": {"ui": s["ui"], "mono": s["mono"], "display": s["display"]},
        "style": {"radius": s["r"], "border": s["b"]},
        "palette": palette(s),
        # extra colours for the lock screen / terminal / compositor
        "extra": {"accent2": s["accent2"]},
    }

# ---------------------------------------------------------------------------
# name, dark, bg, fg, accent, accent2, ui, mono, display, r, b
def S(name, dark, bg, fg, accent, accent2, ui, mono, display, r, b, **kw):
    return dict(name=name, dark=dark, bg=bg, fg=fg, accent=accent, accent2=accent2,
                ui=ui, mono=mono, display=display, r=r, b=b, **kw)

RAJ, STM, ORB = "Rajdhani", "Share Tech Mono", "Orbitron"
PLEX, JBM, SPM, SPG = "IBM Plex Mono", "JetBrains Mono", "Space Mono", "Space Grotesk"

SEEDS = {
 # --- photographs -------------------------------------------------------
 "USSF-51":   S("Range Safety", 1, "#17130f", "#f1e6d8", "#f28c38", "#c9a27a", RAJ, STM, ORB, .5, 1),
 "VIC_8066":  S("Lighthouse Hour", 1, "#1a1719", "#efe3d8", "#e8a27c", "#9aa3b5", "Lora", PLEX, "Playfair Display", 1.4, 1, hue=.2),
 "canaveral1":S("Anvil Cloud", 1, "#1c1a24", "#f0e6da", "#f2b25a", "#8f8fb8", "DM Sans", PLEX, "Josefin Sans", 1, 1),
 "canaveral2":S("Blue Hour Ascent", 1, "#0a1a3a", "#e4ecff", "#ffab3d", "#4c8be6", "Josefin Sans", JBM, "Josefin Sans", 1, 1),
 # --- painted ----------------------------------------------------------
 "antenna":   S("Array Sunset", 1, "#241813", "#f6e3cf", "#f0a24b", "#7fa3c7", SPG, SPM, SPG, 1, 1),
 "black_ocean":S("Red Tether", 1, "#0b1030", "#dfe6ff", "#e23b4a", "#5b7cff", "Outfit", JBM, "Outfit", 2, 0),
 "bridge":    S("Bridge Fog", 1, "#071b1f", "#cfe9e6", "#ff6a4d", "#2fb5aa", RAJ, STM, RAJ, .3, 1),
 "by_on_ramp":S("Sunbelt Cartoon", 0, "#fdf3d0", "#23303a", "#ff7a2f", "#1fa6c4", "Nunito", SPM, "Nunito", 2, 2, sat=1.1),
 "city":      S("Overgrowth", 1, "#17201a", "#e6ecd2", "#b8c95a", "#d9a25a", "Lora", PLEX, "Playfair Display", 1.2, 1),
 "clouds":    S("Cotton Sky", 0, "#f4ecfa", "#3a2f57", "#e0508f", "#7c6bd6", "Quicksand", SPM, "Quicksand", 2, 1, sat=1.1),
 "coast":     S("Ember Arc", 1, "#120f1c", "#f2ddd0", "#ff5b2e", "#4aa3d8", RAJ, STM, ORB, .6, 1),
 "crossing":  S("Harbor Light", 1, "#0c2a30", "#d5f0ee", "#f4c95d", "#4fc1c6", "Nunito", PLEX, "Josefin Sans", 1.6, 1),
 "drone":     S("Steel Sea", 1, "#0f3346", "#e2f4fb", "#f2c14e", "#5bc0e8", "Oxanium", STM, "Oxanium", .2, 2),
 "evening_light":S("Blast Sunset", 1, "#150e0f", "#ffe6cf", "#ff7a2b", "#d94a3a", RAJ, PLEX, ORB, .6, 1),
 "impact":    S("Impact Gold", 1, "#0d1428", "#ffeccc", "#ffb020", "#ff5a2b", "Josefin Sans", SPM, "Playfair Display", .8, 1),
 "lander":    S("Red Planet Dusk", 1, "#14183a", "#e8e6ff", "#ff6a55", "#7f8cff", SPG, JBM, SPG, 1.2, 1),
 "launch":    S("Contrail Dusk", 1, "#121a3a", "#e9e4f8", "#f27fa5", "#6fa6e8", "Nunito", STM, "Nunito", 1.8, 1),
 "launch2":   S("Lone Beacon", 1, "#060d1a", "#c9d6e8", "#ffb85c", "#4d6b93", "Josefin Sans", PLEX, "Josefin Sans", .4, 0, sat=.8),
 "nebula":    S("Nebula Bloom", 1, "#120b1f", "#f2e2f5", "#ff5fa8", "#38d6b8", "Outfit", SPM, "Outfit", 1.6, 1),
 "nebula2":   S("Amber Nebula", 1, "#1c1020", "#ffe9d2", "#ff9d3a", "#8b6ee6", "DM Sans", JBM, "Josefin Sans", 1.4, 1),
 "night":     S("Deep Void", 1, "#07080b", "#c8cbd3", "#8aa4ff", "#6b7280", JBM, JBM, JBM, .3, 1, sat=.7),
 "orbiter":   S("Orbital Deck", 1, "#0d1030", "#dfe3ff", "#7d8bff", "#ff5f7a", RAJ, STM, ORB, .4, 1),
 "plugged_in":S("Nightshift Green", 1, "#0a1a17", "#cbe3d4", "#8fd9b0", "#d6b85a", PLEX, PLEX, PLEX, .5, 1),
 "pluton":    S("Dish Rust", 1, "#18222f", "#e6eef7", "#e08a4c", "#6fb1e8", SPG, SPM, SPG, .8, 1),
 "sailboat_void":S("Moonlit Sail", 1, "#080e1e", "#d2dcf0", "#a9c4ff", "#e3d8b0", "Lora", PLEX, "Cormorant Garamond", 1.6, 1, hue=.2),
 "shuttle":   S("Reentry Glow", 1, "#0a0a1c", "#ffe9e4", "#ff7a5c", "#7f9cff", RAJ, STM, ORB, .6, 1),
 "street":    S("Sodium Violet", 1, "#120c1a", "#e4d6ee", "#c77dff", "#ff8a5c", "Josefin Sans", PLEX, "Josefin Sans", 1, 1),
 "upload":    S("Phone Booth", 1, "#0b2226", "#dcefe9", "#ffc93c", "#38b6a8", "DM Sans", SPM, "DM Sans", 1.2, 1),
 "void":      S("Line Cosmos", 1, "#12142a", "#eef0ff", "#f5f0d0", "#8fa0e8", "Quicksand", SPM, "Quicksand", 2, 1),
 "waterfront_city":S("Golden Skyline", 1, "#1f1c10", "#f7ecc4", "#f0c23b", "#5aa07a", "Lora", PLEX, "Playfair Display", .6, 1),
 "xb70":      S("Aerospace White", 1, "#14153a", "#eef0ff", "#a9b6ff", "#ffffff", SPG, JBM, ORB, .5, 1),
 # --- live scenes ------------------------------------------------------
 "free_return":S("Free Return", 1, "#070b14", "#dfe8f5", "#5cc8ff", "#f0d080", STM, STM, STM, .3, 1),
 "space_shuttle":S("Shuttle Deck", 1, "#080a12", "#e6ecf7", "#ff8a4d", "#58a6ff", RAJ, STM, ORB, .5, 1),
 "spinning_globe":S("Blue Marble", 1, "#06101f", "#dbe9ff", "#4aa3ff", "#5fd39a", "Outfit", JBM, "Outfit", 1.4, 1),
}

# Cat Bouquine: a bookshop cat; parchment, ink, brass, oxblood, moss. A preset
# other themes inherit from (wallpapers/<cat wallpaper>/theme.json:
# {"inherits": "cat_bouquine"}); "_day" is the paper variant.
PRESETS = {
 "cat_bouquine":     S("Cat Bouquine", 1, "#231a15", "#f1e4cb", "#d9a441", "#b5523b", "Lora", "IBM Plex Mono", "Cormorant Garamond", 1.4, 1, hue=.25, sat=.8),
 "cat_bouquine_day": S("Cat Bouquine (paper)", 0, "#f3e8d0", "#2b1d16", "#a8452f", "#3f6b4b", "Lora", "IBM Plex Mono", "Cormorant Garamond", 1.4, 1, hue=.25, sat=.75),
 "default":          S("Catppuccin Mocha", 1, "#1e1e2e", "#cdd6f4", "#89b4fa", "#b4befe", "Noto Sans", "monospace", "Noto Sans", 1, 1, hue=0, sat=1),
}

MOCHA = {"red": "#f38ba8", "orange": "#fab387", "yellow": "#f9e2af", "green": "#a6e3a1", "teal": "#94e2d5", "cyan": "#89dceb", "blue": "#89b4fa", "indigo": "#74c7ec", "violet": "#cba6f7", "lavender": "#b4befe", "pink": "#f5c2e7", "background": "#1e1e2e", "panel": "#181825", "panelDeep": "#11111b", "inset": "#313244", "border": "#45475a", "textPrimary": "#cdd6f4", "textSecondary": "#a6adc8", "textMuted": "#6c7086", "accent": "#89b4fa", "error": "#f38ba8", "success": "#a6e3a1", "warning": "#f9e2af", "onAccent": "#1e1e2e"}

def main():
    want = sys.argv[1:]
    presets = WALLPAPERS / "_presets"; presets.mkdir(exist_ok=True)
    for k, s in PRESETS.items():
        if want and k not in want: continue
        (presets / f"{k}.json").write_text(json.dumps(theme(k, s), indent=2) + "\n")
    for stem, s in SEEDS.items():
        if want and stem not in want: continue
        d = WALLPAPERS / stem; d.mkdir(exist_ok=True)
        (d / "theme.json").write_text(json.dumps(theme(stem, s), indent=2) + "\n")
        print("wrote", d / "theme.json")

if __name__ == "__main__":
    main()
