# Live Firefox theme

`apply.py` writes `~/.cache/wallpaper_theme/current.json`. `host.py` (native-messaging host, stdin/stdout
only, no sockets) watches it and pushes a `browser.theme.update()` payload to `extension/`, so a running
Firefox re-themes within ~0.3 s: no restart, no new window. `firefox.py` registers the host manifest
(`~/.mozilla/` and `~/.config/mozilla/native-messaging-hosts/wallpaper_theme.json`).

Release Firefox (`MOZ_REQUIRE_SIGNING`) refuses unsigned add-ons, so the extension is a temporary
add-on, and temporary add-ons are gone after every Firefox restart (or update). `autoconfig/` loads it
again on each start: run `./install-autoconfig.sh` once per machine (sudo; copies `autoconfig.js` to
`<install dir>/defaults/pref/` and `firefox.cfg` to the install dir, `/usr/lib/firefox` on Arch; the
firefox package does not own them, so upgrades keep them). `firefox.cfg` loads
`<profile>/chrome/wallpaper-theme-extension`, a symlink `firefox.py` makes to `extension/` in the default
profile, so no profile path is hardcoded and other profiles are left alone.

Without the autoconfig: `./load-addon.sh` (Hyprland; drives about:debugging with keystrokes) or by hand:
about:debugging#/runtime/this-firefox -> Load Temporary Add-on -> `extension/manifest.json`, once per
Firefox run.

Check: with Firefox running, `pgrep -af firefox-live/host.py` shows the host (the extension started it).

Limits: the generated userChrome/userContent CSS is empty on purpose (a variable set there stays at its
startup value and beats the live theme; a window started before that change keeps its old values until
Firefox restarts once). The tab-strip background did not follow `frame` on this machine even with the
installed static theme alone.
