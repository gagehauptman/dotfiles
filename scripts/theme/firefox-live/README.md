# Live Firefox theme

`apply.py` writes `~/.cache/wallpaper_theme/current.json`. `host.py` (native-messaging host, stdin/stdout
only, no sockets) watches it and pushes a `browser.theme.update()` payload to `extension/`, so a running
Firefox re-themes within ~0.3 s: no restart, no new window. `firefox.py` registers the host manifest
(`~/.mozilla/` and `~/.config/mozilla/native-messaging-hosts/wallpaper_theme.json`).

Release Firefox (`MOZ_REQUIRE_SIGNING`) refuses unsigned add-ons, so the extension is a temporary
add-on: load it once per Firefox run, `./load-addon.sh` (Hyprland; drives about:debugging with
keystrokes) or by hand: about:debugging#/runtime/this-firefox -> Load Temporary Add-on ->
`extension/manifest.json`. A persistent alternative needs root (Firefox autoconfig in /usr/lib/firefox).

Limits: the generated userChrome/userContent CSS is empty on purpose (a variable set there stays at its
startup value and beats the live theme; a window started before that change keeps its old values until
Firefox restarts once). The tab-strip background did not follow `frame` on this machine even with the
installed static theme alone.
