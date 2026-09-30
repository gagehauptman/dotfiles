#!/usr/bin/env python3
"""Native-messaging host for the live Firefox theme (extension/ in this folder).

Firefox starts it when the extension calls connectNative("wallpaper_theme"). It sends the
theme.update() payload for $XDG_CACHE_HOME/wallpaper_theme/current.json (written by apply.py)
right away and again whenever that file changes. Talks over stdin/stdout only: no sockets.
"""
import json, os, struct, sys, time
from pathlib import Path

CUR = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "wallpaper_theme/current.json"


def theme(t):
    p = t["palette"]
    on = p.get("onAccent", p["background"])
    dark = t.get("dark", True)
    colors = {
        "frame": p["panelDeep"], "frame_inactive": p["panelDeep"],
        "tab_background_text": p["textSecondary"], "tab_selected": p["background"],
        "tab_text": p["textPrimary"], "tab_line": p["accent"], "tab_loading": p["accent"],
        "toolbar": p["background"], "toolbar_text": p["textPrimary"],
        "toolbar_top_separator": p["border"], "toolbar_bottom_separator": p["border"],
        "toolbar_vertical_separator": p["border"],
        "toolbar_field": p["panel"], "toolbar_field_text": p["textPrimary"],
        "toolbar_field_border": p["border"], "toolbar_field_focus": p["panel"],
        "toolbar_field_text_focus": p["textPrimary"], "toolbar_field_border_focus": p["accent"],
        "toolbar_field_highlight": p["accent"], "toolbar_field_highlight_text": on,
        "icons": p["textPrimary"], "icons_attention": p["accent"],
        "button_background_hover": p["inset"], "button_background_active": p["border"],
        "popup": p["panel"], "popup_text": p["textPrimary"], "popup_border": p["border"],
        "popup_highlight": p["accent"], "popup_highlight_text": on,
        "sidebar": p["panelDeep"], "sidebar_text": p["textPrimary"], "sidebar_border": p["border"],
        "sidebar_highlight": p["accent"], "sidebar_highlight_text": on,
        "ntp_background": p["background"], "ntp_text": p["textPrimary"], "ntp_card_background": p["panel"],
        "tab_background_separator": p["border"], "toolbar_field_separator": p["border"], "bookmark_text": p["textPrimary"],
    }
    return {"colors": colors, "properties": {"color_scheme": "dark" if dark else "light", "content_color_scheme": "dark" if dark else "light"}}


def send(obj):
    data = json.dumps(obj).encode()
    sys.stdout.buffer.write(struct.pack("=I", len(data)) + data)
    sys.stdout.buffer.flush()


def main():
    last = None
    while True:
        try:
            st = CUR.stat()
            key = (st.st_mtime_ns, st.st_size)
            if key != last:
                send(theme(json.loads(CUR.read_text())))
                last = key
        except (OSError, ValueError, KeyError):
            pass
        time.sleep(0.25)


if __name__ == "__main__":
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt):
        pass
