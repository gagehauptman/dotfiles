"""Zed theme from the wallpaper theme (called by apply.py).

Writes one generated theme family, "Wallpaper Current", to ~/.config/zed/themes/wallpaper-current.json
(used on Zed start), points settings.json `theme` at it, and mirrors the same style into settings.json
`experimental.theme_overrides`. The mirror is what makes a *running* Zed re-theme: Zed's settings
watcher is reliable, its themes-dir watcher is not (a dir created after Zed started, or a rewritten
same-named theme, is never re-applied), so the live path must be a settings.json change.
settings.json is edited textually (comments/other keys/format preserved) and replaced atomically. Optional per-wallpaper
override: wallpapers/<stem>/zed.json, {"appearance"?, "style": {...}, "syntax": {...}}; its
style/syntax keys are merged over the generated ones (a "players" list replaces them).
Skips quietly when Zed's config dir does not exist.
"""
import json, os, shutil, tempfile
from pathlib import Path

NAME = "Wallpaper Current"
SCHEMA = "https://zed.dev/schema/themes/v0.2.0.json"


def _a(c, alpha):
    return c[:7] + "%02x" % round(alpha * 255)


def _mix(a, b, f):
    """a blended toward b by f (0..1); opaque #rrggbb."""
    x, y = (tuple(int(c[i:i + 2], 16) for i in (1, 3, 5)) for c in (a, b))
    return "#%02x%02x%02x" % tuple(round(p + (q - p) * f) for p, q in zip(x, y))


def build(t, override):
    p = t["palette"]
    dark = bool(t.get("dark", True))
    bg, panel, deep, inset, border = p["background"], p["panel"], p["panelDeep"], p["inset"], p["border"]
    fg, fg2, muted, acc = p["textPrimary"], p["textSecondary"], p["textMuted"], p["accent"]
    onacc = p.get("onAccent", bg)
    ghost = "#00000000"
    hover, active = _a(acc, .12), _a(acc, .22)
    ansi = {"black": deep if dark else inset, "red": p["red"], "green": p["green"], "yellow": p["yellow"],
            "blue": p["blue"], "magenta": p["violet"], "cyan": p["cyan"], "white": fg2}
    term = {"terminal.background": bg, "terminal.foreground": fg, "terminal.bright_foreground": fg,
            "terminal.dim_foreground": muted}
    for k, v in ansi.items():
        term[f"terminal.ansi.{k}"] = v
        term[f"terminal.ansi.bright_{k}"] = v
        term[f"terminal.ansi.dim_{k}"] = _mix(v, bg, .35)
    st = {
        "border": border, "border.variant": _mix(border, bg, .5), "border.focused": acc,
        "border.selected": acc, "border.transparent": ghost, "border.disabled": _mix(border, bg, .5),
        "elevated_surface.background": panel, "surface.background": panel, "background": deep,
        "element.background": inset, "element.hover": _mix(inset, acc, .15), "element.active": _mix(inset, acc, .3),
        "element.selected": _mix(inset, acc, .3), "element.disabled": panel,
        "drop_target.background": _a(acc, .25),
        "ghost_element.background": ghost, "ghost_element.hover": hover, "ghost_element.active": active,
        "ghost_element.selected": active, "ghost_element.disabled": ghost,
        "text": fg, "text.muted": fg2, "text.placeholder": muted, "text.disabled": muted, "text.accent": acc,
        "icon": fg, "icon.muted": fg2, "icon.disabled": muted, "icon.placeholder": fg2, "icon.accent": acc,
        "status_bar.background": deep, "title_bar.background": deep, "title_bar.inactive_background": panel,
        "toolbar.background": bg, "tab_bar.background": panel, "tab.inactive_background": panel,
        "tab.active_background": bg, "search.match_background": _a(p["yellow"], .3),
        "panel.background": panel, "panel.focused_border": acc,
        "scrollbar.thumb.background": _a(fg2, .25), "scrollbar.thumb.hover_background": _a(fg2, .4),
        "scrollbar.thumb.border": ghost, "scrollbar.track.background": ghost, "scrollbar.track.border": ghost,
        "editor.foreground": fg, "editor.background": bg, "editor.gutter.background": bg,
        "editor.subheader.background": panel, "editor.active_line.background": _a(fg2, .1),
        "editor.highlighted_line.background": _a(fg2, .1), "editor.line_number": muted,
        "editor.active_line_number": fg, "editor.invisible": muted, "editor.wrap_guide": _a(border, .5),
        "editor.active_wrap_guide": border,
        "editor.document_highlight.read_background": _a(acc, .15),
        "editor.document_highlight.write_background": _a(acc, .25),
        "link_text.hover": acc,
        "conflict": p["orange"], "created": p["success"], "deleted": p["error"], "hidden": muted,
        "hint": p["teal"], "ignored": muted, "modified": p["warning"], "predictive": muted,
        "renamed": p["blue"], "unreachable": muted,
        "error": p["error"], "success": p["success"], "warning": p["warning"], "info": p["blue"],
        **term,
        "players": [{"cursor": c, "background": c, "selection": _a(c, .25)}
                    for c in (acc, p["pink"], p["orange"], p["violet"], p["green"], p["cyan"], p["red"], p["yellow"])],
    }
    for k in ("error", "success", "warning", "info", "conflict", "created", "deleted", "modified", "renamed", "hint"):
        st[f"{k}.background"] = _a(st[k], .15)
        st[f"{k}.border"] = _mix(st[k], bg, .5)
    it = {"font_style": "italic"}
    syn = {
        "attribute": {"color": p["yellow"]}, "boolean": {"color": p["orange"]},
        "comment": {"color": muted, **it}, "comment.doc": {"color": muted, **it},
        "constant": {"color": p["orange"]}, "constructor": {"color": p["indigo"]},
        "embedded": {"color": fg}, "emphasis": {"color": acc, **it},
        "emphasis.strong": {"color": acc, "font_weight": 700},
        "enum": {"color": p["teal"]}, "function": {"color": p["blue"]},
        "hint": {"color": p["teal"]}, "keyword": {"color": p["violet"]}, "label": {"color": p["indigo"]},
        "link_text": {"color": p["blue"], **it}, "link_uri": {"color": p["teal"]},
        "number": {"color": p["orange"]}, "operator": {"color": p["cyan"]},
        "predictive": {"color": muted, **it}, "preproc": {"color": p["pink"]},
        "primary": {"color": fg}, "property": {"color": p["blue"]},
        "punctuation": {"color": fg2}, "punctuation.bracket": {"color": fg2},
        "punctuation.delimiter": {"color": fg2}, "punctuation.list_marker": {"color": p["cyan"]},
        "punctuation.special": {"color": p["pink"]}, "string": {"color": p["green"]},
        "string.escape": {"color": p["pink"]}, "string.regex": {"color": p["orange"]},
        "string.special": {"color": p["pink"]}, "string.special.symbol": {"color": p["red"]},
        "tag": {"color": p["blue"]}, "text.literal": {"color": p["green"]},
        "title": {"color": p["red"], "font_weight": 700}, "type": {"color": p["yellow"]},
        "variable": {"color": fg}, "variable.special": {"color": p["red"]},
        "variant": {"color": p["lavender"]},
    }
    appearance = override.get("appearance") or ("dark" if dark else "light")
    ost = override.get("style") or {}
    st.update(ost)
    syn.update(override.get("syntax") or {})
    st["syntax"] = syn
    return {"$schema": SCHEMA, "name": NAME, "author": "scripts/theme/zed.py (generated: do not edit)",
            "themes": [{"name": NAME, "appearance": appearance, "style": st}]}


