//! Globe: live weather, light pollution and aircraft on a vector-style
//! cube-sphere, in the dashboard's colours. Data comes from
//! scripts/globeserver.py on 127.0.0.1:38471 (the registry starts it).
//!
//! Preset options for the card (the initial state; the card's toggles change
//! it while the widget lives):
//!
//!   "options": { "layers": ["weather", "lp", "air", "sats"],
//!                "satellites": ["stations", "visual", "weather", "gnss"],
//!                "view": { "type": "focus", "lat": 48.9, "lon": 2.3, "dist": 1.8 } }
//!   "view": { "type": "chase", "satellite": "ISS", "target": [29.3, -81.1], "standoff": 0.45 }
//!
//! Weather and orbits are on by default, lights (light pollution) and
//! aircraft off. Drag to orbit, wheel to zoom, Home flies to home, click an
//! aircraft for its flight, type, route and path, click a satellite for its
//! orbit and a Follow pill that chases it towards home. The camera rigs are
//! the harness's `rig` module; a `view` control event drives them too:
//! `orbit`, `focus:lat,lon[,dist]`, `chase:NAME[:lat,lon][:standoff]`.
//! The view starts centred on the service's idea of home (/geo.json),
//! which is also marked with a ring.
//! Coastlines and borders come from Natural Earth through the service: 50m
//! lines and the biggest country names far out, 10m coastlines and national
//! borders with every country name and the largest cities closer, and region
//! borders with region names and more cities the further in. Names are
//! painted on the surface along great circles (text.rs); cities get rings
//! sized by population. Readouts: moving aircraft drawn, weather frame time
//! (UTC) and home.
mod config;
mod material;
mod net;
mod sats;
mod sphere;
mod text;

use std::collections::HashMap;
use std::time::{SystemTime, UNIX_EPOCH};

use bevy::core_pipeline::tonemapping::{DebandDither, Tonemapping};
use bevy::pbr::MaterialPlugin;
use bevy::prelude::*;
use bevy::render::mesh::{Indices, PrimitiveTopology};
use bevy::render::render_asset::RenderAssetUsages;
use bevy::render::render_resource::TextureFormat;
use bevy::render::view::NoFrustumCulling;
use bevy::text::Font;
use quickshell_bevy::prelude::*;
use serde::Deserialize;

use config::{Change, Options, SatStyle, ViewOption};
use material::{texture, GlobeMaterial, GlobeParams, GLOBE_SHADER};
use net::{Cmd, Detail, Feed, Kind, Msg, TexFormat};
use sats::Sat;
use sphere::{Lines, Shapes};
use text::{Atlas, TextMesh, RASTER_PX};

pub struct Globe;

impl Plugin for Globe {
    fn build(&self, app: &mut App) {
        app.world_mut()
            .resource_mut::<Assets<Shader>>()
            .insert(GLOBE_SHADER.id(), Shader::from_wgsl(include_str!("globe.wgsl"), "globe/globe.wgsl"));
        let json = app.world().resource::<WidgetOptions>().0.clone();
        let mut options = Options::parse(&json);
        // what the user changed in the settings panel before, on top of the preset
        for (id, value) in options.settings.clone() {
            options.apply(&id, &value);
        }
        let palette = Palette::from_theme(&options.theme, &options.colors);
        let layers = Layers::from_options(&options);
        let sat_options = options.sats();
        let feed = net::start(net::Config {
            base: options.server.clone().unwrap_or_else(|| "http://127.0.0.1:38471".into()),
            lp_query: format!("pal={}&tint={}", palette.lp_pal.join(","), palette.lp_tint),
            geo_query: options.geo_query(),
            line_radius: R_OUTLINE,
            sat_query: if layers.sats { sat_options.query() } else { String::new() },
        });
        let (mode, pending) = match &options.view {
            Some(ViewOption::Focus { lat, lon, dist }) => (View::Focus { dir: sphere::latlon(lat.to_radians(), lon.to_radians()), dist: dist.unwrap_or(2.2) }, None),
            Some(ViewOption::Chase { satellite, target, standoff }) => {
                (View::Orbit, Some((satellite.clone(), target.map(|[lat, lon]| sphere::latlon(lat.to_radians(), lon.to_radians())), standoff.unwrap_or(0.45))))
            }
            None => (View::Orbit, None),
        };
        // the sun's direction and the data layers live in the material
        redraw_on_asset::<GlobeMaterial>(app);
        app.add_plugins(MaterialPlugin::<GlobeMaterial>::default())
            .insert_resource(feed)
            .insert_resource(palette)
            .insert_resource(layers)
            .insert_resource(Display { scale: options.scale.unwrap_or(1.0).clamp(0.5, 4.0) })
            .insert_resource(sat_options)
            .insert_resource(options)
            .insert_resource(PresetOptions(json))
            .init_resource::<Orbit>()
            .init_resource::<Air>()
            .init_resource::<Labels>()
            .init_resource::<Selection>()
            .init_resource::<Sats>()
            .insert_resource(CameraRig { mode, pending_chase: pending })
            // Nothing here moves on its own clock except what the systems
            // rebuild (aircraft a few times a second, satellites every frame
            // while shown), so a still globe needn't be redrawn 30 times a second.
            .insert_resource(FramePacing { on_change: true, ..default() })
            .add_systems(Startup, setup)
            .add_systems(Update, (receive, controls, settings, camera, select, line_visibility, labels, sun, aircraft, selection_view, satellites).chain());
    }
}

quickshell_bevy::widget!(Globe);

// ---------------------------------------------------------------- options

/// How the camera is driven. `Orbit` is the hand-driven view; the others
/// are the harness's rigs, and any drag drops back to `Orbit` from wherever
/// the camera is.
#[derive(Clone, Debug)]
enum View {
    Orbit,
    /// straight down at a point of the surface (a unit vector), from `dist`
    Focus { dir: Vec3, dist: f32 },
    /// from behind a satellite towards a point on the surface (None: home)
    Chase { norad: u32, target: Option<Vec3>, standoff: f32 },
}

/// The options JSON as the card handed it over, for the Reset button.
#[derive(Resource)]
struct PresetOptions(String);

#[derive(Resource)]
struct CameraRig {
    mode: View,
    /// a chase asked for by name before the elements arrived
    pending_chase: Option<(String, Option<Vec3>, f32)>,
}

#[derive(Resource, Clone, Copy)]
struct Layers {
    weather: bool,
    lp: bool,
    air: bool,
    sats: bool,
    outlines: bool,
    labels: bool,
    graticule: bool,
}

impl Layers {
    fn from_options(o: &Options) -> Self {
        Layers {
            weather: o.layer_on("weather", true),
            lp: o.layer_on("lp", false),
            air: o.layer_on("air", false),
            sats: o.layer_on("sats", true),
            outlines: true, // coastlines, borders and names are the globe; no toggles
            labels: true,
            graticule: o.graticule.show,
        }
    }
}

#[derive(Resource)]
struct Display {
    scale: f32,
}

/// Colours picked from the shell theme (Catppuccin Mocha when a key is
/// missing), with the preset's `colors` overrides applied.
#[derive(Resource, Clone)]
struct Palette {
    fill: Color,
    coast: Color,
    border: Color,
    region: Color,
    grid: Color,
    rim: Color,
    home: Color,
    /// by altitude band: below 10 000 ft, 25 000 ft, 36 000 ft, above
    air: [Color; 4],
    /// label colours by kind: country, region, place, capital
    text: [Color; 4],
    airport: Color,
    /// eight light pollution zone colours and the tint they fade towards, as rrggbb
    lp_pal: Vec<String>,
    lp_tint: String,
}

impl Palette {
    fn from_theme(theme: &HashMap<String, String>, overrides: &HashMap<String, String>) -> Self {
        let pick = |key: &str, fallback: &str| -> (Color, String) {
            let s = theme.get(key).map(String::as_str).unwrap_or(fallback);
            let hex = s.trim_start_matches('#');
            let hex = if hex.len() == 8 { &hex[2..] } else { hex }; // QML prints #aarrggbb for translucent colours
            let v = u32::from_str_radix(hex, 16).ok().filter(|_| hex.len() == 6);
            let v = v.unwrap_or_else(|| u32::from_str_radix(fallback.trim_start_matches('#'), 16).unwrap_or(0));
            (Color::srgb_u8((v >> 16) as u8, (v >> 8) as u8, v as u8), format!("{:06x}", v))
        };
        let (fill, _tint) = pick("panelDeep", "#181825");
        let lp_pal = ["blue", "teal", "green", "yellow", "orange", "red", "pink", "textPrimary"]
            .iter()
            .zip(["#89b4fa", "#94e2d5", "#a6e3a1", "#f9e2af", "#fab387", "#f38ba8", "#f5c2e7", "#cdd6f4"])
            .map(|(k, f)| pick(k, f).1)
            .collect();
        let over = |key: &str, base: Color| overrides.get(key).and_then(|c| config::parse_color(c, theme)).unwrap_or(base);
        let fill = over("fill", fill);
        Palette {
            fill,
            coast: over("coast", pick("teal", "#94e2d5").0.with_alpha(0.75)),
            border: over("borders", pick("lavender", "#b4befe").0.with_alpha(0.5)),
            region: over("regions", pick("textMuted", "#6c7086").0.with_alpha(0.6)),
            grid: over("grid", pick("textMuted", "#6c7086").0.with_alpha(0.28)),
            rim: over("rim", pick("teal", "#94e2d5").0),
            home: over("home", pick("pink", "#f5c2e7").0),
            air: [
                over("aircraft_low", pick("green", "#a6e3a1").0),
                over("aircraft_mid", pick("yellow", "#f9e2af").0),
                over("aircraft_high", pick("orange", "#fab387").0),
                over("aircraft_cruise", pick("blue", "#89b4fa").0),
            ],
            text: [
                over("countries", pick("textPrimary", "#cdd6f4").0),
                over("region_names", pick("textPrimary", "#cdd6f4").0),
                over("cities", pick("textSecondary", "#a6adc8").0),
                over("capitals", pick("textPrimary", "#cdd6f4").0),
            ],
            airport: over("airports", pick("blue", "#89b4fa").0),
            lp_pal,
            lp_tint: format!("{:06x}", {
                let l = fill.to_srgba();
                ((l.red * 255.0) as u32) << 16 | ((l.green * 255.0) as u32) << 8 | (l.blue * 255.0) as u32
            }),
        }
    }
}

fn lin(c: Color) -> [f32; 4] {
    c.to_linear().to_f32_array()
}

// ---------------------------------------------------------------- scene

#[derive(Resource)]
struct Handles {
    material: Handle<GlobeMaterial>,
    home: Handle<Mesh>,
    coast: Handle<StandardMaterial>,
    border: Handle<StandardMaterial>,
    region: Handle<StandardMaterial>,
    /// every text material (they share the atlas texture; each layer has its own for the draw order)
    text_mats: Vec<Handle<StandardMaterial>>,
}

#[derive(Component)]
struct HomeMarker;

