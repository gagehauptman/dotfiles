// Connects to the native host (host.py), which watches the wallpaper theme and pushes a
// theme.update() payload on connect and on every change. Reconnects if the host exits.
function connect() {
  const port = browser.runtime.connectNative("wallpaper_theme");
  port.onMessage.addListener((theme) => browser.theme.update(theme));
  port.onDisconnect.addListener(() => setTimeout(connect, 2000));
}
connect();
