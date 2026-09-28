//! The space shuttle wallpaper's scene, without any GPU API: the shader, the
//! geometry it draws, the per-frame parameters and the list of draws. Shared
//! by the wallpaper renderer (`scripts/wallpaper/bins/spinning_globe`, wgpu 30
//! on a layer surface, which hosts every warm wallpaper scene) and the
//! selector's live preview (`bevy/apps/space_shuttle`, wgpu 24 inside
//! Quickshell), so both draw exactly the same picture.
//!
//! How to draw it: an 8-bit *non-sRGB* colour target cleared to [`BG`] and a
//! Depth32Float depth target cleared to 1.0 (usable as a texture too), with
//! one uniform buffer of [`Globals`] at group 0 binding 0 (vertex and
//! fragment). Every entry of [`DRAWS`] in order: its pipeline is described
//! by the entry's [`Blend`], [`DepthMode`] and [`Source`] (vertex layout and
//! buffer), and it draws [`SceneData::counts`]. The first [`PREPASS_DRAWS`]
//! go in a render pass of their own that stores the depth; the rest in a
//! second one with the depth attachment read-only, which the
//! [`DepthMode::Sampled`] draw also reads as a texture.
//!
//! Everything moves with the wall clock ([`Globals::at`]) and loops
//! seamlessly every [`loop_secs`], so the preview and the wallpaper show the
//! same pose at the same moment, across restarts.
mod model;

use std::f64::consts::TAU;
use std::time::{SystemTime, UNIX_EPOCH};

pub use bytemuck;
/// Catppuccin Mocha Base #1e1e2e, the clear colour (encoded 0..1), same as
/// the globe.
pub use globe_scene::BG;

pub const SHADER: &str = include_str!("shuttle.wgsl");

/// Two vec4s per instance: orbiter edges and stars.
#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub struct Instance {
    pub a: [f32; 4],
    pub b: [f32; 4],
}

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub struct Globals {
    pub viewport: [f32; 2],
    pub offset: [f32; 2],
    pub output: [f32; 2],
    pub time: f32,
    pub hidden: f32,
    pub earth: [f32; 4],
    pub earth_rot: [[f32; 4]; 3],
    pub model: [[f32; 4]; 3],
    pub proj: [f32; 4],
    pub depth: [f32; 4],
}

// --- Motion (all periods in seconds) -------------------------------------
//
// The orbiter flies an ISS-like circular orbit and the camera flies with it,
// so the Earth's disc stays put and its surface turns under the orbiter
// along the real ground track. The orbit's numbers give a repeating ground
// track: ORBITS orbits take exactly DAYS turns of the Earth relative to the
// orbit plane, so after that loop everything is back where it started.
// Every motion is a function of the loop's phase, taken from the wall clock
// (Unix seconds), so a moment always shows the same frame.

/// Simulated seconds per wall-clock second. 1 is real time: an orbit takes
/// 92.9 minutes and the loop 3.9 days.
pub const TIME_SCALE: f64 = 1.0;

/// 61 orbits in 4 turns of the Earth relative to the orbit plane: a 92.89
/// minute orbit, 419.8 km up (circular, with J2), the ISS's usual height.
const ORBITS: f64 = 61.0;
const DAYS: f64 = 4.0;
const INCLINATION_DEG: f64 = 51.6;
/// The Earth turns once per sidereal day; the orbit plane turns the other
/// way, from the Earth's oblateness (J2), this much per 86400 s at 419.8 km
/// and 51.6 degrees.
const SIDEREAL_DAY: f64 = 86_164.0905;
const NODE_DRIFT_DEG_PER_DAY: f64 = -4.9515;

/// The loop in simulated seconds: DAYS turns of the Earth relative to the
/// orbit plane (339,993 s, 3.94 days).
fn loop_sim_secs() -> f64 {
    DAYS / (1.0 / SIDEREAL_DAY - NODE_DRIFT_DEG_PER_DAY / 360.0 / 86_400.0)
}

