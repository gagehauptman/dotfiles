# Dashboard apps

One directory per app, each a `cdylib` crate built by `../build.sh` and
installed as `~/.config/quickshell/modules/Bevy/apps/<name>/lib<name>.so`
(plus the app's `assets/` directory, if it has one). A card points at it with
`{ "type": "bevy", "options": { "app": "<name>" } }` in a preset, or the app
gets a widget type of its own in `DashboardConfig.qml` (`globe` does, with
`props: { app: "globe" }` and its service).

- `planet`: the demo, a low-poly planet with moons.
- `globe`: weather, light pollution and live aircraft on a cube-sphere with
  Natural Earth coastlines, borders, names and cities by zoom level, fed by
  `scripts/globeserver.py`. Its labels are quads on the sphere from a glyph
  atlas (`text.rs`), so they follow the surface; markers are filled shapes
  with a dark rim (`sphere::Shapes`, `glyph`, `billboard`) sized in pixels
  and scaled by zoom, so an airliner or an airport stays readable at any
  distance; a click on an aircraft shows its flight and draws its path. Satellites come from CelesTrak
  elements propagated with SGP4 (`sats.rs`); the camera rigs it uses for
  Home and Follow are the harness's `rig` module.

Minimal app (`apps/<name>/src/lib.rs`):

```rust
use bevy::prelude::*;
use quickshell_bevy::prelude::*;

pub struct Scene;
impl Plugin for Scene {
    fn build(&self, app: &mut App) { app.add_systems(Startup, setup); }
}
quickshell_bevy::widget!(Scene);

fn setup(mut commands: Commands) {
    // Tag your camera; the harness aims it at the card (or spawns a default one)
    commands.spawn((Camera3d::default(), WidgetCamera, Transform::from_xyz(0.0, 2.0, 6.0).looking_at(Vec3::ZERO, Vec3::Y)));
}
```

`Cargo.toml` mirrors `planet/Cargo.toml` (`bevy` and `quickshell-bevy` from the
workspace). Read `WidgetInput` for the pointer (0..1 over the card, `down`,
wheel `scroll` steps; a press and release inside one frame still arrive as a
press, then a release) and the card size, and `WidgetOptions` for the card's
preset options as JSON (with the shell's `theme` colours added). Declare
toggles, buttons and readouts in `WidgetUi` (`ui.toggle(id, label, on)`,
`ui.button(id, label)`, `ui.info(id, label, value)`); the card draws them and
presses come back as `WidgetEvent { id, value }` (`e.on()` for a toggle). A
transparent clear colour shows the card behind the scene. Rebuilt apps need a
Quickshell restart to load. `../target/release/bevy-snapshot <lib.so> out.png`
renders an app headlessly to check it without the shell (`--send id=value`
presses a control).
