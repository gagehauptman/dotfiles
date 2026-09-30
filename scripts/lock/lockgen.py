#!/usr/bin/env python3
"""Resolve the lock screen's settings for the current wallpaper, as JSON for
the Quickshell lock (qs/shell.qml).

Placement and text style come from meta/<stem>.toml (see README.md), layered
over meta/default.toml, so every wallpaper can be tuned on its own. The
background is per monitor: the live Bevy scene of a live wallpaper (rendered
in-process by the lock itself), a still cover-cropped to the monitor, or a flat
colour.

  lockgen.py [--wallpaper PATH] [--out FILE] [--monitors NAME:WxH,...] [--check]

--wallpaper  use this instead of the saved selection (wpsave.txt)
--out        write the JSON here instead of stdout
--monitors   pretend these monitors are connected (e.g. no compositor running)
--check      also print a one-line summary per monitor to stderr
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
import tomllib
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent            # dotfiles/scripts/lock
DOTFILES = HERE.parent.parent
HOME = Path.home()
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME", HOME / ".config"))
RUNTIME = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
STATE = RUNTIME / "lockscreen"
META = HERE / "meta"
WALLPAPERS = CONFIG / "wallpapers"
SAVE_FILE = CONFIG / "scripts/wallpaper/wpsave.txt"
# wallpaper_select.sh --warm keeps screen-sized copies of every still here.
SCALED = RUNTIME / "wallpaper_select/scaled"

ELEMENTS = ("clock", "date", "greeting", "input")
TEXT_ELEMENTS = ("clock", "date", "greeting")
COLOR_KEYS = {"color", "font_color", "outer_color", "inner_color", "check_color", "fail_color",
              "capslock_color", "shadow_color", "accent_color", "success_color", "caps_color"}
STILL_EXTS = {".png", ".jpg", ".jpeg", ".webp", ".bmp", ".jxl"}


def log(*a):
    print("lockgen:", *a, file=sys.stderr)


def merge(base, over):
    out = dict(base)
    for k, v in over.items():
        out[k] = merge(out[k], v) if isinstance(v, dict) and isinstance(out.get(k), dict) else v
    return out


def load_toml(path):
    try:
        with open(path, "rb") as f:
            return tomllib.load(f)
    except FileNotFoundError:
        return {}
    except tomllib.TOMLDecodeError as e:
        log(f"{path}: {e}; ignoring it")
        return {}


# ---------------------------------------------------------------- inputs

def current_wallpaper():
    try:
        p = SAVE_FILE.read_text().strip()
    except OSError:
        p = ""
    return Path(p) if p else None


REFRESH = {}      # monitor name -> Hz, filled by monitors()


def monitors(spec=None):
    """[(name, width, height)] in physical pixels, as the monitor is oriented."""
    if spec:
        out = []
        for item in spec.split(","):
            name, size = item.split(":")
            w, h = size.lower().split("x")
            out.append((name, int(w), int(h)))
            REFRESH[name] = 60.0
        return out
    try:
        mons = json.loads(subprocess.run(["hyprctl", "-j", "monitors"], capture_output=True,
                                         text=True, timeout=3).stdout)
        out = []
        for m in mons:
            if m.get("disabled"):
                continue
            w, h = m["width"], m["height"]
            if m.get("transform", 0) % 2:
                w, h = h, w
            out.append((m["name"], w, h))
            REFRESH[m["name"]] = float(m.get("refreshRate") or 60)
        if out:
            return out
    except Exception as e:
        log(f"hyprctl monitors failed ({e}); one generic output")
    return [("", 1920, 1080)]


def meta_for(stem, monitor):
    """Resolved settings for one monitor: default < layouts/<base> < <stem>,
    then each of those files' [monitor."<name>"] overrides in the same order."""
    own = {}
    if stem:
        folder = WALLPAPERS / stem / "lock.toml"      # the wallpaper's own folder wins
        own = load_toml(folder if folder.is_file() else META / f"{stem}.toml")
    layers = [load_toml(META / "default.toml")]
    if own.get("base"):
        layers.append(load_toml(META / "layouts" / f"{own['base']}.toml"))
    layers.append(own)
    m = {}
    for layer in layers:
        m = merge(m, layer)
    for layer in layers:
        m = merge(m, layer.get("monitor", {}).get(monitor, {}))
    m.pop("monitor", None)
    m.pop("base", None)
    return m


