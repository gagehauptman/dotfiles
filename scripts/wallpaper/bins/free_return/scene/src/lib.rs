//! The free-return wallpaper's scene, without any GPU API: the shader, the
//! geometry it draws, the per-frame parameters and the list of draws. Shared
//! by the wallpaper renderer (`scripts/wallpaper/bins/spinning_globe`, wgpu 30
//! on a layer surface, which hosts every warm wallpaper scene) and the
//! selector's live preview (`bevy/apps/free_return`, wgpu 24 inside
//! Quickshell), so both draw exactly the same picture.
//!
//! The Earth-Moon system in the frame turning with the Moon (the circular
//! restricted three-body problem, `cr3bp`): the five Lagrange points, the
//! zero-velocity curves through L1, L2 and L3 and round L4/L5 as faint
//! dots, the Moon's orbit, and an Apollo-style free-return trajectory, the
//! figure eight round the far side of the Moon, flown out of a parking orbit
//! by a spacecraft that draws its path as it goes over the faint planned one.
//!
//! How to draw it: an 8-bit *non-sRGB* colour target cleared to [`BG`], no
//! depth, one uniform buffer of [`Globals`] at group 0 binding 0 (vertex and
//! fragment). Every entry of [`DRAWS`] in order, in one render pass: its
//! pipeline is described by the entry's [`Blend`] and [`Source`] (vertex
//! layout and buffer), and it draws [`SceneData::counts`].
//!
//! Everything moves with the wall clock ([`Globals::at`]) and loops every
//! [`LOOP_SECS`], so the preview and the wallpaper show the same moment of
//! the flight, across restarts.
pub mod cr3bp;

use std::time::{SystemTime, UNIX_EPOCH};

use cr3bp::{EARTH_RADIUS, MOON_RADIUS, MU, TIME_SCALE_HOURS};

pub use bytemuck;
/// Catppuccin Mocha Base #1e1e2e, the clear colour (encoded 0..1), same as
/// the globe.
pub use globe_scene::BG;

pub const SHADER: &str = include_str!("free_return.wgsl");

/// Two vec4s per instance: trajectory segments, marks and stars.
#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub struct Instance {
    pub a: [f32; 4],
    pub b: [f32; 4],
}

/// One vec4 per dot: position (frame units), intensity, style.
#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub struct Dot(pub [f32; 4]);

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub struct Globals {
    pub viewport: [f32; 2],
    pub offset: [f32; 2],
    pub output: [f32; 2],
    /// Twinkle clock, 0..1000 s, wrapping seamlessly with the loop.
    pub time: f32,
    /// Mission elapsed time, hours from TLI.
    pub met: f32,
    /// Barycentre x, y (output px), px per Earth-Moon distance, line width px.
    pub frame: [f32; 4],
    /// Spacecraft x, y (output px), its brightness, the flown path's
    /// brightness (fades out at the end of the loop).
    pub craft: [f32; 4],
    /// Earth radius px, Moon radius px, mark scale (px per glyph unit), 0.
    pub bodies: [f32; 4],
}

// --- Motion ---------------------------------------------------------------
//
// One loop: the flight from the parking orbit to entry in FLY_SECS, the
// finished figure eight held for HOLD_SECS, then the flown path fades back
// into the planned one over FADE_SECS and the next flight begins. Mission
// time runs linearly with the wall clock, so the spacecraft keeps the real
// flight's pace: quick through perigee and the flyby, slow near apogee.

pub const FLY_SECS: f64 = 840.0;
pub const HOLD_SECS: f64 = 45.0;
pub const FADE_SECS: f64 = 15.0;
pub const LOOP_SECS: f64 = FLY_SECS + HOLD_SECS + FADE_SECS;

/// Trajectory line width in output pixels at 1440 px tall (scales with height).
const LINE_WIDTH: f64 = 1.6;

/// Seconds since the Unix epoch.
pub fn unix_secs(now: SystemTime) -> f64 {
    now.duration_since(UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64())
}

/// Where the frame's origin goes and how big it is, for a `w` × `h` output:
/// the barycentre a little left of centre so the whole L3..L2 span is
/// centred, L4 and L5 inside the top and bottom with room for their labels.
fn layout(w: f64, h: f64) -> (f64, f64, f64) {
    let scale = (0.44 * h).min(w / 2.5);
    (0.5 * w - 0.075 * scale, 0.5 * h, scale)
}