def _skip(text, k):
    """Index after whitespace/comments starting at k."""
    n = len(text)
    while k < n:
        if text[k] in " \t\r\n":
            k += 1
        elif text.startswith("//", k):
            k = text.find("\n", k)
            k = n if k < 0 else k
        elif text.startswith("/*", k):
            k = text.find("*/", k)
            k = n if k < 0 else k + 2
        else:
            break
    return k


def _str_end(text, k):
    """text[k] is an opening quote; index just past the closing one."""
    k += 1
    while text[k] != '"':
        k += 2 if text[k] == "\\" else 1
    return k + 1


def _value_end(text, j):
    """Index just past the JSON value starting at text[j] (string, scalar or balanced {} / [])."""
    if text[j] == '"':
        return _str_end(text, j)
    if text[j] not in "{[":
        while text[j] not in ",}]\n":
            j += 1
        return j
    depth = 0
    while True:
        c = text[j]
        if c == '"':
            j = _str_end(text, j)
            continue
        if text.startswith("//", j) or text.startswith("/*", j):
            j = _skip(text, j)
            continue
        if c in "{[":
            depth += 1
        elif c in "}]":
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1


def _find_key(text, key):
    """(start, end) of the value of top-level `key` in JSONC `text`, or None."""
    k = _skip(text, 0)
    if k >= len(text) or text[k] != "{":
        return None
    k += 1
    while True:
        k = _skip(text, k)
        if k >= len(text) or text[k] == "}":
            return None
        if text[k] == ",":
            k += 1
            continue
        if text[k] != '"':
            return None
        e = _str_end(text, k)
        name = text[k + 1:e - 1]
        k = _skip(text, e)
        if text[k] != ":":
            return None
        j = _skip(text, k + 1)
        end = _value_end(text, j)
        if name == key:
            return j, end
        k = end


def _set_key(text, key, value):
    """text with top-level `key` set to `value` (indented to sit at 2 spaces); None if unchanged."""
    enc = json.dumps(value, indent=2).replace("\n", "\n  ")
    span = _find_key(text, key)
    if span:
        if text[span[0]:span[1]] == enc:
            return None
        return text[:span[0]] + enc + text[span[1]:]
    i = text.index("{") + 1
    return text[:i] + f'\n  "{key}": {enc},' + text[i:]


def _atomic_write(path, text):
    """Write via temp file + rename in the same dir (keeps mode; follows a symlinked file)."""
    path = Path(path).resolve()
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        shutil.copymode(path, tmp)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def apply(t, stem, wp_dir, write_if_changed):
    zed = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "zed"
    if not zed.is_dir():
        return
    try:
        override = json.loads((Path(wp_dir) / stem / "zed.json").read_text())
    except (OSError, ValueError):
        override = {}
    theme = build(t, override)
    write_if_changed(zed / "themes" / "wallpaper-current.json", json.dumps(theme, indent=1) + "\n")
    sf = zed / "settings.json"
    try:
        text = sf.read_text()
    except OSError:
        return
    new = text
    for key, value in (("theme", NAME), ("experimental.theme_overrides", theme["themes"][0]["style"])):
        upd = _set_key(new, key, value)
        if upd is None:
            continue
        backup = sf.with_name("settings.json.pre-wallpaper-theme")
        if not backup.exists():
            shutil.copy2(sf, backup)
        new = upd
    if new != text:
        _atomic_write(sf, new)