# ---------------------------------------------------------------- backgrounds

def scaled_cache_path(src, w, h):
    """The copy wallpaper_select.sh --warm makes (same key as its scaled_path)."""
    real = os.path.realpath(src)
    st = os.stat(real)
    key = hashlib.md5(f"{real}|{st.st_size}-{int(st.st_mtime)}".encode()).hexdigest()
    return SCALED / f"{w}x{h}" / f"{key}.png"


def still_background(src, w, h):
    """A WxH cover-cropped copy of a still (cached), else the original."""
    try:
        cached = scaled_cache_path(src, w, h)
    except OSError:
        return None
    if cached.is_file() and cached.stat().st_size:
        return cached
    own = STATE / "bg" / f"{w}x{h}" / cached.name
    if own.is_file() and own.stat().st_size:
        return own
    own.parent.mkdir(parents=True, exist_ok=True)
    tmp = own.with_suffix(f".tmp{os.getpid()}.png")
    try:
        subprocess.run(["vips", "thumbnail", str(src),
                        f"{tmp}[compression=1,strip]", str(w), "--height", str(h),
                        "--crop", "centre", "--size", "both"],
                       check=True, capture_output=True, timeout=15)
        tmp.replace(own)
        return own
    except Exception as e:
        log(f"scaling {src} failed ({e})")
        tmp.unlink(missing_ok=True)
    return src if src.suffix.lower() in STILL_EXTS else None


def bevy_app(stem):
    """The Bevy app that draws a live wallpaper's scene (the selector's preview app)."""
    for lib in (CONFIG / f"quickshell/modules/Bevy/apps/{stem}/lib{stem}.so",
                DOTFILES / f"bevy/target/release/lib{stem}.so"):
        if lib.is_file():
            return lib
    return None


def background(wall, mon, meta):
    """{"kind": "live"|"still"|"color", ...} for one monitor."""
    name, w, h = mon
    bgm = meta.get("background", {})
    out = {"kind": "color"}
    poster = bgm.get("image")
    if poster:
        p = Path(os.path.expanduser(poster))
        p = p if p.is_absolute() else WALLPAPERS / (wall.stem if wall else "") / p
        if p.is_file():
            img = still_background(p, w, h)
            if img:
                return {"kind": "still", "image": str(img)}
        else:
            log(f"background.image {p} not found")
    if not wall:
        return out
    if wall.suffix == ".live":
        lib = bevy_app(wall.stem)
        if lib and bgm.get("live", True):
            # The scene's own default cap is 30 fps (fine for the wallpaper). The lock
            # runs it at the monitor's refresh rate (live_fps = N overrides). The app
            # cap is set above the rate so it never skips a vblank; the swap chain
            # paces the frames.
            fps = float(bgm.get("live_fps", 0)) or REFRESH.get(name, 60.0)
            return {"kind": "live", "library": str(lib),
                    "options": {"output": [w, h], "fps": round(fps * 2, 1)}}
        if not lib:
            log(f"no Bevy app for live wallpaper {wall.stem}; using a still or flat colour")
        # A still of the scene next to its descriptor, if one was made.
        for ext in STILL_EXTS:
            p = wall.with_suffix(ext)
            if p.is_file():
                img = still_background(p, w, h)
                if img:
                    return {"kind": "still", "image": str(img)}
        return out
    if wall.is_file():
        img = still_background(wall, w, h)
        if img:
            return {"kind": "still", "image": str(img)}
    else:
        log(f"{wall} not found")
    return out


# ---------------------------------------------------------------- output

