//! A low-poly planet with a ring and three moons — the dashboard's demo app.
//! Drag to orbit; it drifts on its own otherwise.
use bevy::core_pipeline::tonemapping::Tonemapping;
use bevy::prelude::*;
use quickshell_bevy::prelude::*;

pub struct Planet;

impl Plugin for Planet {
    fn build(&self, app: &mut App) {
        app.init_resource::<Drag>().add_systems(Startup, setup).add_systems(Update, (spin, drag));
    }
}

quickshell_bevy::widget!(Planet);

#[derive(Component)]
struct Rig {
    yaw: f32,
    pitch: f32,
}

#[derive(Component)]
struct Globe;

#[derive(Component)]
struct Moon {
    radius: f32,
    speed: f32,
    phase: f32,
    tilt: f32,
}

#[derive(Resource, Default)]
struct Drag {
    last: Option<(f32, f32)>,
}

fn setup(mut commands: Commands, mut meshes: ResMut<Assets<Mesh>>, mut mats: ResMut<Assets<StandardMaterial>>) {
    let palette = |hex: u32| Color::srgb_u8((hex >> 16) as u8, (hex >> 8) as u8, hex as u8); // Catppuccin Mocha
    let (mauve, blue, teal, peach, yellow, base) =
        (palette(0xcba6f7), palette(0x89b4fa), palette(0x94e2d5), palette(0xfab387), palette(0xf9e2af), palette(0x1e1e2e));

    let mut globe_mesh = Sphere::new(1.15).mesh().ico(3).unwrap();
    globe_mesh.duplicate_vertices();
    globe_mesh.compute_flat_normals();
    let globe = meshes.add(globe_mesh);
    let ring = meshes.add(Torus::new(1.9, 2.05).mesh().major_resolution(96).minor_resolution(8));
    let moon = meshes.add(Cuboid::new(0.26, 0.26, 0.26));

    let globe_mat = mats.add(StandardMaterial { base_color: mauve, perceptual_roughness: 0.55, ..default() });
    let ring_mat = mats.add(StandardMaterial { base_color: blue.with_alpha(0.55), alpha_mode: AlphaMode::Blend, perceptual_roughness: 0.3, ..default() });
    let moon_mats = [teal, peach, yellow].map(|c| mats.add(StandardMaterial { base_color: c, emissive: c.to_linear() * 0.25, perceptual_roughness: 0.4, ..default() }));

    let rig = commands.spawn((Rig { yaw: 0.0, pitch: 0.35 }, Transform::default(), Visibility::default())).id();
    commands.spawn((Mesh3d(globe), MeshMaterial3d(globe_mat), Globe, Transform::default(), ChildOf(rig)));
    commands.spawn((Mesh3d(ring), MeshMaterial3d(ring_mat), Transform::from_rotation(Quat::from_rotation_x(1.35)), ChildOf(rig)));
    for (i, mat) in moon_mats.into_iter().enumerate() {
        let k = i as f32;
        commands.spawn((
            Mesh3d(moon.clone()),
            MeshMaterial3d(mat),
            Moon { radius: 2.0 + 0.35 * k, speed: 0.9 - 0.2 * k, phase: k * 2.1, tilt: 0.25 * k },
            Transform::default(),
            ChildOf(rig),
        ));
    }
    commands.spawn((
        DirectionalLight { illuminance: 9000.0, shadows_enabled: false, ..default() },
        Transform::from_xyz(3.0, 5.0, 4.0).looking_at(Vec3::ZERO, Vec3::Y),
    ));
    commands.insert_resource(AmbientLight { color: base, brightness: 900.0, ..default() });
    commands.spawn((
        Camera3d::default(),
        WidgetCamera,
        Camera { clear_color: ClearColorConfig::Custom(Color::NONE), ..default() },
        Tonemapping::ReinhardLuminance,
        Msaa::Sample4,
        Transform::from_xyz(0.0, 2.2, 6.5).looking_at(Vec3::ZERO, Vec3::Y),
    ));
}

fn spin(time: Res<Time>, mut globes: Query<&mut Transform, (With<Globe>, Without<Moon>)>, mut moons: Query<(&Moon, &mut Transform), Without<Globe>>) {
    let t = time.elapsed_secs();
    for mut tf in &mut globes {
        tf.rotation = Quat::from_rotation_y(t * 0.25);
    }
    for (m, mut tf) in &mut moons {
        let a = t * m.speed + m.phase;
        tf.translation = Vec3::new(a.cos() * m.radius, (a * 2.0).sin() * 0.25 * m.tilt.max(0.3), a.sin() * m.radius);
        tf.rotation = Quat::from_rotation_y(a) * Quat::from_rotation_x(a * 0.7);
    }
}

fn drag(input: Res<WidgetInput>, mut state: ResMut<Drag>, time: Res<Time>, mut rigs: Query<(&mut Rig, &mut Transform)>) {
    for (mut rig, mut tf) in &mut rigs {
        if input.down {
            if let Some((lx, ly)) = state.last {
                rig.yaw += (input.x - lx) * 4.0;
                rig.pitch = (rig.pitch + (input.y - ly) * 3.0).clamp(-1.2, 1.2);
            }
            state.last = Some((input.x, input.y));
        } else {
            state.last = None;
            rig.yaw += time.delta_secs() * 0.12; // idle drift
        }
        tf.rotation = Quat::from_rotation_y(rig.yaw) * Quat::from_rotation_x(rig.pitch);
    }
}
