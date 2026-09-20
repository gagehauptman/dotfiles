# Dashboard apps

One directory per app, each a `cdylib` crate built by `../build.sh` and
installed as `~/.config/quickshell/modules/Bevy/apps/<name>/lib<name>.so`
(plus the app's `assets/` directory, if it has one). A card points at it with
`{ "type": "bevy", "options": { "app": "<name>" } }` in a preset.

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
workspace). Read `WidgetInput` for the pointer (0..1 over the card, `down`) and
the card size. A transparent clear colour shows the card behind the scene.
Rebuilt apps need a Quickshell restart to load.
