// The live scene behind the lock. Its own file (loaded indirectly by
// LockSurface) because the `Bevy` QML module only exists where bevy/build.sh
// ran: without it the lock still works, on the flat colour.
import QtQuick
import Bevy

BevyView {
  // over the poster: fades in once the scene has drawn
  opacity: frameReady ? 1 : 0
  Behavior on opacity { NumberAnimation { duration: 160 } }
  onErrorChanged: if (error !== "") console.warn("lock: bevy scene: " + error)
}