def qcolor(c):
    """rgb(1b1923) / rgba(1b192380) / 0xAARRGGBB / #rrggbb -> Qt's #AARRGGBB."""
    s = str(c).strip()
    if s.startswith("rgba(") and s.endswith(")") and "," not in s:
        hx = s[5:-1]
        return f"#{hx[6:8] or 'ff'}{hx[:6]}" if len(hx) >= 6 else s
    if s.startswith("rgb(") and s.endswith(")") and "," not in s:
        return f"#ff{s[4:-1]}"
    if s.startswith("0x") and len(s) == 10:      # hyprlang 0xAARRGGBB
        return "#" + s[2:]
    return s


def parse_pos(v):
    """"x%, y%" or [x, y] -> [[value, is_percent], ...] (+y up)."""
    if isinstance(v, list):
        v = ", ".join(map(str, v))
    out = []
    for p in str(v).split(",")[:2]:
        p = p.strip()
        out.append([float(p[:-1] or 0), True] if p.endswith("%") else [float(p or 0), False])
    while len(out) < 2:
        out.append([0.0, False])
    return out


def element(meta, key):
    """[text] is the shared style; labels and the input field inherit from it
    (`accent` becomes the field's accent_color). Each element's own table wins:
    font_family, font_weight, font_size, letter_spacing, uppercase, color, opacity,
    shadow_size/shadow_color/shadow_strength."""
    text = meta.get("text", {})
    opts = {}
    if key in TEXT_ELEMENTS:
        opts.update({k: v for k, v in text.items() if k != "accent"})
    elif key == "input":
        for src, dst in (("color", "font_color"), ("font_family", "font_family"),
                         ("font_weight", "font_weight"), ("font_style", "font_style"),
                         ("accent", "accent_color")):
            if src in text:
                opts[dst] = text[src]
        for k in ("shadow_passes", "shadow_size", "shadow_color"):
            if k in text:
                opts[k] = text[k]
    opts.update(meta.get(key, {}))
    for k in COLOR_KEYS & opts.keys():
        opts[k] = qcolor(opts[k])
    if "position" in opts:
        opts["position"] = parse_pos(opts["position"])
    return opts


def build(wall, mons):
    stem = wall.stem if wall else ""
    metas = {name: meta_for(stem, name) for name, _, _ in mons}

    def one(mon):
        name, w, h = mon
        meta = metas[name]
        bg = background(wall, mon, meta)
        bgm = meta.get("background", {})
        bg["color"] = qcolor(bgm.get("color", "rgb(1b1923)"))
        # brightness/blur dim and soften stills; a live scene is shown as is
        # unless live_brightness is set.
        bg["brightness"] = float(bgm.get("live_brightness", 1.0) if bg["kind"] == "live"
                                 else bgm.get("brightness", 1.0))
        bg["blur"] = int(bgm.get("blur_passes", 0)) * int(bgm.get("blur_size", 6)) if bg["kind"] == "still" else 0
        return {"name": name, "width": w, "height": h, "background": bg,
                "elements": {k: element(meta, k) for k in ELEMENTS}}

    with ThreadPoolExecutor(max_workers=len(mons)) as ex:
        screens = list(ex.map(one, mons))
    return {"wallpaper": str(wall) if wall else "", "stem": stem, "screens": screens}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--wallpaper")
    ap.add_argument("--out")
    ap.add_argument("--monitors")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    wall = Path(a.wallpaper).expanduser() if a.wallpaper else current_wallpaper()
    cfg = build(wall, monitors(a.monitors))
    text = json.dumps(cfg, indent=1)
    if a.out:
        out = Path(a.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        tmp = out.with_suffix(f".tmp{os.getpid()}")
        tmp.write_text(text + "\n")
        tmp.replace(out)
    else:
        print(text)
    if a.check:
        for s in cfg["screens"]:
            b = s["background"]
            log(f"{s['name'] or 'all'} {s['width']}x{s['height']}: {b['kind']} "
                f"{b.get('library') or b.get('image') or b['color']}")


if __name__ == "__main__":
    main()