/// The loop in wall-clock seconds.
pub fn loop_secs() -> f64 {
    loop_sim_secs() / TIME_SCALE
}

/// Where in the loop wall-clock time `t` is, 0..1.
fn loop_phase(t: f64) -> f64 {
    (t / loop_secs()).rem_euclid(1.0)
}

/// Wobble: yaw, pitch, roll (degrees, period), bob and drift (fraction of
/// the output, period). Each is rounded to whole cycles per loop; they're
/// otherwise incommensurate, so the wobble never visibly repeats.
const YAW: (f64, f64) = (7.0, 53.0);
const PITCH: (f64, f64) = (5.0, 41.0);
const ROLL: (f64, f64) = (9.0, 67.0);
const BOB: (f64, f64) = (0.012, 37.0);
const DRIFT: (f64, f64) = (0.008, 89.0);

/// The stars' twinkle runs on a clock of about this period (a whole number
/// of them per loop); each star twinkles a whole number of times per turn.
const TWINKLE_PERIOD: f64 = 1000.0;

/// Orbiter line width in output pixels at 1440 px tall (scales with height).
const LINE_WIDTH: f64 = 2.5;

/// Camera distance to the orbiter (m) and the depth range around it.
const DISTANCE: f64 = 100.0;
const DEPTH_HALF_RANGE: f64 = 30.0;

/// Seconds since the Unix epoch.
pub fn unix_secs(now: SystemTime) -> f64 {
    now.duration_since(UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64())
}

/// How far through its cycles a motion of about `period` seconds is at loop
/// phase `phase`, 0..1: the period is rounded to whole cycles per loop.
fn cycle(phase: f64, period: f64) -> f64 {
    (phase * (loop_secs() / period).round().max(1.0)).fract()
}

/// sin of a `period`-second cycle at loop phase `phase`.
fn wave(phase: f64, period: f64, offset: f64) -> f64 {
    (TAU * cycle(phase, period) + offset).sin()
}

type M3 = [[f64; 3]; 3];

fn mul(a: &M3, b: &M3) -> M3 {
    let mut r = [[0.0; 3]; 3];
    for i in 0..3 {
        for j in 0..3 {
            r[i][j] = (0..3).map(|k| a[i][k] * b[k][j]).sum();
        }
    }
    r
}

fn rot_x(a: f64) -> M3 {
    let (s, c) = a.sin_cos();
    [[1.0, 0.0, 0.0], [0.0, c, -s], [0.0, s, c]]
}

fn rot_y(a: f64) -> M3 {
    let (s, c) = a.sin_cos();
    [[c, 0.0, s], [0.0, 1.0, 0.0], [-s, 0.0, c]]
}

fn rot_z(a: f64) -> M3 {
    let (s, c) = a.sin_cos();
    [[c, -s, 0.0], [s, c, 0.0], [0.0, 0.0, 1.0]]
}

fn normalize(v: [f64; 3]) -> [f64; 3] {
    let l = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt();
    [v[0] / l, v[1] / l, v[2] / l]
}

fn cross(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
}

fn dot(a: [f64; 3], b: [f64; 3]) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

/// The orbiter's resting attitude in view space (x right, y up, z toward
/// the viewer): nose to the left, a little up and toward us, in a gentle
/// bank of about 20 degrees away from us: a hint of the belly (heat shield)
/// shows below and the payload bay doors along the near side. Columns are
/// the model's nose, top and starboard.
fn base_attitude() -> M3 {
    let nose = normalize([-0.95, 0.12, 0.28]);
    let up0 = [0.0, 0.94, -0.34];
    let d = dot(up0, nose);
    let up = normalize([up0[0] - d * nose[0], up0[1] - d * nose[1], up0[2] - d * nose[2]]);
    let starboard = cross(nose, up);
    [
        [nose[0], up[0], starboard[0]],
        [nose[1], up[1], starboard[1]],
        [nose[2], up[2], starboard[2]],
    ]
}

