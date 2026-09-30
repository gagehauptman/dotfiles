"""Firefox theming for scripts/theme/apply.py.

Writes <profile>/chrome/wallpaper-theme.css (UI) and wallpaper-theme-content.css (about: pages)
from templates/firefox-*.css filled with the wallpaper's palette, plus any
wallpapers/<stem>/firefox.css / firefox-content.css appended. userChrome.css and userContent.css
only @import those files (an existing user file is backed up once, then the import is prepended).
Enables toolkit.legacyUserProfileCustomizations.stylesheets via user.js when no prefs file sets it.
The generated CSS is empty on purpose: Firefox reads chrome CSS once per window, so any colour set
there would go stale and override the live theme. Live colours come from firefox-live/ (a
WebExtension calling browser.theme.update(), fed by a native-messaging host that watches
~/.cache/wallpaper_theme/current.json). update() registers that host's manifest; loading the
extension itself is a one-time step per Firefox run (release Firefox refuses unsigned add-ons
permanently), see firefox-live/README.md.
Silently does nothing when Firefox or its profile is missing.
"""
import configparser, json, shutil
from pathlib import Path
from string import Template

HERE = Path(__file__).resolve().parent
PREF = "toolkit.legacyUserProfileCustomizations.stylesheets"
ROOTS = (Path.home() / ".config/mozilla/firefox", Path.home() / ".mozilla/firefox")
FILES = (("userChrome.css", "wallpaper-theme.css", "firefox-chrome.css", "firefox.css"),
         ("userContent.css", "wallpaper-theme-content.css", "firefox-content.css", "firefox-content.css"))


def profile_dir():
    """Default profile: the install-locked one, else the Default=1 profile, else the only one."""
    for root in ROOTS:
        ini = root / "profiles.ini"
        if not ini.is_file():
            continue
        cp = configparser.ConfigParser(interpolation=None)
        cp.read(ini)
        paths = []
        for s in cp.sections():
            if s.startswith("Install") and cp.has_option(s, "Default"):
                paths.append(cp.get(s, "Default"))
        for s in cp.sections():
            if s.startswith("Profile") and cp.get(s, "Default", fallback="0") == "1":
                paths.append(cp.get(s, "Path", fallback=""))
        for s in cp.sections():
            if s.startswith("Profile"):
                paths.append(cp.get(s, "Path", fallback=""))
        for rel in paths:
            d = Path(rel) if rel.startswith("/") else root / rel
            if (d / "prefs.js").is_file():
                return d
    return None


def write_if_changed(path, text):
    try:
        if path.read_text() == text:
            return False
    except OSError:
        pass
    path.write_text(text)
    return True


def backup_once(path):
    bak = path.with_name(path.name + ".bak-wallpaper-theme")
    if path.exists() and not bak.exists():
        shutil.copy2(path, bak)


def ensure_pref(prof):
    """Add the stylesheets pref to user.js unless a prefs file already sets it. True if added."""
    for name in ("user.js", "prefs.js"):
        try:
            if PREF in (prof / name).read_text():
                return False
        except OSError:
            pass
    uj = prof / "user.js"
    backup_once(uj)
    old = uj.read_text() if uj.exists() else ""
    if old and not old.endswith("\n"):
        old += "\n"
    uj.write_text(old + f'// added by dotfiles scripts/theme/firefox.py\nuser_pref("{PREF}", true);\n')
    return True


def ensure_import(path, target):
    line = f'@import url("{target}");'
    try:
        old = path.read_text()
    except OSError:
        old = ""
    if line in old:
        return
    backup_once(path)
    path.write_text(f"/* wallpaper theme: scripts/theme/firefox.py */\n{line}\n" + (("\n" + old) if old else ""))


def ensure_native_host():
    """Register firefox-live/host.py as native messaging host "wallpaper_theme" (both lookup dirs)."""
    host = HERE / "firefox-live/host.py"
    text = json.dumps({"name": "wallpaper_theme", "description": "Wallpaper theme feed for Firefox",
                       "path": str(host), "type": "stdio",
                       "allowed_extensions": ["wallpaper-theme@dotfiles"]}, indent=1) + "\n"
    for root in (Path.home() / ".mozilla", Path.home() / ".config/mozilla"):
        d = root / "native-messaging-hosts"
        d.mkdir(parents=True, exist_ok=True)
        write_if_changed(d / "wallpaper_theme.json", text)


def update(t, wallpaper_dir):
    """Returns a short status string, or None when Firefox is not set up."""
    prof = profile_dir()
    if not prof:
        return None
    p = t["palette"]
    vals = {k: v for k, v in p.items()}
    vals.setdefault("onAccent", p["background"])
    vals["name"] = t.get("name") or t.get("stem", "")
    vals["mode"] = "dark" if t.get("dark", True) else "light"
    chrome = prof / "chrome"
    chrome.mkdir(exist_ok=True)
    changed = False
    for user_file, gen, tmpl, override in FILES:
        css = Template((HERE / "templates" / tmpl).read_text()).safe_substitute(vals)
        try:
            extra = (Path(wallpaper_dir) / override).read_text()
            css += f"\n/* {t.get('stem')}/{override} */\n{extra.rstrip()}\n"
        except OSError:
            pass
        changed |= write_if_changed(chrome / gen, css)
        ensure_import(chrome / user_file, gen)
    ensure_native_host()
    added = ensure_pref(prof)
    return ("pref enabled (restart Firefox once); " if added else "") + ("css updated" if changed else "css unchanged")