/// Vertex data, built once, and the trajectory for placing the spacecraft.
pub struct SceneData {
    stars: Vec<Instance>,
    trajectory: Vec<Instance>,
    marks: Vec<Instance>,
    dots: Vec<Dot>,
    /// (x, y, hours from TLI), in flight order.
    path: Vec<[f64; 3]>,
}

impl Globals {
    /// The scene for a `width` × `height` output at wall-clock time `now`.
    pub fn at(now: SystemTime, width: u32, height: u32, data: &SceneData) -> Self {
        Self::at_secs(unix_secs(now), width, height, data)
    }

    pub fn at_secs(t: f64, width: u32, height: u32, data: &SceneData) -> Self {
        let (w, h) = (width as f64, height as f64);
        let (cx, cy, scale) = layout(w, h);
        let into_loop = t.rem_euclid(LOOP_SECS);

        let (start, end) = (data.path[0][2], data.path[data.path.len() - 1][2]);
        let met = start + (end - start) * (into_loop / FLY_SECS).min(1.0);
        let flying = into_loop < FLY_SECS;
        let fade = if into_loop < FLY_SECS + HOLD_SECS { 1.0 } else { 1.0 - (into_loop - FLY_SECS - HOLD_SECS) / FADE_SECS };

        let (x, y) = data.position(met);
        Globals {
            viewport: [width as f32, height as f32],
            offset: [0.0; 2],
            output: [width as f32, height as f32],
            time: (1000.0 * into_loop / LOOP_SECS) as f32,
            met: met as f32,
            frame: [cx as f32, cy as f32, scale as f32, (LINE_WIDTH * h / 1440.0).max(1.0) as f32],
            craft: [(cx + x * scale) as f32, (cy - y * scale) as f32, if flying { 1.0 } else { 0.0 }, fade as f32],
            bodies: [
                (EARTH_RADIUS * scale).max(3.0) as f32,
                (MOON_RADIUS * scale).max(1.5) as f32,
                (1.5 * h / 1440.0) as f32,
                0.0,
            ],
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

/// Colour blending: One/One with this operation.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Blend {
    Add,
    Max,
}

/// Where a draw's vertices come from.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Source {
    /// Per-instance [`Instance`] buffer (stride 32: two Float32x4 at
    /// locations 0 and 1), 4-vertex triangle strips.
    Stars,
    Trajectory,
    Marks,
    /// Per-instance [`Dot`] buffer (stride 16: one Float32x4 at location 0),
    /// 4-vertex triangle strips.
    Dots,
    /// No buffer: the shader makes the vertices (Earth and Moon, the
    /// spacecraft).
    Bodies,
    Craft,
}

impl Source {
    pub const ALL: [Source; 6] = [Source::Stars, Source::Trajectory, Source::Marks, Source::Dots, Source::Bodies, Source::Craft];

    pub fn index(self) -> usize {
        Self::ALL.iter().position(|&s| s == self).unwrap()
    }

    /// Instance stride in bytes (0: no buffer).
    pub fn stride(self) -> u64 {
        match self {
            Source::Stars | Source::Trajectory | Source::Marks => 32,
            Source::Dots => 16,
            Source::Bodies | Source::Craft => 0,
        }
    }
}

pub struct Draw {
    pub label: &'static str,
    pub vs: &'static str,
    pub fs: &'static str,
    pub source: Source,
    pub blend: Blend,
}

/// In order, all triangle strips, one pass.
pub const DRAWS: [Draw; 7] = [
    Draw { label: "stars", vs: "vs_star", fs: "fs_star", source: Source::Stars, blend: Blend::Add },
    Draw { label: "dots", vs: "vs_dot", fs: "fs_dot", source: Source::Dots, blend: Blend::Max },
    Draw { label: "marks", vs: "vs_mark", fs: "fs_line", source: Source::Marks, blend: Blend::Max },
    Draw { label: "planned path", vs: "vs_planned", fs: "fs_line", source: Source::Trajectory, blend: Blend::Max },
    Draw { label: "flown path", vs: "vs_flown", fs: "fs_line", source: Source::Trajectory, blend: Blend::Max },
    Draw { label: "earth and moon", vs: "vs_body", fs: "fs_body", source: Source::Bodies, blend: Blend::Max },
    Draw { label: "spacecraft", vs: "vs_craft", fs: "fs_craft", source: Source::Craft, blend: Blend::Max },
];

const STAR_COUNT: usize = 900;

/// Dot styles (the shader's palette): colour index + 4 for a 3x3 glow dot.
const TEAL: f32 = 0.0;
const SAPPHIRE: f32 = 1.0;
const LAVENDER: f32 = 2.0;
const BIG: f32 = 4.0;

/// Dot spacing along curves, in Earth-Moon distances (~4 px at 1440 tall).
const DOT_SPACING: f64 = 0.0065;

impl SceneData {
    pub fn build() -> Self {
        let samples = cr3bp::free_return();
        let path: Vec<[f64; 3]> = samples.iter().map(|s| [s.x, s.y, s.t * TIME_SCALE_HOURS]).collect();
        let trajectory = path
            .windows(2)
            .map(|w| Instance {
                a: [w[0][0] as f32, w[0][1] as f32, w[0][2] as f32, 0.0],
                b: [w[1][0] as f32, w[1][1] as f32, w[1][2] as f32, 0.0],
            })
            .collect();
        SceneData { stars: build_stars(), trajectory, marks: build_marks(), dots: build_dots(&path), path }
    }