/// The Earth's rotation into the Earth's view space (x toward the viewer, y
/// right, z up) at loop phase `phase`. The camera flies with the orbiter:
/// up is the orbiter's zenith, so the top of the disc is the point below
/// it; the camera looks along the orbit plane's normal, from its north side,
/// so the orbiter flies to the left, as it faces. The orbit is circular,
/// its node where the Earth's 0 degrees east was at phase 0.
fn earth_in_view(phase: f64) -> M3 {
    let u = TAU * (phase * ORBITS).fract(); // from the ascending node
    let turn = TAU * (phase * DAYS).fract(); // the Earth, from the node
    let (si, ci) = INCLINATION_DEG.to_radians().sin_cos();
    let (su, cu) = u.sin_cos();
    // In a frame fixed to the node (z north, x toward the node).
    let normal = [0.0, -si, ci];
    let zenith = [cu, su * ci, su * si];
    let right = cross(zenith, normal); // behind the orbiter
    mul(&[normal, right, zenith], &rot_z(turn))
}

impl Globals {
    /// The scene for a `width` × `height` output at wall-clock time `now`.
    pub fn at(now: SystemTime, width: u32, height: u32) -> Self {
        Self::at_secs(unix_secs(now), width, height)
    }

    pub fn at_secs(t: f64, width: u32, height: u32) -> Self {
        let (w, h) = (width as f64, height as f64);

        // Earth: a big disc whose top peeks up from the bottom edge, its
        // highest point right of centre so the arc leans.
        let radius = (2.0 * w).max(2.6 * h);
        let earth_centre = (0.66 * w, 0.80 * h + radius);
        let phase = loop_phase(t);
        let earth = earth_in_view(phase);

        // Orbiter: resting attitude plus a slow three-axis wobble.
        let yaw = YAW.0.to_radians() * wave(phase, YAW.1, 0.0);
        let pitch = PITCH.0.to_radians() * wave(phase, PITCH.1, 1.3);
        let roll = ROLL.0.to_radians() * wave(phase, ROLL.1, 2.1);
        let attitude = mul(&mul(&rot_y(yaw), &rot_x(pitch)), &mul(&base_attitude(), &rot_x(roll)));

        let anchor = (
            0.44 * w + DRIFT.0 * w * wave(phase, DRIFT.1, 0.7),
            0.33 * h + BOB.0 * h * wave(phase, BOB.1, 0.0),
        );
        let near = DISTANCE - DEPTH_HALF_RANGE;
        let far = DISTANCE + DEPTH_HALF_RANGE;

        let row = |m: &M3, i: usize, w: f64| [m[i][0] as f32, m[i][1] as f32, m[i][2] as f32, w as f32];
        Globals {
            viewport: [width as f32, height as f32],
            offset: [0.0; 2],
            output: [width as f32, height as f32],
            time: (1000.0 * cycle(phase, TWINKLE_PERIOD)) as f32,
            hidden: 0.0,
            earth: [earth_centre.0 as f32, earth_centre.1 as f32, radius as f32, 0.0],
            earth_rot: [row(&earth, 0, 0.0), row(&earth, 1, 0.0), row(&earth, 2, 0.0)],
            model: [row(&attitude, 0, 0.0), row(&attitude, 1, 0.0), row(&attitude, 2, -DISTANCE)],
            proj: [(2.6 * h) as f32, anchor.0 as f32, anchor.1 as f32, (LINE_WIDTH * h / 1440.0).max(1.0) as f32],
            depth: [(1.0 / near) as f32, (1.0 / near - 1.0 / far) as f32, 0.0025, 0.0],
        }
    }

    /// The same scene, drawn into a `crop_w` × `crop_h` window centred on
    /// that output (what a centre crop of a screenshot would show).
    pub fn for_crop(self, crop_w: u32, crop_h: u32) -> Self {
        Globals {
            viewport: [crop_w as f32, crop_h as f32],
            offset: [
                ((self.output[0] - crop_w as f32) / 2.0).floor(),
                ((self.output[1] - crop_h as f32) / 2.0).floor(),
            ],
            ..self
        }
    }
}