/// Entities whose mesh is rebuilt at runtime: each rebuild is a fresh mesh
/// asset swapped into the entity's `Mesh3d`, and the old one is dropped.
#[derive(Component)]
struct LabelMesh;
#[derive(Component)]
struct MarkerMesh;
#[derive(Component)]
struct AirMesh;
/// The aircraft silhouettes (filled), beside the lines in `AirMesh`
#[derive(Component)]
struct AirFill;
/// Callsigns beside the aircraft when zoomed in
#[derive(Component)]
struct AirText;
/// Filled markers of the label pass (airports)
#[derive(Component)]
struct MarkerFill;
/// The clicked aircraft's path and route
#[derive(Component)]
struct TrailMesh;
/// The clicked aircraft's flight and altitude next to it, and its airports
#[derive(Component)]
struct SelText;
/// Satellite markers, their orbits, their names
#[derive(Component)]
struct SatMesh;
/// The satellite icons (filled billboards)
#[derive(Component)]
struct SatIcon;
#[derive(Component)]
struct OrbitMesh;
#[derive(Component)]
struct SatText;

/// The satellites and what was last drawn for them.
#[derive(Resource, Default)]
struct Sats {
    list: Vec<Sat>,
    /// how each one is drawn, resolved from the options
    styles: Vec<SatStyle>,
    /// orbit lines by NORAD number: when computed, and the points
    tracks: HashMap<u32, (f64, Vec<Vec3>)>,
    /// which lines the orbit mesh currently shows, and whether it must be
    /// redrawn regardless (styles changed)
    track_set: Vec<u32>,
    redraw: bool,
    readout_at: f64,
    /// something is on screen and needs clearing when the list empties
    drawn: bool,
}

impl Sats {
    fn find(&self, norad: u32) -> Option<&Sat> {
        self.list.iter().find(|s| s.norad == norad)
    }

    /// By NORAD number or a case-insensitive part of the name ("ISS")
    fn by_name(&self, q: &str) -> Option<&Sat> {
        if let Ok(n) = q.trim().parse::<u32>() {
            return self.find(n);
        }
        let q = q.trim().to_uppercase();
        self.list.iter().find(|s| s.name.to_uppercase() == q).or_else(|| self.list.iter().find(|s| s.name.to_uppercase().contains(&q)))
    }
}

/// The aircraft or satellite the user clicked.
#[derive(Resource, Default)]
struct Selection {
    hex: Option<String>,
    sat: Option<u32>,
    detail: Option<Detail>,
    /// where it was last drawn: position on the unit sphere, altitude, flight
    pos: Option<(Vec3, f32, String)>,
    text_dirty: bool,
    trail_dirty: bool,
}

const R_TRAIL: f32 = 1.0045;