    /// The spacecraft's position (frame units) `met` hours from TLI.
    pub fn position(&self, met: f64) -> (f64, f64) {
        let i = self.path.partition_point(|p| p[2] <= met).clamp(1, self.path.len() - 1);
        let (a, b) = (self.path[i - 1], self.path[i]);
        let f = if b[2] > a[2] { ((met - a[2]) / (b[2] - a[2])).clamp(0.0, 1.0) } else { 1.0 };
        (a[0] + f * (b[0] - a[0]), a[1] + f * (b[1] - a[1]))
    }

    /// The vertex buffer contents for a source, if it has one.
    pub fn bytes(&self, source: Source) -> Option<&[u8]> {
        match source {
            Source::Stars => Some(bytemuck::cast_slice(&self.stars)),
            Source::Trajectory => Some(bytemuck::cast_slice(&self.trajectory)),
            Source::Marks => Some(bytemuck::cast_slice(&self.marks)),
            Source::Dots => Some(bytemuck::cast_slice(&self.dots)),
            Source::Bodies | Source::Craft => None,
        }
    }

    /// (vertices, instances) to draw.
    pub fn counts(&self, source: Source) -> (u32, u32) {
        match source {
            Source::Stars => (4, self.stars.len() as u32),
            Source::Trajectory => (4, self.trajectory.len() as u32),
            Source::Marks => (4, self.marks.len() as u32),
            Source::Dots => (4, self.dots.len() as u32),
            Source::Bodies => (4, 2),
            Source::Craft => (4, 1),
        }
    }
}

/// The faint dotted layer: the zero-velocity curves at the Jacobi constants
/// of L1, L2 and L3 and one just above L4/L5's (their tadpoles), the Moon's
/// orbit, and a tick on the planned path every 12 hours of the flight.
fn build_dots(path: &[[f64; 3]]) -> Vec<Dot> {
    let mut dots = Vec::new();
    let points = cr3bp::lagrange_points();
    let level = |p: (f64, f64)| cr3bp::two_omega(p.0, p.1);
    let (l1, l2, l3, l4) = (level(points[0]), level(points[1]), level(points[2]), level(points[3]));
    let curves = [(l1, 0.40), (l2, 0.32), (l3, 0.27), (l4 + 0.25 * (l3 - l4), 0.23)];
    for (c, k) in curves {
        for line in cr3bp::contour(c, (-1.6, 1.6), (-1.2, 1.2), 0.0025) {
            for (x, y) in cr3bp::resample(&line, DOT_SPACING) {
                dots.push(Dot([x as f32, y as f32, k, TEAL]));
            }
        }
    }

    let n = (std::f64::consts::TAU / DOT_SPACING) as usize;
    for i in 0..n {
        let a = std::f64::consts::TAU * i as f64 / n as f64;
        dots.push(Dot([(-MU + a.cos()) as f32, a.sin() as f32, 0.22, SAPPHIRE]));
    }

    let mut next = 12.0;
    for w in path.windows(2) {
        while w[1][2] >= next && w[0][2] < next {
            let f = (next - w[0][2]) / (w[1][2] - w[0][2]);
            let (x, y) = (w[0][0] + f * (w[1][0] - w[0][0]), w[0][1] + f * (w[1][1] - w[0][1]));
            // Days brighter than half days.
            let k = if (next / 24.0).fract() == 0.0 { 0.5 } else { 0.3 };
            dots.push(Dot([x as f32, y as f32, k, LAVENDER + BIG]));
            next += 12.0;
        }
    }
    dots
}

/// Stroke glyphs on a 4 × 6 grid (y down): L and the digits 1-5.
const GLYPH_L: &[[f32; 4]] = &[[0.0, 0.0, 0.0, 6.0], [0.0, 6.0, 3.5, 6.0]];
const GLYPH_DIGITS: [&[[f32; 4]]; 5] = [
    &[[1.0, 1.2, 2.2, 0.0], [2.2, 0.0, 2.2, 6.0]],
    &[[0.2, 1.2, 1.2, 0.0], [1.2, 0.0, 2.8, 0.0], [2.8, 0.0, 3.8, 1.0], [3.8, 1.0, 3.8, 2.2], [3.8, 2.2, 0.0, 6.0], [0.0, 6.0, 4.0, 6.0]],
    &[
        [0.0, 0.0, 4.0, 0.0],
        [4.0, 0.0, 1.8, 2.6],
        [1.8, 2.6, 2.8, 2.6],
        [2.8, 2.6, 4.0, 3.7],
        [4.0, 3.7, 4.0, 5.0],
        [4.0, 5.0, 3.0, 6.0],
        [3.0, 6.0, 1.0, 6.0],
        [1.0, 6.0, 0.0, 5.0],
    ],
    &[[3.0, 6.0, 3.0, 0.0], [3.0, 0.0, 0.0, 4.2], [0.0, 4.2, 4.0, 4.2]],
    &[
        [4.0, 0.0, 0.3, 0.0],
        [0.3, 0.0, 0.0, 2.6],
        [0.0, 2.6, 2.8, 2.6],
        [2.8, 2.6, 4.0, 3.7],
        [4.0, 3.7, 4.0, 5.0],
        [4.0, 5.0, 3.0, 6.0],
        [3.0, 6.0, 0.0, 6.0],
    ],
];

/// The Lagrange points: a small cross each and its name beside it. A stroke
/// is (point x, y in frame units, its offset from there in glyph units),
/// (offset of the other end, intensity, 0).
fn build_marks() -> Vec<Instance> {
    let mut marks = Vec::new();
    for (i, &(x, y)) in cr3bp::lagrange_points().iter().enumerate() {
        let (x, y) = (x as f32, y as f32);
        let mut stroke = |x0: f32, y0: f32, x1: f32, y1: f32, k: f32| {
            marks.push(Instance { a: [x, y, x0, y0], b: [x1, y1, k, 0.0] });
        };
        stroke(-3.0, 0.0, 3.0, 0.0, 0.8);
        stroke(0.0, -3.0, 0.0, 3.0, 0.8);
        // The label to the lower right, clear of the curves' crossings.
        let (lx, ly) = (4.0, 3.5);
        for s in GLYPH_L {
            stroke(lx + s[0], ly + s[1], lx + s[2], ly + s[3], 0.55);
        }
        let dx = lx + 5.5;
        for s in GLYPH_DIGITS[i] {
            stroke(dx + s[0], ly + s[1], dx + s[2], ly + s[3], 0.55);
        }
    }
    marks
}

/// A fixed, seeded star field in 0..1 output coordinates (as the shuttle's,
/// sparser and dimmer: the diagram is the subject).
fn build_stars() -> Vec<Instance> {
    let mut seed: u64 = 0xf2ee_2e70_2a11;
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
            let brightness = 0.10 + 0.45 * m * m * m;
            let big = rand() > 0.975;
            let cycles = 50.0 + (rand() * 130.0).floor(); // 5-18 s periods
            let phase = rand() * std::f32::consts::TAU;
            let depth = 0.2 + 0.35 * rand();
            let c = rand();
            let colour = if c < 0.62 { 0.0 } else if c < 0.82 { 1.0 } else if c < 0.93 { 2.0 } else { 3.0 };
            Instance {
                a: [x, y, if big { brightness.max(0.4) } else { brightness }, cycles],
                b: [phase, depth, if big { 1.0 } else { 0.0 }, colour],
            }
        })
        .collect()
}