// --- Draws ----------------------------------------------------------------

/// Colour blending: One/One with this operation; `DepthOnly` writes no
/// colour at all.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Blend {
    Add,
    Max,
    DepthOnly,
}

/// Depth test and write.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum DepthMode {
    /// Less, writes: the orbiter's surfaces.
    Prepass,
    /// LessEqual, no write: at depth 1, so the orbiter masks it.
    Test,
    /// Always, no write, and the depth target bound at group 1 binding 0
    /// (`texture_depth_2d`, fragment): the orbiter's edges, which do their
    /// own hidden-line test against it.
    Sampled,
}

/// Where a draw's vertices come from.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Source {
    /// Per-instance [`Instance`] buffer (stride 32: two Float32x4 at
    /// locations 0 and 1), 4-vertex triangle strips. `Coastlines` is
    /// Natural Earth 50m's, a segment per instance.
    Stars,
    ShuttleLines,
    Coastlines,
    /// Per-vertex Float32x4 at location 0 (stride 16), triangle list.
    Mesh,
    /// No buffer: the shader makes the vertices.
    EarthGrid,
    Atmosphere,
}

impl Source {
    pub const ALL: [Source; 6] = [Source::Stars, Source::ShuttleLines, Source::Coastlines, Source::Mesh, Source::EarthGrid, Source::Atmosphere];

    pub fn index(self) -> usize {
        Self::ALL.iter().position(|&s| s == self).unwrap()
    }

    pub fn instanced(self) -> bool {
        matches!(self, Source::Stars | Source::ShuttleLines | Source::Coastlines)
    }

    /// Triangle strip (else a list).
    pub fn strip(self) -> bool {
        self != Source::Mesh
    }
}

pub struct Draw {
    pub label: &'static str,
    pub vs: &'static str,
    pub fs: &'static str,
    pub source: Source,
    pub blend: Blend,
    pub depth: DepthMode,
}

/// In order. The orbiter's surfaces go first so everything behind it,
/// drawn at depth 1, is masked out.
pub const DRAWS: [Draw; 6] = [
    Draw { label: "orbiter depth", vs: "vs_mesh", fs: "fs_mesh", source: Source::Mesh, blend: Blend::DepthOnly, depth: DepthMode::Prepass },
    Draw { label: "stars", vs: "vs_star", fs: "fs_star", source: Source::Stars, blend: Blend::Add, depth: DepthMode::Test },
    Draw { label: "atmosphere", vs: "vs_atmosphere", fs: "fs_atmosphere", source: Source::Atmosphere, blend: Blend::Max, depth: DepthMode::Test },
    Draw { label: "earth grid", vs: "vs_earth_grid", fs: "fs_dot", source: Source::EarthGrid, blend: Blend::Max, depth: DepthMode::Test },
    Draw { label: "coastlines", vs: "vs_coast", fs: "fs_coast", source: Source::Coastlines, blend: Blend::Max, depth: DepthMode::Test },
    Draw { label: "orbiter edges", vs: "vs_shuttle", fs: "fs_line", source: Source::ShuttleLines, blend: Blend::Max, depth: DepthMode::Sampled },
];

/// How many of [`DRAWS`] fill the depth target, in a pass of their own.
pub const PREPASS_DRAWS: usize = 1;

const GRID_DOTS: u32 = 11 * 3600 + 24 * 1800;
const ATMO_SEGMENTS: u32 = 512;
const STAR_COUNT: usize = 1100;

/// Vertex data, built once.
pub struct SceneData {
    stars: Vec<Instance>,
    shuttle_lines: Vec<Instance>,
    coastlines: Vec<Instance>,
    mesh: Vec<[f32; 4]>,
}