/// Which toggle shows or hides this entity.
#[derive(Component, Clone, Copy, PartialEq, Eq)]
enum Layer {
    Air,
    Graticule,
    Sats,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum LineKind {
    Coast,
    Admin0,
    Admin1,
    /// the embedded 110m outlines, shown until the service's bundle arrives
    Fallback,
}

/// A coastline or border layer; `detail` 0 is the 50m scale, 1 the 10m scale.
#[derive(Component, Clone, Copy)]
struct LineLayer {
    kind: LineKind,
    detail: u8,
}

/// Every label the bundle has, the glyph atlas, and what was drawn last.
#[derive(Resource, Default)]
struct Labels {
    defs: Vec<net::Label>,
    atlas: Option<Atlas>,
    last_cam: Option<Vec3>,
    last_set: Vec<(usize, bool)>,
    dirty: bool,
}

const SURFACE: f32 = 1.0;
const R_GRID: f32 = 1.0015;
const R_OUTLINE: f32 = 1.003;
const R_HOME: f32 = 1.005;
const R_AIR: f32 = 1.004;
const R_MARKER: f32 = 1.0045;
const R_TEXT: f32 = 1.006;

fn shown(on: bool) -> Visibility {
    if on {
        Visibility::Visible
    } else {
        Visibility::Hidden
    }
}

fn setup(
    mut commands: Commands,
    mut meshes: ResMut<Assets<Mesh>>,
    mut globe_mats: ResMut<Assets<GlobeMaterial>>,
    mut std_mats: ResMut<Assets<StandardMaterial>>,
    mut images: ResMut<Assets<Image>>,
    mut ui: ResMut<WidgetUi>,
    mut labels: ResMut<Labels>,
    fonts: Res<Assets<Font>>,
    palette: Res<Palette>,
    layers: Res<Layers>,
    options: Res<Options>,
) {
    ui.toggle("weather", "Weather", layers.weather)
        .toggle("lp", "Lights", layers.lp)
        .toggle("air", "Aircraft", layers.air)
        .toggle("sats", "Orbits", layers.sats)
        .button("home", "Home");
    declare_settings(&mut ui, &options);

    // Empty layers until the service delivers: transparent palettes, zero indices
    let mut blank = |format: TextureFormat, bytes: Vec<u8>| images.add(texture(1, 1, bytes, format, false, false));
    let (blank_rg, blank_r, blank_rgba) = (blank(TextureFormat::Rg8Unorm, vec![0, 0]), blank(TextureFormat::R8Unorm, vec![0]), blank(TextureFormat::Rgba8UnormSrgb, vec![0, 0, 0, 0]));
    let rim = lin(palette.rim);
    let material = globe_mats.add(GlobeMaterial {
        params: GlobeParams {
            fill: Vec4::from_array(lin(palette.fill)),
            rim: Vec4::new(rim[0], rim[1], rim[2], 0.07),
            sun: Vec4::new(1.0, 0.0, 0.0, 0.3),
            layers: Vec4::new(
                if layers.weather { options.weather.opacity } else { 0.0 },
                if layers.lp { options.lights.opacity } else { 0.0 },
                options.weather.saturation,
                options.lights.day,
            ),
            inset_wx: Vec4::ZERO,
            inset_lp: Vec4::ZERO,
        },
        weather: blank_rg.clone(),
        lp: blank_r.clone(),
        weather_inset: blank_rg,
        lp_inset: blank_r,
        weather_lut: blank_rgba.clone(),
        lp_lut: blank_rgba,
    });
    commands.spawn((Mesh3d(meshes.add(sphere::mesh(48))), MeshMaterial3d(material.clone()), Transform::from_scale(Vec3::splat(SURFACE))));

    // Every overlay is alpha blended without depth writes, so what is drawn
    // over what is the transparent sort order, and that ties between meshes
    // at the same origin (and then flickers frame to frame). A depth bias per
    // layer breaks the ties: bigger is drawn later, on top. Kept under 1 so
    // no rasteriser bias is applied.
    let line_mat = |c: Color, bias: f32| StandardMaterial { base_color: c, unlit: true, alpha_mode: AlphaMode::Blend, cull_mode: None, depth_bias: bias, ..default() };
    let mut layer_mat = |bias: f32| std_mats.add(line_mat(Color::WHITE, bias)); // vertex-coloured layers
    let grid_mat = layer_mat(0.05);
    let marker_fill_mat = layer_mat(0.20);
    let marker_mat = layer_mat(0.21);
    let trail_mat = layer_mat(0.30);
    let air_fill_mat = layer_mat(0.32);
    let air_mat = layer_mat(0.34);
    let home_mat = layer_mat(0.40);
    let orbit_mat = layer_mat(0.50);
    let sat_icon_mat = layer_mat(0.52);
    let sat_mat = layer_mat(0.54);
    let region = std_mats.add(line_mat(palette.region, 0.10));
    let border = std_mats.add(line_mat(palette.border, 0.11));
    let coast = std_mats.add(line_mat(palette.coast, 0.12));
    commands.spawn((Mesh3d(meshes.add(graticule(lin(palette.grid), options.graticule.step))), MeshMaterial3d(grid_mat), Layer::Graticule, shown(layers.graticule)));
    commands.spawn((
        Mesh3d(meshes.add(outlines())),
        MeshMaterial3d(coast.clone()),
        LineLayer { kind: LineKind::Fallback, detail: 1 },
        shown(layers.outlines),
    ));
    let air = meshes.add(Lines::default().mesh());
    commands.spawn((Mesh3d(air.clone()), MeshMaterial3d(air_mat), NoFrustumCulling, Layer::Air, AirMesh, shown(layers.air)));
    commands.spawn((Mesh3d(meshes.add(Shapes::default().mesh())), MeshMaterial3d(air_fill_mat), NoFrustumCulling, Layer::Air, AirFill, shown(layers.air)));
    let home = meshes.add(Lines::default().mesh());
    commands.spawn((Mesh3d(home.clone()), MeshMaterial3d(home_mat), NoFrustumCulling, Visibility::Hidden, HomeMarker));

    // Names on the surface: a glyph atlas from the system font, one mesh of quads
    let font = Atlas::system_font().or_else(|| fonts.get(&Handle::<Font>::default()).map(|f| f.data.to_vec()));
    labels.atlas = font.and_then(Atlas::new);
    if let Some(a) = labels.atlas.as_mut() {
        a.dirty = false; // uploaded right here
    }
    let atlas = images.add(labels.atlas.as_ref().map(|a| a.image()).unwrap_or_else(|| texture(1, 1, vec![0, 0, 0, 0], TextureFormat::Rgba8UnormSrgb, false, false)));
    let mut text_mat = |bias: f32| {
        std_mats.add(StandardMaterial {
            base_color: Color::WHITE,
            base_color_texture: Some(atlas.clone()),
            unlit: true,
            alpha_mode: AlphaMode::Blend,
            cull_mode: None,
            depth_bias: bias,
            ..default()
        })
    };
    let (label_text_mat, air_text_mat, sel_text_mat, sat_text_mat) = (text_mat(0.25), text_mat(0.36), text_mat(0.37), text_mat(0.56));
    let text_mats = vec![label_text_mat.clone(), air_text_mat.clone(), sel_text_mat.clone(), sat_text_mat.clone()];
    let label_mesh = meshes.add(TextMesh::default().mesh());
    commands.spawn((Mesh3d(label_mesh.clone()), MeshMaterial3d(label_text_mat), NoFrustumCulling, LabelMesh));
    commands.spawn((Mesh3d(meshes.add(TextMesh::default().mesh())), MeshMaterial3d(air_text_mat), NoFrustumCulling, Layer::Air, AirText, shown(layers.air)));
    let markers = meshes.add(Lines::default().mesh());
    commands.spawn((Mesh3d(markers.clone()), MeshMaterial3d(marker_mat), NoFrustumCulling, MarkerMesh));
    commands.spawn((Mesh3d(meshes.add(Shapes::default().mesh())), MeshMaterial3d(marker_fill_mat), NoFrustumCulling, MarkerFill));
    commands.spawn((Mesh3d(meshes.add(Lines::default().mesh())), MeshMaterial3d(trail_mat), NoFrustumCulling, TrailMesh));
    commands.spawn((Mesh3d(meshes.add(TextMesh::default().mesh())), MeshMaterial3d(sel_text_mat), NoFrustumCulling, SelText));
    commands.spawn((Mesh3d(meshes.add(Lines::default().mesh())), MeshMaterial3d(sat_mat), NoFrustumCulling, Layer::Sats, shown(layers.sats), SatMesh));
    commands.spawn((Mesh3d(meshes.add(Shapes::default().mesh())), MeshMaterial3d(sat_icon_mat), NoFrustumCulling, Layer::Sats, shown(layers.sats), SatIcon));
    commands.spawn((Mesh3d(meshes.add(Lines::default().mesh())), MeshMaterial3d(orbit_mat), NoFrustumCulling, Layer::Sats, shown(layers.sats), OrbitMesh));
    commands.spawn((Mesh3d(meshes.add(TextMesh::default().mesh())), MeshMaterial3d(sat_text_mat), NoFrustumCulling, Layer::Sats, shown(layers.sats), SatText));

    commands.spawn((
        Camera3d::default(),
        WidgetCamera,
        Camera { clear_color: ClearColorConfig::Custom(Color::NONE), ..default() },
        Projection::from(PerspectiveProjection { fov: FOV, near: 0.01, ..default() }),
        Tonemapping::None,
        DebandDither::Disabled,
        Msaa::Sample4,
        Transform::from_xyz(0.0, 0.0, 4.0).looking_at(Vec3::ZERO, Vec3::Y),
    ));
    commands.insert_resource(Handles { material, home, coast, border, region, text_mats });
}

/// A grid every `step` degrees, the equator and prime meridian a little brighter.
fn graticule(color: [f32; 4], step: f32) -> Mesh {
    let step = step.clamp(1.0, 90.0);
    let mut lines = Lines::default();
    let bright = [color[0], color[1], color[2], (color[3] * 1.7).min(1.0)];
    let mut lat: f32 = -90.0 + step;
    while lat < 89.999 {
        let c = if lat.abs() < 1e-3 { bright } else { color };
        let latr = lat.to_radians();
        lines.path((0..=180).map(|i| sphere::latlon(latr, (i as f32 * 2.0).to_radians()) * R_GRID), c);
        lat += step;
    }
    let mut lon: f32 = -180.0;
    while lon < 179.999 {
        let c = if lon.abs() < 1e-3 { bright } else { color };
        let lonr = lon.to_radians();
        lines.path((0..=90).map(|i| sphere::latlon((i as f32 * 2.0 - 90.0).to_radians(), lonr) * R_GRID), c);
        lon += step;
    }
    lines.mesh()
}

#[derive(Deserialize)]
struct Earth {
    feature: Vec<Feature>,
}

#[derive(Deserialize)]
struct Feature {
    #[allow(dead_code)]
    name: String,
    points: Vec<[f64; 2]>,
}

/// The embedded 110m outlines (downrange's earth.toml): the stand-in until
/// the Natural Earth bundle is in.
fn outlines() -> Mesh {
    let earth: Earth = toml::from_str(include_str!("earth.toml")).unwrap_or(Earth { feature: Vec::new() });
    let mut positions = Vec::new();
    let mut indices = Vec::new();
    for f in &earth.feature {
        sphere::surface_polyline(f.points.iter().map(|p| (p[1] as f32, p[0] as f32)), R_OUTLINE, &mut positions, &mut indices);
    }
    line_mesh(positions, indices)
}

fn line_mesh(positions: Vec<[f32; 3]>, indices: Vec<u32>) -> Mesh {
    Mesh::new(PrimitiveTopology::LineList, RenderAssetUsages::default())
        .with_inserted_attribute(Mesh::ATTRIBUTE_POSITION, positions)
        .with_inserted_indices(Indices::U32(indices))
}

fn home_ring(lat: f32, lon: f32, color: [f32; 4]) -> Mesh {
    let p = sphere::latlon(lat, lon);
    let (e, n) = sphere::frame(p);
    let mut lines = Lines::default();
    for radius in [0.012, 0.004] {
        lines.path(
            (0..=32).map(|i| {
                let a = i as f32 / 32.0 * std::f32::consts::TAU;
                (p + (e * a.cos() + n * a.sin()) * radius).normalize() * R_HOME
            }),
            color,
        );
    }
    lines.mesh()
}

// ---------------------------------------------------------------- data in

#[allow(clippy::too_many_arguments)]
fn receive(
    mut commands: Commands,
    feed: Res<Feed>,
    handles: Res<Handles>,
    palette: Res<Palette>,
    mut images: ResMut<Assets<Image>>,
    mut meshes: ResMut<Assets<Mesh>>,
    mut mats: ResMut<Assets<GlobeMaterial>>,
    mut orbit: ResMut<Orbit>,
    mut air: ResMut<Air>,
    mut ui: ResMut<WidgetUi>,
    mut labels: ResMut<Labels>,
    mut sel: ResMut<Selection>,
    mut sats: ResMut<Sats>,
    options: Res<Options>,
    mut home: Query<&mut Visibility, With<HomeMarker>>,
    line_layers: Query<(Entity, &LineLayer)>,
) {
    let Ok(rx) = feed.rx.lock() else { return };
    while let Ok(msg) = rx.try_recv() {
        match msg {
            Msg::Geo { lat, lon, city } => {
                let (lat, lon) = (lat.to_radians(), lon.to_radians());
                orbit.home = Some((lat, lon));
                if !orbit.touched {
                    orbit.lat = lat;
                    orbit.lon = lon;
                }
                meshes.insert(handles.home.id(), home_ring(lat, lon, lin(palette.home)));
                for mut v in &mut home {
                    *v = Visibility::Visible;
                }
                if !city.is_empty() {
                    ui.info("home", "\u{f02dc}", city); // nf-md-home
                }
            }
            Msg::Texture { kind, width, height, data, format, stamp, window } => {
                let (format, smooth) = match format {
                    TexFormat::R8 => (TextureFormat::R8Unorm, false), // zone indices: no blending between zones
                    TexFormat::Rg8 => (TextureFormat::Rg8Unorm, true),
                    TexFormat::Rgba8 => (TextureFormat::Rgba8UnormSrgb, false),
                };
                let wrap = matches!(kind, Kind::Weather | Kind::Lp);
                let img = images.add(texture(width, height, data, format, smooth, wrap));
                if let Some(m) = mats.get_mut(&handles.material) {
                    match kind {
                        Kind::Weather => m.weather = img,
                        Kind::Lp => m.lp = img,
                        Kind::WeatherInset => {
                            m.weather_inset = img;
                            m.params.inset_wx = Vec4::from_array(window);
                        }
                        Kind::LpInset => {
                            m.lp_inset = img;
                            m.params.inset_lp = Vec4::from_array(window);
                        }
                        Kind::WeatherLut => m.weather_lut = img,
                        Kind::LpLut => m.lp_lut = img,
                    }
                }
                if kind == Kind::Weather && stamp > 0 {
                    ui.info("weather", "\u{f0590}", format!("{:02}:{:02}Z", stamp.rem_euclid(86400) / 3600, stamp.rem_euclid(3600) / 60)); // nf-md-weather-cloudy
                }
            }
            Msg::Air { rows, ts } => {
                // a few minutes of positions per aircraft, for the tails
                let mut seen: HashMap<String, Vec<(f64, Vec3)>> = HashMap::with_capacity(rows.len());
                for a in &rows {
                    let mut h = air.history.remove(&a.hex).unwrap_or_default();
                    if h.last().map_or(true, |(t, _)| ts - t > 1.0) {
                        h.push((ts, sphere::latlon(a.lat.to_radians(), a.lon.to_radians())));
                    }
                    h.retain(|(t, _)| ts - t < 300.0);
                    seen.insert(a.hex.clone(), h);
                }
                air.history = seen;
                air.rows = rows;
                air.ts = ts;
                air.dirty = true;
            }
            Msg::Detail(d) => {
                if sel.hex.as_deref() == Some(d.hex.as_str()) {
                    ui.info("flight", "", flight_summary(&d));
                    sel.detail = Some(*d);
                    sel.trail_dirty = true;
                    sel.text_dirty = true;
                }
            }
            Msg::Sats(list) => {
                let sat_options = options.sats();
                sats.styles = list.iter().map(|s| sat_options.style_for(&s.name, s.norad, &s.group, &options.theme)).collect();
                sats.list = list;
                sats.tracks.clear();
                sats.track_set.clear();
            }
            Msg::Vectors(v) => {
                for (e, l) in &line_layers {
                    if l.kind == LineKind::Fallback {
                        commands.entity(e).despawn();
                    }
                }
                for layer in v.layers {
                    let (kind, detail) = match layer.name.as_str() {
                        "coast50" => (LineKind::Coast, 0),
                        "coast10" => (LineKind::Coast, 1),
                        "admin0_50" => (LineKind::Admin0, 0),
                        "admin0_10" => (LineKind::Admin0, 1),
                        "admin1_10" => (LineKind::Admin1, 1),
                        _ => continue,
                    };
                    let mat = match kind {
                        LineKind::Coast | LineKind::Fallback => handles.coast.clone(),
                        LineKind::Admin0 => handles.border.clone(),
                        LineKind::Admin1 => handles.region.clone(),
                    };
                    commands.spawn((
                        Mesh3d(meshes.add(line_mesh(layer.positions, layer.indices))),
                        MeshMaterial3d(mat),
                        LineLayer { kind, detail },
                        NoFrustumCulling,
                        Visibility::Hidden,
                    ));
                }
                labels.defs = v.labels;
                labels.dirty = true;
            }
        }
    }
}

// ---------------------------------------------------------------- settings

/// The card's settings panel: the handful of options worth reaching for
/// while looking at the globe, with their current values (the preset has
/// the rest). Called at start and after a reset.
fn declare_settings(ui: &mut WidgetUi, o: &Options) {
    let so = o.sats();
    let groups = ["stations", "visual", "weather", "gnss", "science", "starlink"];
    let pops = ["0", "100000", "500000", "1000000"];
    let pop = format!("{}", o.labels.min_population as i64);
    ui.setting("Layers", Control::slider("weather.opacity", "Weather", 0.0, 1.0, 0.05, o.weather.opacity))
        .setting("Layers", Control::slider("lights.opacity", "Lights", 0.0, 1.0, 0.05, o.lights.opacity))
        .setting("Layers", Control::toggle("graticule.show", "Grid", o.graticule.show))
        .setting("Satellites", Control::multi("satellites.groups", "Groups", &groups, &so.groups))
        .setting("Satellites", Control::multi("satellites.track_groups", "Orbit lines", &groups, &so.track_groups))
        .setting("Aircraft", Control::slider("aircraft.min_altitude", "Hide below (ft)", 0.0, 10000.0, 500.0, o.aircraft.min_altitude))
        .setting("Names", Control::select("labels.min_population", "Cities from", &pops, if pops.contains(&pop.as_str()) { &pop } else { "0" }))
        .setting("Names", Control::toggle("labels.airports", "Airports", o.labels.airports))
        .setting("", Control::button("settings.reset", "Reset to the preset"));
}

/// Changes from the settings panel (and Reset): update the options and
/// refresh whatever they affect.
#[allow(clippy::too_many_arguments)]
fn settings(
    mut events: EventReader<WidgetEvent>,
    preset: Res<PresetOptions>,
    handles: Res<Handles>,
    feed: Res<Feed>,
    palette: Res<Palette>,
    mut options: ResMut<Options>,
    mut sat_options: ResMut<config::SatOptions>,
    mut layers: ResMut<Layers>,
    mut sats: ResMut<Sats>,
    mut lab: ResMut<Labels>,
    mut ui: ResMut<WidgetUi>,
    mut mats: ResMut<Assets<GlobeMaterial>>,
    mut meshes: ResMut<Assets<Mesh>>,
    mut layer_q: Query<(&Layer, &mut Mesh3d, &mut Visibility)>,
) {
    let mut changes: Vec<Change> = Vec::new();
    for e in events.read() {
        if e.id == "settings.reset" {
            *options = Options::parse(&preset.0);
            changes.extend([Change::Layers, Change::Material, Change::Grid, Change::SatelliteSet, Change::Labels, Change::Aircraft]);
            declare_settings(&mut ui, &options);
        } else if let Some(c) = options.apply(&e.id, &e.value) {
            if !matches!(e.id.as_str(), "weather" | "lp" | "air" | "sats") {
                changes.push(c); // the pill toggles are handled in `controls`
            }
        }
    }
    if changes.is_empty() {
        return;
    }
    let has = |c: Change| changes.contains(&c);
    if has(Change::Layers) {
        let l = Layers::from_options(&options);
        *layers = l;
        ui.toggle("weather", "Weather", l.weather).toggle("lp", "Lights", l.lp).toggle("air", "Aircraft", l.air).toggle("sats", "Orbits", l.sats);
        for (layer, _, mut vis) in &mut layer_q {
            match layer {
                Layer::Air => *vis = shown(l.air),
                Layer::Sats => *vis = shown(l.sats),
                Layer::Graticule => {}
            }
        }
    }
    if has(Change::Material) || has(Change::Layers) {
        if let Some(m) = mats.get_mut(&handles.material) {
            m.params.layers = Vec4::new(
                if layers.weather { options.weather.opacity } else { 0.0 },
                if layers.lp { options.lights.opacity } else { 0.0 },
                options.weather.saturation,
                options.lights.day,
            );
        }
    }
    if has(Change::Grid) {
        layers.graticule = options.graticule.show;
        let mesh = meshes.add(graticule(lin(palette.grid), options.graticule.step));
        for (layer, mut m, mut vis) in &mut layer_q {
            if *layer == Layer::Graticule {
                m.0 = mesh.clone();
                *vis = shown(options.graticule.show);
            }
        }
    }
    if has(Change::Satellites) || has(Change::SatelliteSet) {
        *sat_options = options.sats();
        sats.styles = sats.list.iter().map(|s| sat_options.style_for(&s.name, s.norad, &s.group, &options.theme)).collect();
        sats.redraw = true; // the lines again, from the cached points, with the new choice and colours
        if has(Change::SatelliteSet) {
            feed.send(Cmd::Sats(if layers.sats { sat_options.query() } else { String::new() }));
        }
    }
    if has(Change::Labels) {
        lab.dirty = true;
    }
}

// ---------------------------------------------------------------- controls

/// Presses on the card's toggles and the Home button.
#[allow(clippy::too_many_arguments)]
fn controls(
    mut events: EventReader<WidgetEvent>,
    handles: Res<Handles>,
    feed: Res<Feed>,
    input: Res<WidgetInput>,
    sats: Res<Sats>,
    options: Res<Options>,
    mut layers: ResMut<Layers>,
    mut sel: ResMut<Selection>,
    mut ui: ResMut<WidgetUi>,
    mut orbit: ResMut<Orbit>,
    mut cam_rig: ResMut<CameraRig>,
    mut mats: ResMut<Assets<GlobeMaterial>>,
    mut visible: Query<(&Layer, &mut Visibility)>,
) {
    let aspect = if input.height > 0 { input.width as f32 / input.height as f32 } else { 1.0 };
    for e in events.read() {
        match e.id.as_str() {
            "weather" | "lp" => {
                if e.id == "weather" {
                    layers.weather = e.on();
                } else {
                    layers.lp = e.on();
                }
                if let Some(m) = mats.get_mut(&handles.material) {
                    m.params.layers.x = if layers.weather { options.weather.opacity } else { 0.0 };
                    m.params.layers.y = if layers.lp { options.lights.opacity } else { 0.0 };
                }
            }
            "air" => {
                layers.air = e.on();
                for (l, mut v) in &mut visible {
                    if *l == Layer::Air {
                        *v = shown(e.on());
                    }
                }
                if !e.on() {
                    sel.hex = None;
                    sel.detail = None;
                    sel.pos = None;
                    sel.trail_dirty = true;
                    sel.text_dirty = true;
                    feed.send(Cmd::Select(None));
                    ui.remove("flight").remove("aircraft");
                }
            }
            "sats" => {
                layers.sats = e.on();
                for (l, mut v) in &mut visible {
                    if *l == Layer::Sats {
                        *v = shown(e.on());
                    }
                }
                if e.on() && sats.list.is_empty() {
                    feed.send(Cmd::Sats(options.sats().query()));
                }
                if !e.on() && sel.sat.take().is_some() {
                    ui.remove("sat").remove("follow");
                    if matches!(cam_rig.mode, View::Chase { .. }) {
                        cam_rig.mode = View::Orbit;
                    }
                }
            }
            "follow" => {
                if let Some(norad) = sel.sat {
                    cam_rig.mode = if e.on() { View::Chase { norad, target: None, standoff: 0.45 } } else { View::Orbit };
                }
            }
            "home" => match orbit.home {
                Some((lat, lon)) => cam_rig.mode = View::Focus { dir: sphere::latlon(lat, lon), dist: fit_distance(aspect) },
                None => {
                    cam_rig.mode = View::Orbit;
                    orbit.touched = false;
                }
            },
            "view" => {
                let mut parts = e.value.split(':');
                let kind = parts.next().unwrap_or("");
                let nums = |s: &str| s.split(',').filter_map(|x| x.trim().parse::<f32>().ok()).collect::<Vec<_>>();
                match kind {
                    "focus" => {
                        let v = nums(parts.next().unwrap_or(""));
                        if v.len() >= 2 {
                            let dist = v.get(2).copied().unwrap_or_else(|| fit_distance(aspect));
                            cam_rig.mode = View::Focus { dir: sphere::latlon(v[0].to_radians(), v[1].to_radians()), dist };
                        }
                    }
                    "chase" => {
                        let name = parts.next().unwrap_or("").to_string();
                        let rest: Vec<&str> = parts.collect();
                        let target = rest.first().map(|t| nums(t)).filter(|v| v.len() >= 2).map(|v| sphere::latlon(v[0].to_radians(), v[1].to_radians()));
                        let standoff = rest.get(1).and_then(|t| t.trim().parse::<f32>().ok()).unwrap_or(0.45);
                        match sats.by_name(&name) {
                            Some(s) => cam_rig.mode = View::Chase { norad: s.norad, target, standoff },
                            None => cam_rig.pending_chase = Some((name, target, standoff)),
                        }
                    }
                    _ => cam_rig.mode = View::Orbit,
                }
            }
            _ => {}
        }
    }
}

// ---------------------------------------------------------------- camera

#[derive(Resource)]
struct Orbit {
    lat: f32,
    lon: f32,
    dist: f32,
    last: Option<(f32, f32)>,
    touched: bool,
    home: Option<(f32, f32)>,
    /// 0 far (50m lines, big countries), 1 mid (10m lines, all countries), 2 near (regions and places)
    level: u8,
    /// where and when the button went down
    press: Option<(f32, f32, f32)>,
    /// the press has moved past the dead zone: it is a drag, not a click
    dragging: bool,
    /// a click (press and release without moving), in pixels, for `select`
    click: Option<Vec2>,
}

impl Default for Orbit {
    fn default() -> Self {
        Orbit { lat: 20f32.to_radians(), lon: 0.0, dist: 4.0, last: None, touched: false, home: None, level: 0, press: None, dragging: false, click: None }
    }
}

const FOV: f32 = 30.0 * std::f32::consts::PI / 180.0;
const LEVEL_FAR: f32 = 2.4;
const LEVEL_NEAR: f32 = 1.45;
const LEVEL_HYST: f32 = 0.06;

/// Camera distance at which the globe fills most of the card's shorter side.
fn fit_distance(aspect: f32) -> f32 {
    let half_v = FOV / 2.0;
    let half = half_v.min((half_v.tan() * aspect.max(0.05)).atan());
    (1.0 / (0.9 * half).sin()).clamp(1.5, 12.0)
}

/// Detail level for a camera distance, sticky around the two boundaries.
fn level_for(dist: f32, current: u8) -> u8 {
    match current {
        0 if dist < LEVEL_FAR - LEVEL_HYST => {
            if dist < LEVEL_NEAR {
                2
            } else {
                1
            }
        }
        1 if dist > LEVEL_FAR + LEVEL_HYST => 0,
        1 if dist < LEVEL_NEAR - LEVEL_HYST => 2,
        2 if dist > LEVEL_NEAR + LEVEL_HYST => {
            if dist > LEVEL_FAR {
                0
            } else {
                1
            }
        }
        l => l,
    }
}

/// Rough web-map zoom for the current distance, to compare with label ranks.
fn zoom_for(dist: f32) -> f32 {
    1.0 + (3.0 / (dist - 1.0).max(0.02)).log2()
}

/// Reads the camera pose back into the orbit state, so a switch to the
/// hand-driven view continues from wherever a rig left the camera.
fn sync_orbit(o: &mut Orbit, tf: &Transform) {
    let p = tf.translation;
    let len = p.length().max(1.01);
    let d = p / len;
    o.dist = len;
    o.lat = d.y.clamp(-1.0, 1.0).asin();
    o.lon = (-d.z).atan2(d.x);
    o.touched = true;
}

/// Pointer input and the camera: drags orbit (and take over from any rig),
/// the wheel zooms or, in a chase, changes the standoff; a press without a
/// move becomes a click for `select`. Then the camera follows the rig.
/// How far out the wheel goes: with satellites on, far enough to take in
/// the geostationary belt; otherwise the globe stays the subject.
fn max_distance(layers: &Layers) -> f32 {
    if layers.sats {
        40.0
    } else {
        16.0
    }
}

fn camera(
    input: Res<WidgetInput>,
    time: Res<Time>,
    sats: Res<Sats>,
    layers: Res<Layers>,
    mut o: ResMut<Orbit>,
    mut cam_rig: ResMut<CameraRig>,
    mut cams: Query<&mut Transform, (With<Camera3d>, With<WidgetCamera>)>,
) {
    let dt = time.delta_secs();
    let aspect = if input.height > 0 { input.width as f32 / input.height as f32 } else { 1.0 };
    let Ok(mut tf) = cams.single_mut() else { return };
    if let Some((name, target, standoff)) = cam_rig.pending_chase.clone() {
        if let Some(s) = sats.by_name(&name) {
            cam_rig.mode = View::Chase { norad: s.norad, target, standoff };
            cam_rig.pending_chase = None;
        }
    }
    let (w, h) = (input.width as f32, input.height as f32);
    if input.down {
        if o.press.is_none() {
            o.press = Some((input.x, input.y, time.elapsed_secs()));
            o.dragging = false;
        }
        // a few pixels of wobble is still a click; past that it is a drag
        if let Some((px, py, _)) = o.press {
            if !o.dragging && ((input.x - px) * w).hypot((input.y - py) * h) > 6.0 {
                o.dragging = true;
                o.last = Some((px, py));
            }
        }
        if let (true, Some((lx, ly))) = (o.dragging, o.last) {
            let (dx, dy) = (input.x - lx, input.y - ly);
            if dx != 0.0 || dy != 0.0 {
                if !matches!(cam_rig.mode, View::Orbit) {
                    cam_rig.mode = View::Orbit;
                    sync_orbit(&mut o, &tf);
                }
                let k = 1.25 * (o.dist - 1.0).max(0.05);
                o.lon -= dx * k * aspect;
                o.lat = (o.lat + dy * k).clamp(-1.48, 1.48);
                o.touched = true;
            }
        }
        if o.dragging {
            o.last = Some((input.x, input.y));
        }
    } else {
        if let Some((px, py, t0)) = o.press.take() {
            if !o.dragging && time.elapsed_secs() - t0 < 1.5 {
                o.click = Some(Vec2::new(px * w, py * h));
            }
        }
        o.dragging = false;
        o.last = None;
    }
    if input.scroll != 0.0 {
        let f = 0.85f32.powf(input.scroll);
        let far = max_distance(&layers);
        match &mut cam_rig.mode {
            View::Chase { standoff, .. } => *standoff = (*standoff * f).clamp(0.03, 12.0),
            View::Focus { dist, .. } => *dist = (*dist * f).clamp(1.06, far),
            View::Orbit => o.dist = (o.dist * f).clamp(1.06, far),
        }
        o.touched = true;
    }
    match cam_rig.mode.clone() {
        View::Orbit => {
            if !o.touched {
                o.dist = fit_distance(aspect);
            }
            // unchanged unless the view moved, so a still globe can idle
            tf.set_if_neq(rig::above(sphere::latlon(o.lat, o.lon), o.dist));
        }
        View::Focus { dir, dist } => {
            rig::approach(&mut tf, &rig::above(dir, dist), dt, 0.35);
            sync_orbit(&mut o, &tf);
        }
        View::Chase { norad, target, standoff } => {
            if let Some(s) = sats.find(norad).filter(|s| s.pos != Vec3::ZERO) {
                let target = target.or_else(|| o.home.map(|(lat, lon)| sphere::latlon(lat, lon))).unwrap_or_else(|| s.pos.normalize_or(Vec3::Z));
                rig::approach(&mut tf, &rig::chase(s.pos, target, standoff), dt, 0.25);
                sync_orbit(&mut o, &tf);
            }
        }
    }
    o.level = level_for(o.dist, o.level);
}

/// Which coastline and border layers the current level shows.
fn line_visibility(layers: Res<Layers>, o: Res<Orbit>, mut lines: Query<(&LineLayer, &mut Visibility)>) {
    for (l, mut vis) in &mut lines {
        let show = layers.outlines
            && match l.kind {
                LineKind::Fallback => true,
                LineKind::Coast | LineKind::Admin0 => (o.level == 0) == (l.detail == 0),
                LineKind::Admin1 => o.level == 2,
            };
        let v = shown(show);
        if *vis != v {
            *vis = v;
        }
    }
}

// ---------------------------------------------------------------- labels

/// Marker ring radius in pixels and label size in pixels for a place, by population.
fn place_class(pop: f32, capital: bool) -> (f32, f32) {
    let ring: f32 = if pop >= 5_000_000.0 {
        4.0
    } else if pop >= 1_000_000.0 {
        3.0
    } else if pop >= 100_000.0 {
        2.2
    } else {
        1.6
    };
    let size: f32 = if pop >= 5_000_000.0 {
        13.0
    } else if pop >= 1_000_000.0 {
        12.0
    } else {
        10.5
    };
    (if capital { ring.max(3.0) } else { ring }, if capital { size.max(12.0) } else { size })
}

struct Cand {
    def: usize,
    x: f32,
    y: f32,
    alpha: f32,
    prio: f32,
    size: f32,
    ring: f32,
    rw: f32,
    rh: f32,
    /// pixels the name starts right of the anchor (0 = centred on it)
    lead: f32,
    labelled: bool,
    world_per_px: f32,
}

/// Picks the names and city markers worth showing for the level and zoom,
/// drops names that would overlap on screen, and paints them on the sphere:
/// text along the great circle through each anchor, rings around cities.
/// Rebuilt only when the camera or the visible set changes.
#[allow(clippy::too_many_arguments)]
fn labels(
    cams: Query<(&Camera, &Transform), (With<Camera3d>, With<WidgetCamera>)>,
    o: Res<Orbit>,
    layers: Res<Layers>,
    input: Res<WidgetInput>,
    display: Res<Display>,
    palette: Res<Palette>,
    handles: Res<Handles>,
    options: Res<Options>,
    mut lab: ResMut<Labels>,
    mut meshes: ResMut<Assets<Mesh>>,
    mut images: ResMut<Assets<Image>>,
    mut mats: ResMut<Assets<StandardMaterial>>,
    mut label_q: Query<&mut Mesh3d, (With<LabelMesh>, Without<MarkerMesh>, Without<MarkerFill>)>,
    mut marker_q: Query<&mut Mesh3d, (With<MarkerMesh>, Without<LabelMesh>, Without<MarkerFill>)>,
    mut fill_q: Query<&mut Mesh3d, (With<MarkerFill>, Without<LabelMesh>, Without<MarkerMesh>)>,
) {
    let Ok((cam, cam_tf)) = cams.single() else { return };
    let (w, h) = (input.width as f32, input.height as f32);
    if lab.defs.is_empty() || lab.atlas.is_none() || w < 2.0 || h < 2.0 {
        return;
    }
    let cam_pos = cam_tf.translation;
    let moved = lab.last_cam.map_or(true, |c| c.distance(cam_pos) > 1e-5);
    if !moved && !lab.dirty {
        return;
    }
    let lab = &mut *lab;
    let atlas = lab.atlas.as_mut().unwrap();

    let mut visible: Vec<Cand> = Vec::new();
    if layers.labels {
        let view_dir = cam_pos.normalize();
        let z = zoom_for(o.dist);
        let gt = GlobalTransform::from(*cam_tf);
        let px_world = 2.0 * (FOV / 2.0).tan() / h; // world units per pixel per unit of distance
        let mut cands: Vec<Cand> = Vec::new();
        for (i, d) in lab.defs.iter().enumerate() {
            let allowed = matches!((o.level, d.kind), (0, 0) | (1, 0) | (1, 2) | (1, 3) | (1, 4) | (2, 1) | (2, 2) | (2, 3) | (2, 4));
            let wanted = match d.kind {
                0 => options.labels.countries,
                1 => options.labels.regions,
                4 => options.labels.airports,
                _ => options.labels.cities && d.pop >= options.labels.min_population,
            };
            if !allowed || !wanted {
                continue;
            }
            // Cities: rings for one more zoom level than names
            let (label_limit, marker_limit) = match d.kind {
                0 => (z + 1.2, z + 1.2),
                1 => (z + 0.8, z + 0.8),
                3 => (z + 1.5, z + 2.0),
                4 => (z + 2.0, z + 2.0),
                _ => (z + 0.4, z + 1.4),
            };
            if d.rank > marker_limit {
                continue;
            }
            let p = Vec3::from_array(d.pos);
            let dot = p.dot(view_dir);
            if dot < 0.12 {
                continue;
            }
            let Ok(v) = cam.world_to_viewport(&gt, p * R_TEXT) else { continue };
            if v.x < -80.0 || v.y < -40.0 || v.x > w + 80.0 || v.y > h + 40.0 {
                continue;
            }
            let (ring, size) = match d.kind {
                0 => (0.0, 15.0),
                1 => (0.0, 12.5),
                4 => ((3.0 + 0.9 * z).clamp(4.0, 10.0), 10.5), // airports grow with the zoom
                k => {
                    let (ring, size) = place_class(d.pop, k == 3);
                    (ring * (0.55 + 0.2 * z).clamp(0.9, 1.8), size)
                }
            };
            let size = size * display.scale * options.labels.size;
            let text_w = atlas.width(&d.text) * size / RASTER_PX;
            // a city's name sits to the right of its ring; other names are centred
            let lead = if ring > 0.0 { ring * display.scale + 3.0 } else { 0.0 };
            cands.push(Cand {
                def: i,
                x: v.x,
                y: v.y,
                alpha: ((dot - 0.12) / 0.25).clamp(0.0, 1.0),
                prio: match d.kind {
                    0 => 0.0,
                    1 => 10.0,
                    3 => 20.0,
                    4 => 40.0, // codes yield to city names
                    _ => 30.0,
                } + d.rank
                    - (d.pop.max(1.0).log10() * 0.1),
                size,
                ring: ring * display.scale,
                rw: text_w + 8.0,
                rh: size + 6.0,
                lead,
                labelled: d.rank <= label_limit,
                world_per_px: (p * R_TEXT).distance(cam_pos) * px_world,
            });
        }
        cands.sort_by(|a, b| a.prio.partial_cmp(&b.prio).unwrap_or(std::cmp::Ordering::Equal));
        let mut placed: Vec<[f32; 4]> = Vec::new();
        for mut c in cands {
            if c.labelled {
                let x0 = if c.lead > 0.0 { c.x + c.lead - 4.0 } else { c.x - c.rw / 2.0 };
                let r = [x0, c.y - c.rh / 2.0, x0 + c.rw, c.y + c.rh / 2.0];
                if placed.len() < 400 && !placed.iter().any(|p| r[0] < p[2] && r[2] > p[0] && r[1] < p[3] && r[3] > p[1]) {
                    placed.push(r);
                } else {
                    c.labelled = false; // the ring still shows where the city is
                }
            }
            if c.labelled || c.ring > 0.0 {
                visible.push(c);
            }
        }
    }

    let set: Vec<(usize, bool)> = visible.iter().map(|c| (c.def, c.labelled)).collect();
    if std::env::var_os("GLOBE_DEBUG").is_some() {
        eprintln!("labels: level {} z {:.2} dist {:.2} visible {} labelled {}", o.level, zoom_for(o.dist), o.dist, visible.len(), visible.iter().filter(|c| c.labelled).count());
    }
    let same = set == lab.last_set;
    lab.last_cam = Some(cam_pos);
    lab.dirty = false;
    if same && !moved && !visible.is_empty() {
        return;
    }
    lab.last_set = set;

    let shadow = lin(palette.fill.with_alpha(0.9));
    let mut tm = TextMesh::default();
    for pass in 0..2 {
        for c in visible.iter().filter(|c| c.labelled) {
            let d = &lab.defs[c.def];
            let k = c.size / RASTER_PX * c.world_per_px;
            let label = if d.kind == 0 { d.text.to_uppercase() } else { d.text.clone() };
            let p = Vec3::from_array(d.pos);
            // shift in raster pixels: half the width plus the lead puts the name's left edge right of the ring
            let lead = if c.lead > 0.0 { (atlas.width(&label) / 2.0) + c.lead * RASTER_PX / c.size } else { 0.0 };
            if pass == 0 {
                let color = [shadow[0], shadow[1], shadow[2], shadow[3] * c.alpha];
                tm.text(atlas, &label, p, k, R_TEXT - 0.0002, color, Vec2::new(lead + RASTER_PX * 0.06, -RASTER_PX * 0.06));
            } else {
                let base = lin(if d.kind == 4 { palette.airport } else { palette.text[d.kind.min(3) as usize] });
                tm.text(atlas, &label, p, k, R_TEXT, [base[0], base[1], base[2], 0.95 * c.alpha], Vec2::new(lead, 0.0));
            }
        }
    }
    let text_mesh = meshes.add(tm.mesh());
    for mut m in &mut label_q {
        m.0 = text_mesh.clone();
    }

    let ring_color = lin(palette.text[2]);
    let airport_color = lin(palette.airport);
    let outline = lin(palette.fill.with_alpha(0.9));
    let mut rings = Lines::default();
    let mut fills = Shapes::default();
    let disc = sphere::circle(14);
    let disc: [&[[f32; 2]]; 1] = [&disc];
    for c in visible.iter().filter(|c| c.ring > 0.0) {
        let d = &lab.defs[c.def];
        let p = Vec3::from_array(d.pos);
        let (e, n) = sphere::frame(p);
        let radius = c.ring * c.world_per_px;
        let rim_px = (0.16 * c.ring).clamp(0.8, 1.6) * display.scale;
        let rim = [outline[0], outline[1], outline[2], outline[3] * c.alpha];
        if d.kind == 4 {
            // airports: a disc with an airliner cut out of it once it is big enough
            let color = [airport_color[0], airport_color[1], airport_color[2], 0.95 * c.alpha];
            sphere::glyph_rim(&mut fills, &disc, p, n, e, radius, rim_px / c.ring, R_MARKER - 0.0002, rim);
            sphere::glyph(&mut fills, &disc, p, n, e, radius, R_MARKER, color);
            if c.ring >= 5.5 {
                let (nose, wing) = ((n + e).normalize(), (e - n).normalize());
                sphere::glyph(&mut fills, &sphere::AIRLINER, p, nose, wing, radius * 0.74, R_MARKER, rim);
            }
            continue;
        }
        // cities: a filled dot; capitals ringed
        let color = [ring_color[0], ring_color[1], ring_color[2], 0.95 * c.alpha];
        sphere::glyph_rim(&mut fills, &disc, p, n, e, radius, rim_px / c.ring, R_MARKER - 0.0002, rim);
        sphere::glyph(&mut fills, &disc, p, n, e, radius, R_MARKER, color);
        if d.kind == 3 {
            let r2 = radius * 1.9;
            rings.path((0..=20).map(|i| {
                let a = i as f32 / 20.0 * std::f32::consts::TAU;
                (p + (e * a.cos() + n * a.sin()) * r2).normalize() * R_MARKER
            }), color);
        }
    }
    let ring_mesh = meshes.add(rings.mesh());
    for mut m in &mut marker_q {
        m.0 = ring_mesh.clone();
    }
    let fill_mesh = meshes.add(fills.mesh());
    for mut m in &mut fill_q {
        m.0 = fill_mesh.clone();
    }

    if atlas.dirty {
        // A glyph outside the preloaded ranges: the material gets a fresh
        // texture asset, like the meshes
        atlas.dirty = false;
        let image = images.add(atlas.image());
        for h in &handles.text_mats {
            if let Some(m) = mats.get_mut(h) {
                m.base_color_texture = Some(image.clone());
            }
        }
    }
}

// ---------------------------------------------------------------- selection

/// A click picks the nearest drawn aircraft within a few pixels (or clears
/// the pick); a `select` control event with a hex does the same from outside.
#[allow(clippy::too_many_arguments)]
fn select(
    cams: Query<(&Camera, &Transform), (With<Camera3d>, With<WidgetCamera>)>,
    mut o: ResMut<Orbit>,
    layers: Res<Layers>,
    feed: Res<Feed>,
    display: Res<Display>,
    mut air: ResMut<Air>,
    sats: Res<Sats>,
    options: Res<Options>,
    mut sel: ResMut<Selection>,
    mut cam_rig: ResMut<CameraRig>,
    mut ui: ResMut<WidgetUi>,
    mut events: EventReader<WidgetEvent>,
) {
    // Some(Pick::None) clears; None means no pick happened this frame
    enum Pick {
        None,
        Aircraft(String),
        Sat(u32),
    }
    let mut pick: Option<Pick> = None;
    for e in events.read() {
        if e.id == "select" {
            pick = Some(match e.value.strip_prefix("sat:") {
                Some(name) => sats.by_name(name).map(|s| Pick::Sat(s.norad)).unwrap_or(Pick::None),
                None if e.value.is_empty() => Pick::None,
                None => Pick::Aircraft(e.value.to_lowercase()),
            });
        }
    }
    if let Some(click) = o.click.take() {
        let Ok((cam, cam_tf)) = cams.single() else { return };
        let gt = GlobalTransform::from(*cam_tf);
        let view_dir = cam_tf.translation.normalize();
        let mut best: Option<(f32, Pick)> = None;
        if layers.sats {
            for (s, st) in sats.list.iter().zip(&sats.styles).filter(|(s, st)| st.show && s.pos != Vec3::ZERO) {
                let _ = st;
                let Ok(v) = cam.world_to_viewport(&gt, s.pos) else { continue };
                let d = v.distance(click);
                if d < 18.0 && best.as_ref().map_or(true, |(bd, _)| d < *bd) {
                    best = Some((d, Pick::Sat(s.norad)));
                }
            }
        }
        if layers.air && !air.rows.is_empty() {
            let elapsed = (unix_now() - air.ts).clamp(0.0, 600.0) as f32;
            let ao = &options.aircraft;
            let floor = altitude_floor(o.dist, ao);
            let reach = (air_icon_px(o.dist, ao, display.scale) * 1.6).max(18.0);
            for a in air.rows.iter().filter(|a| moving(a, ao) && a.alt >= floor) {
                let (p, _) = reckon(a, elapsed);
                if p.dot(view_dir) < 0.15 {
                    continue;
                }
                let Ok(v) = cam.world_to_viewport(&gt, p * air_radius(a.alt)) else { continue };
                let d = v.distance(click);
                if d < reach && best.as_ref().map_or(true, |(bd, _)| d < *bd) {
                    best = Some((d, Pick::Aircraft(a.hex.clone())));
                }
            }
        }
        pick = Some(best.map(|(_, p)| p).unwrap_or(Pick::None));
    }
    let Some(pick) = pick else { return };
    let (hex, sat) = match pick {
        Pick::None => (None, None),
        Pick::Aircraft(h) => (Some(h), None),
        Pick::Sat(n) => (None, Some(n)),
    };
    if hex == sel.hex && sat == sel.sat {
        return;
    }
    if hex != sel.hex {
        sel.hex = hex.clone();
        sel.detail = None;
        sel.pos = None;
        sel.trail_dirty = true;
        sel.text_dirty = true;
        air.dirty = true; // the ring shows this frame, not at the next redraw
        feed.send(Cmd::Select(hex.clone()));
        match hex {
            Some(_) => {
                ui.info("flight", "", "\u{2026}");
            }
            None => {
                ui.remove("flight");
            }
        }
    }
    if sat != sel.sat {
        sel.sat = sat;
        match sat {
            Some(norad) => {
                let following = matches!(cam_rig.mode, View::Chase { norad: n, .. } if n == norad);
                ui.toggle("follow", "Follow", following);
                if let Some(s) = sats.find(norad) {
                    ui.info("sat", "", sat_summary(s));
                }
            }
            None => {
                ui.remove("sat").remove("follow");
                if matches!(cam_rig.mode, View::Chase { .. }) {
                    cam_rig.mode = View::Orbit;
                }
            }
        }
    }
}

fn sat_summary(s: &Sat) -> String {
    format!("{}  {} km  {:.2} km/s  {:.1}\u{b0}", s.name, s.alt_km.round() as i32, s.speed_kms, s.inclination)
}

fn flight_summary(d: &Detail) -> String {
    if !d.known {
        return "no data".into();
    }
    let mut parts: Vec<String> = Vec::new();
    if !d.flight.is_empty() {
        parts.push(d.flight.clone());
    } else if !d.reg.is_empty() {
        parts.push(d.reg.clone());
    }
    if !d.typ.is_empty() {
        parts.push(d.typ.clone());
    }
    match (&d.origin, &d.destination) {
        (Some(o), Some(t)) => parts.push(format!("{} \u{2192} {}", o.code, t.code)),
        (Some(o), None) => parts.push(format!("{} \u{2192} ?", o.code)),
        (None, Some(t)) => parts.push(format!("? \u{2192} {}", t.code)),
        _ => {}
    }
    if d.alt > 0.0 {
        parts.push(format!("FL{:03}", (d.alt / 100.0).round() as i32));
    }
    if d.gs > 0.0 {
        parts.push(format!("{} kt", d.gs.round() as i32));
    }
    parts.join("  ")
}

/// Draws what the clicked aircraft has: its path so far and the great
/// circle to its destination, its airports, and a caption beside it.
#[allow(clippy::too_many_arguments)]
fn selection_view(
    cams: Query<&Transform, (With<Camera3d>, With<WidgetCamera>)>,
    input: Res<WidgetInput>,
    display: Res<Display>,
    palette: Res<Palette>,
    mut sel: ResMut<Selection>,
    mut lab: ResMut<Labels>,
    mut meshes: ResMut<Assets<Mesh>>,
    mut trail_q: Query<&mut Mesh3d, (With<TrailMesh>, Without<SelText>)>,
    mut text_q: Query<&mut Mesh3d, (With<SelText>, Without<TrailMesh>)>,
) {
    if sel.trail_dirty {
        sel.trail_dirty = false;
        let mut lines = Lines::default();
        if let (Some(_), Some(d)) = (&sel.hex, &sel.detail) {
            let path = lin(palette.home.with_alpha(0.85));
            lines.surface_path(d.trail.iter().map(|p| (p.0, p.1)), R_TRAIL, path);
            if let (Some(o), Some(t)) = (&d.origin, &d.destination) {
                // the great circle between the airports, dashed
                let a = sphere::latlon(o.lat.to_radians(), o.lon.to_radians());
                let b = sphere::latlon(t.lat.to_radians(), t.lon.to_radians());
                let ang = a.dot(b).clamp(-1.0, 1.0).acos();
                if ang > 1e-4 {
                    let route = lin(palette.border.with_alpha(0.7));
                    let n = ((ang / 0.01).ceil() as usize).clamp(8, 400);
                    let at = |k: usize| {
                        let f = k as f32 / n as f32;
                        ((a * ((1.0 - f) * ang).sin() + b * (f * ang).sin()) / ang.sin()) * R_TRAIL
                    };
                    for k in (0..n).step_by(2) {
                        lines.seg(at(k), at(k + 1), route);
                    }
                }
            }
            for ap in [&d.origin, &d.destination].into_iter().flatten() {
                let p = sphere::latlon(ap.lat.to_radians(), ap.lon.to_radians());
                let (e, n) = sphere::frame(p);
                lines.path((0..=16).map(|i| {
                    let t = i as f32 / 16.0 * std::f32::consts::TAU;
                    (p + (e * t.cos() + n * t.sin()) * 0.004).normalize() * R_TRAIL
                }), path);
            }
        }
        let mesh = meshes.add(lines.mesh());
        for mut m in &mut trail_q {
            m.0 = mesh.clone();
        }
    }
    if sel.text_dirty {
        sel.text_dirty = false;
        let Ok(cam_tf) = cams.single() else { return };
        let Some(atlas) = lab.atlas.as_mut() else { return };
        let h = input.height.max(1) as f32;
        let px_world = 2.0 * (FOV / 2.0).tan() / h;
        let mut tm = TextMesh::default();
        let mut put = |atlas: &mut Atlas, text: &str, p: Vec3, size: f32, lead_px: f32, color: [f32; 4]| {
            let size = size * display.scale;
            let k = size / RASTER_PX * (p * R_TEXT).distance(cam_tf.translation) * px_world;
            let lead = atlas.width(text) / 2.0 + lead_px * display.scale * RASTER_PX / size;
            let shadow = lin(palette.fill.with_alpha(0.9));
            tm.text(atlas, text, p, k, R_TEXT - 0.0002, shadow, Vec2::new(lead + RASTER_PX * 0.06, -RASTER_PX * 0.06));
            tm.text(atlas, text, p, k, R_TEXT, color, Vec2::new(lead, 0.0));
        };
        if let (Some(_), Some((p, alt, flight))) = (&sel.hex, &sel.pos) {
            let name = if flight.is_empty() { sel.detail.as_ref().map(|d| d.reg.clone()).unwrap_or_default() } else { flight.clone() };
            let caption = if *alt > 0.0 { format!("{} FL{:03}", name, (alt / 100.0).round() as i32) } else { name };
            put(atlas, caption.trim(), *p, 12.0, 14.0, lin(palette.home));
        }
        if let (Some(_), Some(d)) = (&sel.hex, &sel.detail) {
            for ap in [&d.origin, &d.destination].into_iter().flatten() {
                let p = sphere::latlon(ap.lat.to_radians(), ap.lon.to_radians());
                put(atlas, &ap.code, p, 11.0, 8.0, lin(palette.text[2]));
            }
        }
        let mesh = meshes.add(tm.mesh());
        for mut m in &mut text_q {
            m.0 = mesh.clone();
        }
    }
}

// ---------------------------------------------------------------- satellites

fn sat_style(group: &str, palette: &Palette) -> (f32, Color) {
    match group {
        "stations" => (6.5, palette.home),
        "weather" => (4.5, palette.rim),
        "gnss" => (4.5, palette.air[3]),
        "science" => (4.5, palette.air[0]),
        "starlink" => (3.0, palette.grid.with_alpha(0.7)),
        _ => (4.5, palette.text[1]),
    }
}

/// Propagates every satellite to now and draws the ones the options show: a
/// cross facing the camera at true altitude, a track and a billboard name
/// for the ones the options pick (by default the ISS, Tiangong and Hubble)
/// and the clicked one, which also gets a ring and a live readout.
#[allow(clippy::too_many_arguments)]
fn satellites(
    cams: Query<&Transform, (With<Camera3d>, With<WidgetCamera>)>,
    layers: Res<Layers>,
    input: Res<WidgetInput>,
    display: Res<Display>,
    palette: Res<Palette>,
    sat_options: Res<config::SatOptions>,
    mut sats: ResMut<Sats>,
    sel: Res<Selection>,
    mut lab: ResMut<Labels>,
    mut ui: ResMut<WidgetUi>,
    mut meshes: ResMut<Assets<Mesh>>,
    mut sat_q: Query<&mut Mesh3d, (With<SatMesh>, Without<OrbitMesh>, Without<SatText>, Without<SatIcon>)>,
    mut orbit_q: Query<&mut Mesh3d, (With<OrbitMesh>, Without<SatMesh>, Without<SatText>, Without<SatIcon>)>,
    mut text_q: Query<&mut Mesh3d, (With<SatText>, Without<SatMesh>, Without<OrbitMesh>, Without<SatIcon>)>,
    mut icon_q: Query<&mut Mesh3d, (With<SatIcon>, Without<SatMesh>, Without<OrbitMesh>, Without<SatText>)>,
) {
    if !layers.sats || sats.list.is_empty() {
        if sats.drawn {
            // every group turned off: take the last markers, lines and names down
            sats.drawn = false;
            sats.tracks.clear();
            sats.track_set.clear();
            let empty_lines = meshes.add(Lines::default().mesh());
            let empty_text = meshes.add(TextMesh::default().mesh());
            let empty_icons = meshes.add(Shapes::default().mesh());
            for mut m in sat_q.iter_mut().chain(orbit_q.iter_mut()) {
                m.0 = empty_lines.clone();
            }
            for mut m in &mut icon_q {
                m.0 = empty_icons.clone();
            }
            for mut m in &mut text_q {
                m.0 = empty_text.clone();
            }
        }
        return;
    }
    sats.drawn = true;
    let Ok(cam_tf) = cams.single() else { return };
    let now = unix_now();
    for s in &mut sats.list {
        s.update(now);
    }
    let h = input.height.max(1) as f32;
    let px_world = 2.0 * (FOV / 2.0).tan() / h;
    let right = cam_tf.rotation * Vec3::X;
    let up = cam_tf.rotation * Vec3::Y;
    let cam = cam_tf.translation;
    // the icons lean in the view plane, and grow as the camera comes in
    let (lean_s, lean_c) = (35.0_f32.to_radians()).sin_cos();
    let (ir, iu) = (right * lean_c + up * lean_s, up * lean_c - right * lean_s);
    let zoom_scale = (1.0 + 0.3 * zoom_for(cam.length())).clamp(0.55, 2.4);
    let outline = lin(palette.fill.with_alpha(0.9));

    let mut marks = Lines::default();
    let mut icons = Shapes::default();
    let mut tm = TextMesh::default();
    let mut named: Vec<usize> = Vec::new();
    let mut tracked: Vec<usize> = Vec::new();
    for (i, (s, st)) in sats.list.iter().zip(&sats.styles).enumerate() {
        if s.pos == Vec3::ZERO || !st.show {
            continue;
        }
        let (px, group_color) = sat_style(&s.group, &palette);
        let color = st.color.unwrap_or(group_color);
        let selected = sel.sat == Some(s.norad);
        let wpp = s.pos.distance(cam) * px_world;
        let px = px * st.size * zoom_scale * display.scale;
        let size = px * wpp;
        let c = lin(color);
        if px >= 3.0 {
            let body = [c[0] * 0.5 + 0.5, c[1] * 0.5 + 0.5, c[2] * 0.5 + 0.5, c[3]];
            sphere::billboard_rim(&mut icons, &sphere::SATELLITE, s.pos, ir, iu, size, (0.14 * px).clamp(0.8, 1.6) * display.scale / px, outline);
            sphere::billboard(&mut icons, &sphere::SATELLITE[1..], s.pos, ir, iu, size, c);
            sphere::billboard(&mut icons, &sphere::SATELLITE[..1], s.pos, ir, iu, size, body);
        } else {
            // too small for a shape: a dot
            sphere::billboard(&mut icons, &[&sphere::DIAMOND], s.pos, right, up, size, c);
        }
        if selected {
            let r = size * 1.9;
            marks.path((0..=24).map(|k| {
                let t = k as f32 / 24.0 * std::f32::consts::TAU;
                s.pos + (right * t.cos() + up * t.sin()) * r
            }), lin(palette.home));
        }
        if selected || st.label {
            named.push(i);
        }
        if selected || st.track {
            tracked.push(i);
        }
    }
    let sat_mesh = meshes.add(marks.mesh());
    for mut m in &mut sat_q {
        m.0 = sat_mesh.clone();
    }
    let icon_mesh = meshes.add(icons.mesh());
    for mut m in &mut icon_q {
        m.0 = icon_mesh.clone();
    }

    if let Some(atlas) = lab.atlas.as_mut() {
        let shadow = lin(palette.fill.with_alpha(0.9));
        for &i in &named {
            let (s, st) = (&sats.list[i], &sats.styles[i]);
            let (px, group_color) = sat_style(&s.group, &palette);
            let (px, color) = (px * st.size, st.color.unwrap_or(group_color));
            let size = 11.0 * display.scale;
            let k = size / RASTER_PX * s.pos.distance(cam) * px_world;
            let lead = atlas.width(&s.name) / 2.0 + (px + 4.0) * display.scale * RASTER_PX / size;
            tm.text_at(atlas, &s.name, s.pos, right, up, k, shadow, Vec2::new(lead + RASTER_PX * 0.06, -RASTER_PX * 0.06));
            tm.text_at(atlas, &s.name, s.pos, right, up, k, lin(color), Vec2::new(lead, 0.0));
        }
    }
    let text_mesh = meshes.add(tm.mesh());
    for mut m in &mut text_q {
        m.0 = text_mesh.clone();
    }

    // Tracks drift with the Earth's rotation, so each is redone every ten
    // seconds, a few per frame, and the mesh only when one changed
    let wanted: Vec<u32> = tracked.iter().map(|&i| sats.list[i].norad).collect();
    let mut changed = sats.redraw || wanted != sats.track_set;
    sats.redraw = false;
    sats.tracks.retain(|n, _| wanted.contains(n));
    let mut budget = 6;
    let (points, orbits) = (sat_options.track.points.clamp(8, 2000), sat_options.track.orbits.clamp(0.05, 4.0));
    let mut due: Vec<usize> = tracked.iter().copied().filter(|&i| sats.tracks.get(&sats.list[i].norad).map_or(true, |(at, _)| now - at > 10.0)).collect();
    due.sort_by(|a, b| {
        let age = |i: &usize| sats.tracks.get(&sats.list[*i].norad).map_or(0.0, |(at, _)| *at);
        age(a).partial_cmp(&age(b)).unwrap_or(std::cmp::Ordering::Equal)
    });
    for i in due {
        if budget == 0 {
            break;
        }
        budget -= 1;
        let (norad, pts) = {
            let s = &sats.list[i];
            (s.norad, s.track(now, points, orbits))
        };
        sats.tracks.insert(norad, (now, pts));
        changed = true;
    }
    if changed {
        let mut tracks = Lines::default();
        for &i in &tracked {
            let (s, st) = (&sats.list[i], &sats.styles[i]);
            let Some((_, pts)) = sats.tracks.get(&s.norad) else { continue };
            let (_, group_color) = sat_style(&s.group, &palette);
            let color = st.track_color.or(st.color).unwrap_or(group_color);
            let alpha = if sel.sat == Some(s.norad) { st.track_alpha.max(0.85) } else { st.track_alpha };
            tracks.path(pts.iter().copied(), lin(color.with_alpha(alpha)));
        }
        let orbit_mesh = meshes.add(tracks.mesh());
        for mut m in &mut orbit_q {
            m.0 = orbit_mesh.clone();
        }
        sats.track_set = wanted;
    }
    if let Some(norad) = sel.sat {
        if now - sats.readout_at > 1.0 {
            sats.readout_at = now;
            if let Some(s) = sats.find(norad) {
                ui.info("sat", "", sat_summary(s));
            }
        }
    }
}

// ---------------------------------------------------------------- sun

fn unix_now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

/// Direction to the sun from the subsolar point (low-precision solar
/// position with the equation of time folded in through the right ascension).
fn sun_direction(unix: f64) -> Vec3 {
    let n = unix / 86400.0 - 10957.5; // days since J2000
    let rad = std::f64::consts::PI / 180.0;
    let l = (280.460 + 0.9856474 * n).rem_euclid(360.0);
    let g = (357.528 + 0.9856003 * n).rem_euclid(360.0) * rad;
    let lambda = (l + 1.915 * g.sin() + 0.020 * (2.0 * g).sin()) * rad;
    let eps = (23.439 - 0.0000004 * n) * rad;
    let dec = (eps.sin() * lambda.sin()).asin();
    let ra = (eps.cos() * lambda.sin()).atan2(lambda.cos()) / rad;
    let gmst = (280.46061837 + 360.98564736629 * n).rem_euclid(360.0);
    let lon = (ra - gmst + 540.0).rem_euclid(360.0) - 180.0;
    sphere::latlon(dec as f32, (lon * rad) as f32)
}

fn sun(time: Res<Time>, handles: Res<Handles>, mut mats: ResMut<Assets<GlobeMaterial>>, mut next: Local<f32>) {
    if time.elapsed_secs() < *next {
        return;
    }
    *next = time.elapsed_secs() + 30.0;
    if let Some(m) = mats.get_mut(&handles.material) {
        let s = sun_direction(unix_now());
        m.params.sun = Vec4::new(s.x, s.y, s.z, m.params.sun.w);
    }
}

// ---------------------------------------------------------------- aircraft

#[derive(Resource, Default)]
struct Air {
    rows: Vec<net::Aircraft>,
    ts: f64,
    dirty: bool,
    timer: f32,
    size: f32,
    /// recent reported positions per aircraft (frame time, unit vector), newest last
    history: HashMap<String, Vec<(f64, Vec3)>>,
}

fn altitude_band(alt_ft: f32, bands: &[f32; 3]) -> usize {
    bands.iter().position(|b| alt_ft < *b).unwrap_or(3)
}

/// An aircraft's position now and its heading direction, dead-reckoned
/// `elapsed` seconds past the frame time.
fn reckon(a: &net::Aircraft, elapsed: f32) -> (Vec3, Vec3) {
    let p = sphere::latlon(a.lat.to_radians(), a.lon.to_radians());
    let (e, n) = sphere::frame(p);
    let h = a.track.to_radians();
    let dir = n * h.cos() + e * h.sin();
    let theta = a.gs * elapsed / 3600.0 / 3440.065; // knots -> radians of arc
    let p = (p * theta.cos() + dir * theta.sin()).normalize();
    let (e, n) = sphere::frame(p);
    (p, (n * h.cos() + e * h.sin()).normalize())
}

fn moving(a: &net::Aircraft, o: &config::AircraftOptions) -> bool {
    a.gs >= o.min_speed || a.alt >= o.min_altitude // parked or taxiing aircraft would turn airports into hairballs
}

/// Zoomed out, low traffic is noise: the altitude below which aircraft are
/// left out rises with the distance.
fn altitude_floor(dist: f32, o: &config::AircraftOptions) -> f32 {
    if !o.declutter {
        return 0.0;
    }
    match dist {
        d if d > 3.0 => 24_000.0,
        d if d > 2.0 => 12_000.0,
        d if d > 1.5 => 4_000.0,
        _ => 0.0,
    }
}

/// Where an aircraft is drawn: a little above the surface, higher with altitude.
fn air_radius(alt: f32) -> f32 {
    R_AIR + (alt / 45_000.0).clamp(0.0, 1.2) * 0.012
}

/// Half size of the aircraft icon in pixels at a camera distance.
fn air_icon_px(dist: f32, o: &config::AircraftOptions, scale: f32) -> f32 {
    (3.5 + 1.5 * zoom_for(dist)).clamp(4.0, 14.0) * o.size * scale
}

fn thousands(n: usize) -> String {
    let s = n.to_string();
    let mut out = String::with_capacity(s.len() + s.len() / 3);
    for (i, c) in s.chars().enumerate() {
        if i > 0 && (s.len() - i) % 3 == 0 {
            out.push(' ');
        }
        out.push(c);
    }
    out
}

/// Aircraft as small plane glyphs, dead-reckoned from the service's frame
/// time and rebuilt a few times a second (and whenever the zoom changes
/// their size). Zoomed out only the high traffic shows; zoomed in each gets
/// a short tail of recent positions and its callsign.
#[allow(clippy::too_many_arguments)]
fn aircraft(
    cams: Query<(&Camera, &Transform), (With<Camera3d>, With<WidgetCamera>)>,
    time: Res<Time>,
    layers: Res<Layers>,
    o: Res<Orbit>,
    input: Res<WidgetInput>,
    display: Res<Display>,
    palette: Res<Palette>,
    options: Res<Options>,
    mut air: ResMut<Air>,
    mut sel: ResMut<Selection>,
    mut lab: ResMut<Labels>,
    mut meshes: ResMut<Assets<Mesh>>,
    mut ui: ResMut<WidgetUi>,
    mut air_q: Query<&mut Mesh3d, (With<AirMesh>, Without<AirText>, Without<AirFill>)>,
    mut fill_q: Query<&mut Mesh3d, (With<AirFill>, Without<AirMesh>, Without<AirText>)>,
    mut text_q: Query<&mut Mesh3d, (With<AirText>, Without<AirMesh>, Without<AirFill>)>,
) {
    if !layers.air || air.rows.is_empty() {
        return;
    }
    air.timer += time.delta_secs();
    // on-screen half size in pixels grows with the zoom: ~4 px far out, ~9 mid, ~13 close
    let px = air_icon_px(o.dist, &options.aircraft, display.scale);
    let rim_px = (0.14 * px).clamp(0.8, 1.8) * display.scale;
    let size = px * (o.dist - 1.0).max(0.02) * 2.0 * (FOV / 2.0).tan() / input.height.max(1) as f32;
    let moved = lab.last_cam.map_or(false, |c| c.distance(cams.single().map(|(_, t)| t.translation).unwrap_or(c)) > 1e-5);
    if !(air.dirty || air.timer > 0.2 || (size - air.size).abs() > size * 0.08 || (moved && o.dist < 1.35)) {
        return;
    }
    air.timer = 0.0;
    air.dirty = false;
    air.size = size;
    let Ok((cam, cam_tf)) = cams.single() else { return };
    let ao = &options.aircraft;
    let elapsed = (unix_now() - air.ts).clamp(0.0, 600.0) as f32;
    let colors = palette.air.map(|c| lin(c.with_alpha(0.9)));
    let highlight = lin(palette.home);
    let floor = altitude_floor(o.dist, ao);
    let tails = ao.tails && o.dist < 2.6;
    let captions = ao.labels && o.dist < 1.35;
    let (w, h) = (input.width as f32, input.height as f32);
    let gt = GlobalTransform::from(*cam_tf);
    let view_dir = cam_tf.translation.normalize();
    let px_world = 2.0 * (FOV / 2.0).tan() / h.max(1.0);
    let outline = lin(palette.fill.with_alpha(0.9));
    let mut lines = Lines::default();
    let mut fills = Shapes::default();
    let mut drawn = 0usize;
    let mut placed: Vec<[f32; 4]> = Vec::new();
    let mut tm = TextMesh::default();
    let shadow = lin(palette.fill.with_alpha(0.9));
    for a in &air.rows {
        if !moving(a, ao) || a.alt < floor {
            continue;
        }
        drawn += 1;
        let (p, dir) = reckon(a, elapsed);
        let side = p.cross(dir).normalize();
        let r = air_radius(a.alt);
        let band = altitude_band(a.alt, &ao.bands);
        let c = colors[band];
        let selected = sel.hex.as_deref() == Some(a.hex.as_str());
        // an airliner silhouette, sized for this aircraft's distance so every
        // one is the same on-screen size, with a dark rim for contrast
        let half = px * (p * r).distance(cam_tf.translation) * px_world;
        sphere::glyph_rim(&mut fills, &sphere::AIRLINER, p, dir, side, half, rim_px / px, r - 0.0002, outline);
        sphere::glyph(&mut fills, &sphere::AIRLINER, p, dir, side, half, r, if selected { highlight } else { c });
        if tails {
            if let Some(hist) = air.history.get(&a.hex) {
                let n = hist.len();
                if n >= 1 {
                    let mut prev = hist[0].1 * r;
                    for (k, (_, q)) in hist.iter().enumerate().skip(1).chain(std::iter::once((n, &(0.0, p)))) {
                        let next = q * r;
                        let fade = 0.08 + 0.32 * (k as f32 / n as f32);
                        lines.seg(prev, next, [c[0], c[1], c[2], fade]);
                        prev = next;
                    }
                }
            }
        }
        if selected {
            found_selected(&mut sel, &mut lines, p, r, half, a, highlight);
        }
        if captions && !selected && p.dot(view_dir) > 0.2 {
            if let Some(atlas) = lab.atlas.as_mut() {
                let name = if a.flight.is_empty() { a.hex.to_uppercase() } else { a.flight.clone() };
                if let Ok(v) = cam.world_to_viewport(&gt, p * r) {
                    let fs = 10.0 * display.scale;
                    let tw = atlas.width(&name) * fs / RASTER_PX;
                    let x0 = v.x + px * 1.2;
                    let rect = [x0, v.y - fs / 2.0 - 2.0, x0 + tw + 6.0, v.y + fs / 2.0 + 2.0];
                    if v.x > -40.0 && v.y > -20.0 && v.x < w + 40.0 && v.y < h + 20.0 && placed.len() < 120 && !placed.iter().any(|q| rect[0] < q[2] && rect[2] > q[0] && rect[1] < q[3] && rect[3] > q[1]) {
                        placed.push(rect);
                        let k = fs / RASTER_PX * (p * r).distance(cam_tf.translation) * px_world;
                        let lead = atlas.width(&name) / 2.0 + (px * 1.2 + 4.0 * display.scale) * RASTER_PX / fs;
                        tm.text(atlas, &name, p, k, r + 0.0015, shadow, Vec2::new(lead + RASTER_PX * 0.06, -RASTER_PX * 0.06));
                        tm.text(atlas, &name, p, k, r + 0.0017, [c[0], c[1], c[2], 0.95], Vec2::new(lead, 0.0));
                    }
                }
            }
        }
    }
    let mesh = meshes.add(lines.mesh());
    for mut m in &mut air_q {
        m.0 = mesh.clone();
    }
    let fill_mesh = meshes.add(fills.mesh());
    for mut m in &mut fill_q {
        m.0 = fill_mesh.clone();
    }
    let text_mesh = meshes.add(tm.mesh());
    for mut m in &mut text_q {
        m.0 = text_mesh.clone();
    }
    ui.info("aircraft", "\u{f001d}", thousands(drawn)); // nf-md-airplane
}

/// The ring around the clicked aircraft, and its spot for the caption.
fn found_selected(sel: &mut Selection, lines: &mut Lines, p: Vec3, r: f32, half: f32, a: &net::Aircraft, color: [f32; 4]) {
    let (e, n) = sphere::frame(p);
    let radius = half * 1.8;
    lines.path(
        (0..=24).map(|i| {
            let t = i as f32 / 24.0 * std::f32::consts::TAU;
            (p + (e * t.cos() + n * t.sin()) * radius).normalize() * r
        }),
        color,
    );
    if sel.pos.as_ref().map_or(true, |(q, _, _)| q.distance(p) > 1e-5) {
        sel.pos = Some((p, a.alt, a.flight.clone()));
        sel.text_dirty = true;
    }
}