impl SceneData {
    pub fn build() -> Self {
        let orbiter = model::build();
        SceneData { stars: build_stars(), shuttle_lines: orbiter.lines, coastlines: build_coastlines(), mesh: orbiter.mesh }
    }

    /// The vertex buffer contents for a source, if it has one.
    pub fn bytes(&self, source: Source) -> Option<&[u8]> {
        match source {
            Source::Stars => Some(bytemuck::cast_slice(&self.stars)),
            Source::ShuttleLines => Some(bytemuck::cast_slice(&self.shuttle_lines)),
            Source::Coastlines => Some(bytemuck::cast_slice(&self.coastlines)),
            Source::Mesh => Some(bytemuck::cast_slice(&self.mesh)),
            Source::EarthGrid | Source::Atmosphere => None,
        }
    }

    /// (vertices, instances) to draw.
    pub fn counts(&self, source: Source) -> (u32, u32) {
        match source {
            Source::Stars => (4, self.stars.len() as u32),
            Source::ShuttleLines => (4, self.shuttle_lines.len() as u32),
            Source::Coastlines => (4, self.coastlines.len() as u32),
            Source::Mesh => (self.mesh.len() as u32, 1),
            Source::EarthGrid => (4, GRID_DOTS),
            Source::Atmosphere => (2 * (ATMO_SEGMENTS + 1), 1),
        }
    }
}

/// Natural Earth 1:50m coastlines (public domain), baked by
/// tools/coastline.py. The globe wallpaper keeps its own outlines.
const COASTLINE: &[u8] = include_bytes!("coastline.bin");

/// The coastlines, one instance per segment: its ends on the unit sphere
/// (x toward 0°E on the equator, z to the north pole), w unused.
fn build_coastlines() -> Vec<Instance> {
    let mut words = COASTLINE.chunks_exact(4).map(|c| [c[0], c[1], c[2], c[3]]);
    let mut u32_ = || u32::from_le_bytes(words.next().unwrap());
    let polylines = u32_();
    let mut segments = Vec::new();
    for _ in 0..polylines {
        let n = u32_();
        let mut prev: Option<(f64, [f32; 4])> = None;
        for _ in 0..n {
            let lon = f32::from_bits(u32_()) as f64;
            let lat = f32::from_bits(u32_()) as f64;
            let (lon_r, lat_r) = (lon.to_radians(), lat.to_radians());
            let p = [
                (lat_r.cos() * lon_r.cos()) as f32,
                (lat_r.cos() * lon_r.sin()) as f32,
                lat_r.sin() as f32,
                0.0,
            ];
            // Never across the antimeridian (Natural Earth splits there).
            if let Some((_, a)) = prev.filter(|(l, _)| (l - lon).abs() < 180.0) {
                segments.push(Instance { a, b: p });
            }
            prev = Some((lon, p));
        }
    }
    segments
}

/// A fixed, seeded star field in 0..1 output coordinates.
fn build_stars() -> Vec<Instance> {
    let mut seed: u64 = 0x5eed_0f_5ace;
    let mut rand = move || {
        // splitmix64
        seed = seed.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = seed;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        ((z ^ (z >> 31)) >> 11) as f32 / (1u64 << 53) as f32
    };
    (0..STAR_COUNT)
        .map(|_| {
            let (x, y) = (rand(), rand());
            let m = rand();
            let brightness = 0.14 + 0.6 * m * m * m;
            let big = rand() > 0.965;
            let cycles = 45.0 + (rand() * 140.0).floor(); // 5.5-22 s periods
            let phase = rand() * std::f32::consts::TAU;
            let depth = 0.2 + 0.35 * rand();
            let c = rand();
            let colour = if c < 0.62 { 0.0 } else if c < 0.82 { 1.0 } else if c < 0.93 { 2.0 } else { 3.0 };
            Instance {
                a: [x, y, if big { brightness.max(0.45) } else { brightness }, cycles],
                b: [phase, depth, if big { 1.0 } else { 0.0 }, colour],
            }
        })
        .collect()
}
