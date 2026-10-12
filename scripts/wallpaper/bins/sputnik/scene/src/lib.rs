//! The Sputnik 1 wallpaper's scene, without any GPU API: the shader, the
//! orbit (a Kepler propagation of the real elements with J2 precession), the
//! camera, the poster-style layout and text, and the per-frame parameters.
//! Drawn by the wallpaper renderer (`scripts/wallpaper/bins/spinning_globe`,
//! wgpu on a layer surface), which only has to follow [`Frame`]:
//!
//! 1. one full-screen quad (`fs_sky`): gradient, stars, searchlight beam and
//!    the printed Earth, sampling the land mask (R8, [`SceneData::land`]);
//! 2. the static lines ([`SceneData::static_lines`]: the orbit ring and the
//!    decorative loops), 4-vertex strips, one [`Line`] instance each;
//! 3. `Frame::lines[..ground]` (the ground track), then the satellite's ball
//!    (`vs_ball`, 4 vertices, no buffer), then `Frame::lines[ground..]`
//!    (antennas and streaks);
//! 4. the text, one [`Glyph`] instance each, sampling the font atlas.
//!
//! The target is an 8-bit non-sRGB colour; every draw is premultiplied-alpha
//! "over" blended except the sky, which replaces. No depth.
use std::collections::HashMap;
use std::f64::consts::{PI, TAU};
use std::time::{SystemTime, UNIX_EPOCH};

use ab_glyph::{point, Font, FontRef, PxScale, ScaleFont, VariableFont};

pub use bytemuck;

pub const SHADER: &str = include_str!("sputnik.wgsl");
/// Natural Earth coastlines (public domain), shared with the shuttle scene.
const COASTLINE: &[u8] = include_bytes!("../../../space_shuttle/scene/src/coastline.bin");

pub const BG: [f64; 3] = [0.045, 0.07, 0.30];
pub const LAND_W: u32 = 2048;
pub const LAND_H: u32 = 1024;
/// The poster's continents: the coastlines simplified (Douglas-Peucker, this
/// many degrees) into cut-paper shapes, and islands smaller than this many
/// square degrees left out, so the Earth reads as printed, not mapped.
const COAST_TOLERANCE: f64 = 0.8;
const MIN_ISLAND: f64 = 6.0;

// --- Real data ---------------------------------------------------------------

const RE: f64 = 6371.0;
const MU: f64 = 398_600.4418;
const J2: f64 = 1.08263e-3;
const PERIGEE_ALT: f64 = 215.0;
const APOGEE_ALT: f64 = 939.0;
const INCLINATION_DEG: f64 = 65.1;
/// 1957-10-04 19:28:34 UTC, the launch from Baikonur (45.9 N, 63.3 E).
const LAUNCH_YMD: (i64, i64, i64) = (1957, 10, 4);
const LAUNCH_HMS: f64 = 19.0 * 3600.0 + 28.0 * 60.0 + 34.0;
const SITE_LAT_DEG: f64 = 45.92;
const SITE_LON_DEG: f64 = 63.34;

// --- Showing it ---------------------------------------------------------------

/// Simulated seconds per wall-clock second: an orbit takes ~8 min, so the
/// Earth turns under the chase camera at a calm ~10 px/s.
const WARP: f64 = 12.0;
/// The scene runs on the wall clock (Unix time) and loops every this many
/// seconds (48 simulated days at WARP), so the wallpaper, the selector's card
/// and the lock screen all show the same moment of the flight, across
/// restarts, and the shader's f32 time keeps its precision.
const LOOP_SECS: f64 = 4.0 * 86_400.0;
/// The randomness (phases, loops, streaks) when not SPUTNIK_SEED: fixed, so
/// every instance draws the same poster.
const CLOCK_SEED: u64 = 1957_10_04;
/// The altitudes above the surface are drawn this many times too high so the
/// orbit clears the globe's limb; every readout shows the real ones.
const ALT_EXAGGERATION: f64 = 3.6;
const TAN_HALF_FOV: f64 = 0.3057; // 34 degrees vertical
/// Where the satellite sits: x as a fraction of the half-width (capped at
/// 21:9), y in half-heights up from the centre.
const SAT_AT: (f64, f64) = (0.26, 0.30);
/// The camera, from the satellite, in Earth radii: back along its flight,
/// up, and out to the side of the orbit; it aims ahead and down by CAM_AIM.
const CAM_OFF: (f64, f64, f64) = (0.30, -0.02, -1.35);
const CAM_AIM: (f64, f64) = (0.15, 0.55);
/// The flight's direction on the screen (degrees up from the right).
const FLIGHT_ANGLE: f64 = 44.0;
/// The ball's radius, a fraction of the screen height. Not to scale with the
/// Earth, but the satellite's own proportions are the real ones (see
/// ../../REFERENCE.md): a 0.29 m radius ball with whips of 2.9 m and 2.4 m.
const BALL: f64 = 0.058;
/// The long (HF) and short (VHF) pairs, in ball radii: 2.9 m and 2.4 m on a
/// 0.29 m radius ball.
const ANTENNA: (f64, f64) = (10.0, 8.28);
/// Each arm's sweep off the ball's axis, backwards: a pair opens 70°, so 35°
/// either side of the axis (the spring hinges set it after separation).
const ANTENNA_SPLAY: f64 = 35.0;
/// The joint between the two half-shells: a ring square to the ball's axis,
/// this far ahead of the centre (in ball radii, the cosine of its angle from
/// the forward pole). Two hemispheres bolted together meet on the equator;
/// the shader draws their joining frames' strap and its 36 studs there
/// (res.w).
const SEAM: f64 = 0.0;
/// The hinges: where each arm pivots, on the front half-shell right against
/// the seam's strap (same units; the strap's half-width is 0.026). The hinge
/// brackets lie on the shell ahead of it. The shader gets it too (body.w).
const MOUNT: f64 = 0.10;
/// Each hinge's bracket: a tapered plate lying on the shell, from the hinge
/// forward along the meridian, this many radians of arc (about 0.36 radii).
const BRACKET: f64 = 0.36;
/// How far the ball's axis leans away from the viewer (degrees).
const AXIS_LEAN: f64 = -14.0;

// --- Pod data ---------------------------------------------------------------------

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub struct Globals {
    /// Width, height (px), time (s), the seam's offset along the ball's axis
    /// (ball radii).
    pub res: [f32; 4],
    /// Camera position (km), tan(half vertical fov).
    pub cam_pos: [f32; 4],
    /// Camera right axis, lens shift x (half heights).
    pub cam_right: [f32; 4],
    pub cam_up: [f32; 4],
    pub cam_fwd: [f32; 4],
    /// Earth radius, Greenwich sidereal angle (rad), satellite true anomaly
    /// (turns), ball radius (px).
    pub earth: [f32; 4],
    /// Light direction in view space (x right, y up, z towards the viewer), ball visibility.
    pub light: [f32; 4],
    /// Satellite on screen: x, y (px from top left), depth, (spare).
    pub sat_px: [f32; 4],
    /// Beam: angle (rad from vertical), axis x (half heights), breathing, seed.
    pub beam: [f32; 4],
    /// Ring trail length (turns), grain seed, px per reference px, loops' alpha.
    pub misc: [f32; 4],
    /// Orbit plane axes (perigee, 90 degrees on, normal).
    pub orb_p: [f32; 4],
    pub orb_q: [f32; 4],
    pub orb_h: [f32; 4],
    /// The ball's body frame: a direction square to its axis (the axis is
    /// orb_*.w) that turns with it, in view space; the hinges' offset along
    /// the axis (ball radii).
    pub body: [f32; 4],
}

/// One line segment: a (xyz, t), b (xyz, t), c (kind, width px, brightness, seed).
#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub struct Line {
    pub a: [f32; 4],
    pub b: [f32; 4],
    pub c: [f32; 4],
}

/// One glyph quad: x, y, w, h (px), u0, v0, u1, v1, colour rgb + alpha.
#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub struct Glyph {
    pub rect: [f32; 4],
    pub uv: [f32; 4],
    pub color: [f32; 4],
}

#[derive(Default)]
pub struct Frame {
    pub globals: Option<Globals>,
    pub lines: Vec<Line>,
    /// `lines[..ground]` is the ground track, drawn under the ball.
    pub ground: usize,
    pub text: Vec<Glyph>,
}

// --- Maths -------------------------------------------------------------------------

type V3 = [f64; 3];
fn add(a: V3, b: V3) -> V3 { [a[0] + b[0], a[1] + b[1], a[2] + b[2]] }
fn sub(a: V3, b: V3) -> V3 { [a[0] - b[0], a[1] - b[1], a[2] - b[2]] }
fn mul(a: V3, k: f64) -> V3 { [a[0] * k, a[1] * k, a[2] * k] }
fn dot(a: V3, b: V3) -> f64 { a[0] * b[0] + a[1] * b[1] + a[2] * b[2] }
fn cross(a: V3, b: V3) -> V3 { [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]] }
fn len(a: V3) -> f64 { dot(a, a).sqrt() }
fn norm(a: V3) -> V3 { mul(a, 1.0 / len(a).max(1e-12)) }
fn f4(a: V3, w: f64) -> [f32; 4] { [a[0] as f32, a[1] as f32, a[2] as f32, w as f32] }
fn rot_z(a: V3, ang: f64) -> V3 {
    let (s, c) = ang.sin_cos();
    [c * a[0] - s * a[1], s * a[0] + c * a[1], a[2]]
}
fn smoothstep(e0: f64, e1: f64, x: f64) -> f64 {
    let t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> f64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        ((z ^ (z >> 31)) >> 11) as f64 / (1u64 << 53) as f64
    }
    fn range(&mut self, a: f64, b: f64) -> f64 { a + (b - a) * self.next() }
}

/// Days since 1970-01-01 of a civil date (Howard Hinnant's algorithm).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn launch_unix() -> f64 {
    days_from_civil(LAUNCH_YMD.0, LAUNCH_YMD.1, LAUNCH_YMD.2) as f64 * 86_400.0 + LAUNCH_HMS
}

/// Greenwich mean sidereal angle (rad) at a Unix time.
fn gmst(unix: f64) -> f64 {
    let jd = unix / 86_400.0 + 2_440_587.5;
    (280.460_618_37 + 360.985_647_366_29 * (jd - 2_451_545.0)).rem_euclid(360.0).to_radians()
}

// --- The orbit -----------------------------------------------------------------------

struct Orbit {
    a: f64,
    e: f64,
    p: f64,
    n: f64,
    inc: f64,
    raan0: f64,
    argp0: f64,
    raan_dot: f64,
    argp_dot: f64,
}

struct State {
    /// Real position (km, inertial, z north) and radius.
    pos: V3,
    r: f64,
    nu: f64,
    speed: f64,
    /// Perifocal axes P, Q and the orbit normal W.
    axes: [V3; 3],
}

impl Orbit {
    fn new() -> Self {
        let (rp, ra) = (RE + PERIGEE_ALT, RE + APOGEE_ALT);
        let a = 0.5 * (rp + ra);
        let e = (ra - rp) / (ra + rp);
        let p = a * (1.0 - e * e);
        let n = (MU / (a * a * a)).sqrt();
        let inc = INCLINATION_DEG.to_radians();
        let k = 1.5 * n * J2 * (RE / p).powi(2);
        let raan_dot = -k * inc.cos();
        let argp_dot = 0.5 * k * (5.0 * inc.cos().powi(2) - 1.0);
        // Injected at perigee above the cosmodrome, going north-east: the
        // argument of latitude there fixes the argument of perigee, and the
        // node follows from where the site was under the stars.
        let lat = SITE_LAT_DEG.to_radians();
        let u0 = (lat.sin() / inc.sin()).asin();
        let dra = (inc.cos() * u0.sin()).atan2(u0.cos());
        let ra_site = gmst(launch_unix()) + SITE_LON_DEG.to_radians();
        Orbit { a, e, p, n, inc, raan0: ra_site - dra, argp0: u0, raan_dot, argp_dot }
    }

    fn period(&self) -> f64 { TAU / self.n }

    fn at(&self, t: f64) -> State {
        let m = (self.n * t).rem_euclid(TAU);
        let mut ecc = m + self.e * m.sin();
        for _ in 0..4 {
            ecc -= (ecc - self.e * ecc.sin() - m) / (1.0 - self.e * ecc.cos());
        }
        let nu = 2.0 * ((1.0 + self.e).sqrt() * (ecc / 2.0).sin()).atan2((1.0 - self.e).sqrt() * (ecc / 2.0).cos());
        let r = self.a * (1.0 - self.e * ecc.cos());
        let (raan, argp) = (self.raan0 + self.raan_dot * t, self.argp0 + self.argp_dot * t);
        let (so, co) = raan.sin_cos();
        let (sw, cw) = argp.sin_cos();
        let (si, ci) = self.inc.sin_cos();
        let pv = [co * cw - so * sw * ci, so * cw + co * sw * ci, sw * si];
        let qv = [-co * sw - so * cw * ci, -so * sw + co * cw * ci, cw * si];
        let wv = [so * si, -co * si, ci];
        let pos = add(mul(pv, r * nu.cos()), mul(qv, r * nu.sin()));
        State { pos, r, nu, speed: (MU * (2.0 / r - 1.0 / self.a)).sqrt(), axes: [pv, qv, wv] }
    }

    /// Radius drawn at a real radius (altitude exaggerated).
    fn vis_r(r: f64) -> f64 { RE + (r - RE) * ALT_EXAGGERATION }
}

// --- The land mask ---------------------------------------------------------------------

/// Douglas-Peucker: the points of `pts` (an open polyline) that keep it
/// within `tol` of the original.
fn simplify(pts: &[(f64, f64)], tol: f64) -> Vec<(f64, f64)> {
    if pts.len() < 3 {
        return pts.to_vec();
    }
    let mut keep = vec![false; pts.len()];
    keep[0] = true;
    keep[pts.len() - 1] = true;
    let mut stack = vec![(0, pts.len() - 1)];
    while let Some((a, b)) = stack.pop() {
        let ((ax, ay), (bx, by)) = (pts[a], pts[b]);
        let (dx, dy) = (bx - ax, by - ay);
        let l = (dx * dx + dy * dy).sqrt();
        let (mut best, mut at) = (0.0, 0);
        for (i, &(px, py)) in pts.iter().enumerate().take(b).skip(a + 1) {
            let d = if l > 1e-9 { (dx * (ay - py) - dy * (ax - px)).abs() / l } else { (px - ax).hypot(py - ay) };
            if d > best {
                (best, at) = (d, i);
            }
        }
        if best > tol {
            keep[at] = true;
            stack.push((a, at));
            stack.push((at, b));
        }
    }
    pts.iter().zip(keep).filter(|p| p.1).map(|p| *p.0).collect()
}

/// The coastlines, simplified into poster shapes (see COAST_TOLERANCE),
/// filled (even-odd, per polygon) into an equirectangular R8 mask, 255 on
/// land. The data's polylines are rings, except Antarctica's which runs round
/// the coast and is closed through the pole.
fn build_land() -> Vec<u8> {
    let (w, h) = (LAND_W as usize, LAND_H as usize);
    let mut mask = vec![0u8; w * h];
    let rd = |o: usize| u32::from_le_bytes(COASTLINE[o..o + 4].try_into().unwrap());
    let rf = |o: usize| f32::from_le_bytes(COASTLINE[o..o + 4].try_into().unwrap()) as f64;
    let mut off = 4;
    let count = rd(0) as usize;
    let mut xs: Vec<f64> = Vec::new();
    for _ in 0..count {
        let n = rd(off) as usize;
        off += 4;
        // Longitude unwrapped, to pixel coordinates.
        let mut pts: Vec<(f64, f64)> = Vec::with_capacity(n + 2);
        let mut prev = 0.0;
        let mut shift = 0.0;
        for i in 0..n {
            let (lon, lat) = (rf(off), rf(off + 4));
            off += 8;
            if i > 0 {
                if lon + shift - prev > 180.0 { shift -= 360.0 } else if lon + shift - prev < -180.0 { shift += 360.0 }
            }
            let ul = lon + shift;
            prev = ul;
            pts.push((ul, lat));
        }
        let span = pts.iter().map(|p| p.0).fold(f64::MIN, f64::max) - pts.iter().map(|p| p.0).fold(f64::MAX, f64::min);
        if span > 300.0 {
            pts = simplify(&pts, COAST_TOLERANCE);
            let (first, last) = (pts[0], pts[pts.len() - 1]);
            pts.push((last.0, -90.0));
            pts.push((first.0, -90.0));
        } else {
            let twice_area: f64 = (0..pts.len()).map(|i| {
                let (p, q) = (pts[i], pts[(i + 1) % pts.len()]);
                p.0 * q.1 - q.0 * p.1
            }).sum();
            if 0.5 * twice_area.abs() < MIN_ISLAND {
                continue;
            }
            pts.push(pts[0]);
            pts = simplify(&pts, COAST_TOLERANCE);
            pts.pop();
            if pts.len() < 3 {
                continue;
            }
        }
        let px: Vec<(f64, f64)> = pts.iter().map(|&(lon, lat)| ((lon + 180.0) / 360.0 * w as f64, (90.0 - lat) / 180.0 * h as f64)).collect();
        let (ymin, ymax) = px.iter().fold((f64::MAX, f64::MIN), |(a, b), p| (a.min(p.1), b.max(p.1)));
        let (row0, row1) = ((ymin - 0.5).floor().max(0.0) as usize, ((ymax + 0.5).ceil() as usize).min(h - 1));
        for row in row0..=row1 {
            let yc = row as f64 + 0.5;
            xs.clear();
            for i in 0..px.len() {
                let (p0, p1) = (px[i], px[(i + 1) % px.len()]);
                if (p0.1 <= yc) != (p1.1 <= yc) {
                    xs.push(p0.0 + (yc - p0.1) / (p1.1 - p0.1) * (p1.0 - p0.0));
                }
            }
            xs.sort_by(|a, b| a.partial_cmp(b).unwrap());
            for pair in xs.chunks_exact(2) {
                let (x0, x1) = ((pair[0] - 0.5).ceil() as i64, (pair[1] - 0.5).floor() as i64);
                for x in x0..=x1 {
                    mask[row * w + x.rem_euclid(w as i64) as usize] = 255;
                }
            }
        }
    }
    // Softened (two box passes each way, wrapping in longitude) so the
    // shader's 0.5 contour is a smooth, slightly simplified coast instead of
    // texel steps.
    let r = 3usize;
    let mut tmp = vec![0u8; w * h];
    for _ in 0..2 {
        for y in 0..h {
            let row = &mask[y * w..(y + 1) * w];
            let mut acc: u32 = (0..=2 * r).map(|i| row[(i + w - r) % w] as u32).sum();
            for x in 0..w {
                tmp[y * w + x] = (acc / (2 * r as u32 + 1)) as u8;
                acc += row[(x + r + 1) % w] as u32;
                acc -= row[(x + w - r) % w] as u32;
            }
        }
        for x in 0..w {
            let at = |y: i64| tmp[y.clamp(0, h as i64 - 1) as usize * w + x] as u32;
            let mut acc: u32 = (-(r as i64)..=r as i64).map(at).sum();
            for y in 0..h {
                mask[y * w + x] = (acc / (2 * r as u32 + 1)) as u8;
                acc += at(y as i64 + r as i64 + 1);
                acc -= at(y as i64 - r as i64);
            }
        }
    }
    mask
}

// --- Text ----------------------------------------------------------------------------------

const CHARSET: &str = "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ0123456789 ,.:-—!№°/+%";
const CELL: (u32, u32) = (112, 150);
const BASELINE: f32 = 112.0;
const PAD_X: f32 = 6.0;
const FONT_PX: f32 = 130.0;
const CONDENSE: f32 = 0.70;

struct GlyphInfo {
    uv: [f32; 4],
    adv: f32,
}

pub struct Atlas {
    pub w: u32,
    pub h: u32,
    pub pixels: Vec<u8>,
    glyphs: HashMap<char, GlyphInfo>,
    cap: f32,
}

/// A bold, condensed (the font squeezed sideways) face for the Constructivist
/// block lettering: the installed Adwaita Sans at its heaviest, or any other
/// installed bold sans with Cyrillic.
fn load_font() -> Option<(Vec<u8>, f32, f32)> {
    let home = std::env::var("HOME").unwrap_or_default();
    // Oswald (OFL, scripts/theme/install-fonts.sh): already condensed, the
    // poster's tall narrow letters.
    if let Ok(d) = std::fs::read(format!("{home}/.local/share/fonts/wallpaper-themes/Oswald[wght].ttf")) {
        return Some((d, 1.0, 520.0));
    }
    let candidates = [
        "/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf".to_string(),
        "/usr/share/fonts/Adwaita/AdwaitaMono-Bold.ttf".to_string(),
        format!("{home}/.local/share/fonts/carlito/Carlito-Bold.ttf"),
        "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf".to_string(),
        "/usr/share/fonts/noto/NotoSans-Bold.ttf".to_string(),
    ];
    candidates.iter().find_map(|p| std::fs::read(p).ok()).map(|d| (d, CONDENSE, 900.0))
}

fn build_atlas() -> Option<Atlas> {
    let (data, condense, weight) = load_font()?;
    let mut font = FontRef::try_from_slice(&data).ok()?;
    font.set_variation(b"wght", weight);
    let scale = PxScale { x: FONT_PX * condense, y: FONT_PX };
    let scaled = font.as_scaled(scale);
    let chars: Vec<char> = CHARSET.chars().collect();
    let cols = 18u32;
    let rows = (chars.len() as u32).div_ceil(cols);
    let (w, h) = (cols * CELL.0, rows * CELL.1);
    let mut pixels = vec![0u8; (w * h) as usize];
    let mut glyphs = HashMap::new();
    let mut cap = 80.0;
    for (i, &ch) in chars.iter().enumerate() {
        let (cx, cy) = ((i as u32 % cols) * CELL.0, (i as u32 / cols) * CELL.1);
        let id = font.glyph_id(ch);
        let adv = scaled.h_advance(id);
        if let Some(outline) = font.outline_glyph(id.with_scale_and_position(scale, point(PAD_X, BASELINE))) {
            let b = outline.px_bounds();
            if ch == 'Н' {
                cap = b.height();
            }
            outline.draw(|x, y, c| {
                let (px, py) = (b.min.x as i32 + x as i32, b.min.y as i32 + y as i32);
                if px >= 0 && py >= 0 && (px as u32) < CELL.0 && (py as u32) < CELL.1 {
                    let o = ((cy + py as u32) * w + cx + px as u32) as usize;
                    pixels[o] = pixels[o].max((c * 255.0) as u8);
                }
            });
        }
        let uv = [cx as f32 / w as f32, cy as f32 / h as f32, (cx + CELL.0) as f32 / w as f32, (cy + CELL.1) as f32 / h as f32];
        glyphs.insert(ch, GlyphInfo { uv, adv });
    }
    Some(Atlas { w, h, pixels, glyphs, cap })
}

impl Atlas {
    fn width(&self, s: &str, cap_px: f32, tracking: f32) -> f32 {
        let sc = cap_px / self.cap;
        s.chars().map(|c| self.glyphs.get(&c).map_or(0.0, |g| g.adv * sc) + tracking).sum::<f32>() - tracking
    }

    /// Glyph quads for `s` with its baseline at `y`, starting at `x`.
    #[allow(clippy::too_many_arguments)]
    fn push(&self, out: &mut Vec<Glyph>, s: &str, mut x: f32, y: f32, cap_px: f32, tracking: f32, rgb: [f32; 3], alpha: f32) {
        if alpha <= 0.003 {
            return;
        }
        let sc = cap_px / self.cap;
        for c in s.chars() {
            let Some(g) = self.glyphs.get(&c) else { continue };
            if c != ' ' {
                out.push(Glyph {
                    rect: [x - PAD_X * sc, y - BASELINE * sc, CELL.0 as f32 * sc, CELL.1 as f32 * sc],
                    uv: g.uv,
                    color: [rgb[0], rgb[1], rgb[2], alpha],
                });
            }
            x += g.adv * sc + tracking;
        }
    }
}

const PEACH: [f32; 3] = [1.0, 0.76, 0.60];
const CREAM: [f32; 3] = [0.99, 0.94, 0.84];
const GHOST: [f32; 3] = [0.86, 0.17, 0.10];
const RULE: [f32; 3] = [0.93, 0.22, 0.10];

const SLOGANS: [&[&str]; 6] = [
    &["СТРАНА", "ОКТЯБРЯ —", "РОДИНА", "КОСМОНАВТИКИ"],
    &["СТРАНА", "ОКТЯБРЯ —", "РОДИНА", "КОСМОНАВТИКИ"],
    &["СПУТНИК-1"],
    &["ПЕРВЫЙ В МИРЕ", "ИСКУССТВЕННЫЙ", "СПУТНИК", "ЗЕМЛИ"],
    &["4 ОКТЯБРЯ", "1957"],
    &["СЛАВА", "СОВЕТСКОЙ", "НАУКЕ!"],
];

// --- The scene -------------------------------------------------------------------------------

pub struct SceneData {
    pub static_lines: Vec<Line>,
    pub land: Vec<u8>,
    pub atlas: Option<Atlas>,
    orbit: Orbit,
    start_wall: f64,
    t0_sim: f64,
    ph: [f64; 12],
    seed: u32,
    streaks: [[f64; 4]; 8],
}

/// Seconds since the Unix epoch.
pub fn unix_secs(now: SystemTime) -> f64 {
    now.duration_since(UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64())
}

impl SceneData {
    pub fn build() -> Self {
        // SPUTNIK_SEED (stills, examples/sputnik_shot.rs): fixed randomness and
        // a clock that starts at 0.
        let fixed: Option<u64> = std::env::var("SPUTNIK_SEED").ok().and_then(|s| s.parse().ok());
        let start = 0.0;
        let mut rng = Rng(fixed.unwrap_or(CLOCK_SEED) ^ 0x5bd1_e995_1234_abcd);
        let orbit = Orbit::new();
        let mut ph = [0.0; 12];
        for p in ph.iter_mut() {
            *p = rng.range(0.0, TAU);
        }
        let mut streaks = [[0.0; 4]; 8];
        for s in streaks.iter_mut() {
            *s = [rng.range(0.0, TAU), rng.range(0.1, 1.1), rng.range(3.0, 9.0), rng.range(0.0, TAU)];
        }
        let mut static_lines = Vec::new();

        // The orbit ring, in the orbit's own plane (the shader turns it into
        // the precessing real one).
        let n = 360;
        let ring_pt = |i: usize| {
            let nu = TAU * i as f64 / n as f64;
            let r = Orbit::vis_r(orbit.p / (1.0 + orbit.e * nu.cos()));
            [r * nu.cos(), r * nu.sin(), 0.0]
        };
        for i in 0..n {
            let (a, b) = (ring_pt(i), ring_pt(i + 1));
            static_lines.push(Line {
                a: [a[0] as f32, a[1] as f32, 0.0, (i as f64 / n as f64) as f32],
                b: [b[0] as f32, b[1] as f32, 0.0, ((i + 1) as f64 / n as f64) as f32],
                c: [0.0, 4.6, 1.0, 0.0],
            });
        }

        // Thin hand-drawn loops, as scribbled across the poster's lower half:
        // open ellipse arcs on the screen (kind 1, half-heights about a centre
        // given as a fraction of the half-width and a height), with a little
        // wobble; the shader turns and breathes them.
        let loop_specs: [(f64, f64, f64, f64); 9] = [
            (-0.55, -0.35, 1.10, 4.2), (-0.10, -0.55, 0.95, 3.4), (0.25, -0.30, 0.80, 4.4),
            (0.55, -0.60, 1.25, 3.2), (-0.30, 0.05, 1.45, 2.6), (0.10, -0.85, 0.70, 3.8),
            (0.75, -0.15, 0.85, 3.0), (-0.80, -0.75, 0.75, 3.6), (0.30, -0.10, 1.20, 2.6),
        ];
        for (k, &(cx, cy, size, width)) in loop_specs.iter().enumerate() {
            let seed = rng.next();
            let ra = size * rng.range(0.85, 1.15);
            let rb = ra * rng.range(0.22, 0.55);
            let span = rng.range(0.55, 0.92);
            let start_nu = rng.range(0.0, TAU);
            let (f1, f2, f3) = (rng.range(2.0, 5.0).round(), rng.range(5.0, 9.0).round(), rng.range(0.0, TAU));
            let amp = rng.range(0.006, 0.02);
            let steps = 140;
            let pt = |i: usize| {
                let f = i as f64 / steps as f64;
                let nu = start_nu + TAU * span * f;
                let wob = 1.0 + amp * ((f1 * TAU * f + f3).sin() + 0.5 * (f2 * TAU * f + f3 * 2.0).sin());
                [ra * wob * nu.cos(), rb * wob * nu.sin()]
            };
            let (cx, cy) = (cx + rng.range(-0.05, 0.05), cy + rng.range(-0.05, 0.05));
            for i in 0..steps {
                let (a, b) = (pt(i), pt(i + 1));
                static_lines.push(Line {
                    a: [a[0] as f32, a[1] as f32, cx as f32, (i as f64 / steps as f64) as f32],
                    b: [b[0] as f32, b[1] as f32, cy as f32, ((i + 1) as f64 / steps as f64) as f32],
                    c: [1.0, width as f32, 1.0, ((seed + k as f64 * 0.137) % 1.0) as f32],
                });
            }
        }

        SceneData {
            static_lines,
            land: build_land(),
            atlas: build_atlas(),
            orbit,
            start_wall: start,
            t0_sim: { let t0 = rng.range(0.0, 55.0 * 86_400.0); if fixed.is_some() { t0 } else { 0.0 } },
            ph,
            seed: (rng.next() * 4e9) as u32,
            streaks,
        }
    }

    /// The scene for a `width` × `height` output at wall-clock time `now`.
    pub fn frame(&self, now: f64, width: u32, height: u32, out: &mut Frame) {
        let (w, h) = (width as f64, height as f64);
        let aspect = w / h;
        let tw = (now - self.start_wall).rem_euclid(LOOP_SECS);
        let sim_t = self.t0_sim + WARP * tw;
        let st = self.orbit.at(sim_t);
        let [pa, qa, wa] = st.axes;
        let ph = &self.ph;
        let period = self.orbit.period();

        // Chase camera: behind the satellite, a little above and to the side
        // of its orbit, looking along its flight and down at the horizon, so it
        // flies up the frame's diagonal away from the Earth's limb, its
        // antennas trailing back towards us (the poster's view). Everything
        // follows the real orbit: the Earth turns underneath, the limb sinks
        // and swells with the altitude (perigee to apogee), the ring precesses.
        let sat_vis = mul(norm(st.pos), Orbit::vis_r(st.r));
        let rhat = norm(sat_vis);
        let vt = norm(cross(wa, rhat));
        let drift = |p: f64, i: usize| (tw * TAU / p + ph[i]).sin();
        let back = RE * (CAM_OFF.0 + 0.06 * drift(370.0, 0) + 0.03 * drift(149.0, 5));
        let rise = RE * (CAM_OFF.1 + 0.04 * drift(290.0, 1));
        let side = RE * (CAM_OFF.2 + 0.06 * drift(450.0, 2));
        let cam = add(add(add(sat_vis, mul(vt, -back)), mul(rhat, rise)), mul(wa, side));
        let target = add(add(sat_vis, mul(vt, RE * CAM_AIM.0)), mul(rhat, -RE * (CAM_AIM.1 + 0.05 * drift(510.0, 3))));
        let fwd = norm(sub(target, cam));
        let right0 = norm(cross(fwd, rhat));
        let up0 = cross(right0, fwd);
        // Roll so it always flies up the same diagonal: the screen angle of a
        // short step along its flight, before rolling, minus the wanted one.
        let flat = |p: V3| {
            let d = sub(p, cam);
            let z = dot(d, fwd);
            [dot(d, right0) / z, dot(d, up0) / z]
        };
        let (f0, f1) = (flat(sat_vis), flat(add(sat_vis, mul(vt, 0.2 * RE))));
        let phi0 = (f1[1] - f0[1]).atan2(f1[0] - f0[0]);
        let roll = phi0 - FLIGHT_ANGLE.to_radians() + 0.03 * drift(230.0, 6);
        let (sr, cr) = roll.sin_cos();
        let right = add(mul(right0, cr), mul(up0, sr));
        let up = add(mul(right0, -sr), mul(up0, cr));
        let view = |p: V3| {
            let d = sub(p, cam);
            (dot(d, right) / (dot(d, fwd) * TAN_HALF_FOV), dot(d, up) / (dot(d, fwd) * TAN_HALF_FOV), dot(d, fwd))
        };
        // Lens shift: the satellite always lands on the composition's point.
        let (sat_u, sat_v, sz) = view(sat_vis);
        let anchor = [SAT_AT.0 * aspect.min(2.4), SAT_AT.1 + 0.02 * drift(330.0, 7)];
        let (ox, oy) = (anchor[0] - sat_u, anchor[1] - sat_v);
        let project = |p: V3| {
            let (u, v, zc) = view(p);
            (0.5 * w + (u + ox) * 0.5 * h, 0.5 * h - (v + oy) * 0.5 * h, zc)
        };

        // The satellite, its ball and antennas.
        let (sx, sy, _) = project(sat_vis);
        let wpp = sz * TAN_HALF_FOV * 2.0 / h; // km per px at its depth
        let ball_px = BALL * h;
        let ball_r = ball_px * wpp;
        let vhat = vt;
        let e1 = norm(cross(vhat, wa));
        let e2 = cross(vhat, e1);
        // Where it's flying, on the screen: the beam runs that way.
        let vp = [dot(vhat, right) / (dot(vhat, fwd) * TAN_HALF_FOV) + ox, dot(vhat, up) / (dot(vhat, fwd) * TAN_HALF_FOV) + oy];
        let flight = (vp[1] - anchor[1]).atan2(vp[0] - anchor[0]);
        // The ball's own axis (front pole forward, antennas behind): along
        // its flight as seen on the screen, the poster's diagonal, leaning
        // AXIS_LEAN away from the viewer and nodding slowly, so the antennas
        // trail down-left and a little towards us. (The true velocity points
        // mostly away from the chase camera, which would fan them out flat.)
        let lean = (AXIS_LEAN + 4.0 * drift(270.0, 11)).to_radians();
        let want = flight + 0.03 * drift(210.0, 8);
        let axis_at = |fa: f64| norm(add(add(mul(right, fa.cos() * lean.cos()), mul(up, fa.sin() * lean.cos())), mul(fwd, lean.sin())));
        // Perspective skews the trailing rods off the diagonal (the ball is
        // off-centre): turn the axis until the rods' middle runs parallel to
        // the beam on the screen.
        let mut fa = want;
        for _ in 0..2 {
            let tail = add(sat_vis, mul(axis_at(fa), -ANTENNA.0 * ball_r));
            let (tx, ty, _) = project(tail);
            fa += want - (ty - sy).atan2(sx - tx);
        }
        let ax = axis_at(fa);
        let a1 = norm(cross(ax, fwd));
        let a2 = cross(ax, a1);
        // The body frame: the axis and (b1, b2) square to it, rolled about it
        // by kappa. The shell's fittings (shader, from body), the hinge
        // brackets and the antennas all hang off this one frame, so the ball
        // and its arms turn, nod and fly as a single rigid body. It rocks to
        // and fro about the axis rather than spinning right round, so the
        // valve flange (on the front half-shell, facing us at kappa = 0)
        // stays in view.
        let kappa = 0.9 * (tw * 0.035 + ph[7]).sin() + 0.25 * (tw * 0.013 + ph[6]).sin();
        let b1 = add(mul(a1, kappa.cos()), mul(a2, kappa.sin()));
        let b2 = cross(ax, b1);

        // Is it behind the Earth? (softly, by how far the ray clears the limb)
        let to_sat = sub(sat_vis, cam);
        let l = len(to_sat);
        let rdir = mul(to_sat, 1.0 / l);
        let b = dot(cam, rdir);
        let dmin = (dot(cam, cam) - b * b).max(0.0).sqrt();
        let t_hit = -b - (RE * RE - dmin * dmin).max(0.0).sqrt();
        let vis = if dmin < RE + 4.0 * ball_r && t_hit < l { smoothstep(RE, RE + 2.5 * ball_r, dmin) } else { 1.0 };

        out.lines.clear();
        out.text.clear();

        // Ground track: the sub-satellite point a little back and ahead, on
        // the turning Earth.
        let g_now = gmst(launch_unix() + sim_t);
        let steps = 120;
        let (back_t, fwd_t) = (0.35, 0.45);
        let gt_pt = |i: usize| {
            let f = i as f64 / steps as f64;
            let tau = sim_t + (-back_t + (back_t + fwd_t) * f) * period;
            let s = self.orbit.at(tau);
            let ef = rot_z(norm(s.pos), -gmst(launch_unix() + tau));
            (mul(rot_z(ef, g_now), RE * 1.002), (tau - sim_t) / period)
        };
        let (mut prev, mut prev_t) = gt_pt(0);
        for i in 1..=steps {
            let (cur, cur_t) = gt_pt(i);
            out.lines.push(Line { a: f4(prev, prev_t), b: f4(cur, cur_t), c: [2.0, 2.6, 1.0, 0.0] });
            prev = cur;
            prev_t = cur_t;
        }
        out.ground = out.lines.len();

        // Antennas: Sputnik 1's two crossed V-dipoles, four arms, the long
        // (HF) and short (VHF) pairs opposite each other, hinged 90 degrees
        // apart on the front half-shell right against the seam and swept
        // ANTENNA_SPLAY back off the axis into a cone trailing behind it,
        // fixed in the body frame; the arms are stiff (a hair of flex). Each
        // arm, as on the real one: a tapered bracket plate lying on the shell
        // ahead of the hinge, the hinge knuckle, a thick ferrule tube, a
        // collar, then the whip stepping down to a pointed tip. All as
        // tapered strips (kind 3: a.w and b.w are the widths in px, at the
        // 1440 reference height, at either end; c.w picks the ink: 0 the
        // whip, 1 the darker fittings, 2 the bracket plate, the shell's
        // own).
        //
        // The shader draws the ball flat (a disc with view-space normals),
        // so a point of the shell is put on the camera ray through the pixel
        // where that normal is drawn, at its true depth, rather than at its
        // 3D point (which perspective would shift off the seam line).
        let unproject = |px: f64, py: f64, zc: f64| {
            let u = (px - 0.5 * w) / (0.5 * h) - ox;
            let v = (0.5 * h - py) / (0.5 * h) - oy;
            add(add(add(cam, mul(fwd, zc)), mul(right, u * zc * TAN_HALF_FOV)), mul(up, v * zc * TAN_HALF_FOV))
        };
        let surf = |dir: V3| unproject(sx + ball_px * dot(dir, right), sy - ball_px * dot(dir, up), sz + ball_r * dot(dir, fwd));
        // widths: fractions of the ball's radius, as px at the reference height
        let wu = BALL * 1440.0;
        let sigma = ANTENNA_SPLAY.to_radians();
        for k in 0..4 {
            let around = k as f64 * PI / 2.0 + PI / 4.0;
            let radial = add(mul(b1, around.cos()), mul(b2, around.sin()));
            let d = add(mul(ax, -sigma.cos()), mul(radial, sigma.sin()));
            let radii = if k % 2 == 0 { ANTENNA.0 } else { ANTENNA.1 };
            let length = radii * ball_r;
            // the hinge, on the shell just ahead of the seam
            let m = add(mul(ax, MOUNT), mul(radial, (1.0 - MOUNT * MOUNT).sqrt()));
            let origin = surf(m);
            // The bracket plate: on the shell from the hinge forward along
            // the meridian, in a few chords, wide at the hinge and narrowing
            // towards the pole.
            let tmer = norm(sub(ax, mul(m, dot(m, ax))));
            let plate = |theta: f64| surf(add(mul(m, theta.cos()), mul(tmer, theta.sin())));
            let chords = 3;
            for i in 0..chords {
                let (t0, t1) = (BRACKET * i as f64 / chords as f64, BRACKET * (i + 1) as f64 / chords as f64);
                let wd = |t: f64| wu * (0.14 - 0.07 * t / BRACKET);
                out.lines.push(Line { a: f4(plate(t0), wd(t0)), b: f4(plate(t1), wd(t1)), c: [3.0, 0.0, 1.0, 2.0] });
            }
            let (p1, p2) = (ph[8] + k as f64 * 1.9, ph[9] + k as f64 * 2.7);
            let flex = add(mul(a1, (0.31 * tw + p1).sin()), mul(a2, (0.23 * tw + p2).sin()));
            let at = |s: f64| add(add(origin, mul(d, length * s)), mul(flex, length * 0.0035 * s * s));
            // (from, to, width from, width to, ink), lengths as fractions of
            // the arm; the fittings' in ball radii
            let r = |x: f64| x / radii;
            let mut parts: Vec<(f64, f64, f64, f64, f64)> = vec![
                (r(-0.03), r(0.10), wu * 0.15, wu * 0.13, 1.0), // hinge knuckle
                (r(0.10), r(0.44), wu * 0.105, wu * 0.095, 1.0), // ferrule
                (r(0.44), r(0.50), wu * 0.075, wu * 0.06, 1.0),  // collar
            ];
            // the inner rod, then the thinner outer whip, in segments so the
            // flex bends them
            let (c1, c2, tip) = (r(0.50), 0.46, 0.985);
            let seg = 3;
            for i in 0..seg {
                let (s0, s1) = (c1 + (c2 - c1) * i as f64 / seg as f64, c1 + (c2 - c1) * (i + 1) as f64 / seg as f64);
                let wd = |s: f64| wu * (0.055 - 0.010 * (s - c1) / (c2 - c1));
                parts.push((s0, s1, wd(s0), wd(s1), 0.0));
            }
            let seg = 5;
            for i in 0..seg {
                let (s0, s1) = (c2 + (tip - c2) * i as f64 / seg as f64, c2 + (tip - c2) * (i + 1) as f64 / seg as f64);
                let wd = |s: f64| wu * (0.040 - 0.014 * (s - c2) / (tip - c2));
                parts.push((s0, s1, wd(s0), wd(s1), 0.0));
            }
            parts.push((tip, 1.0, wu * 0.026, 0.0, 0.0));
            for (s0, s1, w0, w1, ink) in parts {
                out.lines.push(Line { a: f4(at(s0), w0), b: f4(at(s1), w1), c: [3.0, 0.0, 1.0, ink as f32] });
            }
        }
        // Streaks of light trailing back from it.
        for (j, s) in self.streaks.iter().enumerate() {
            let sd = add(mul(e1, s[0].cos()), mul(e2, s[0].sin()));
            let start = add(add(sat_vis, mul(sd, s[1] * 0.8 * ball_r)), mul(vhat, -ball_r * 0.6));
            let flicker = 0.8 + 0.2 * (tw * (0.5 + 0.07 * j as f64) + s[3]).sin();
            let end = add(add(start, mul(vhat, -s[2] * 0.9 * ball_r * flicker)), mul(sd, ball_r * 0.25 * (s[3]).sin()));
            out.lines.push(Line { a: f4(start, 0.0), b: f4(end, 1.0), c: [4.0, 3.0, (0.45 + 0.4 * flicker) as f32, 0.0] });
        }

        // The Earth's light comes from the upper right, the way it flies.
        let breathe = 1.0 + 0.05 * (tw * 0.21 + ph[3]).sin() + 0.03 * (tw * 0.53 + ph[2]).sin();
        let light = norm([0.62 + 0.05 * drift(610.0, 1), 0.55, 0.42]);
        let vv = [dot(ax, right), dot(ax, up), -dot(ax, fwd)];

        out.globals = Some(Globals {
            res: [width as f32, height as f32, tw as f32, SEAM as f32],
            cam_pos: f4(cam, TAN_HALF_FOV),
            cam_right: f4(right, ox),
            cam_up: f4(up, oy),
            cam_fwd: f4(fwd, 0.0),
            earth: [RE as f32, g_now as f32, (st.nu.rem_euclid(TAU) / TAU) as f32, ball_px as f32],
            light: [light[0] as f32, light[1] as f32, light[2] as f32, vis as f32],
            sat_px: [sx as f32, sy as f32, sz as f32, (0.5 * (tw * 0.07 + ph[5]).sin()) as f32],
            beam: [anchor[0] as f32, anchor[1] as f32, (flight + 0.015 * drift(190.0, 10)) as f32, breathe as f32],
            misc: [0.22, (self.seed % 1013) as f32, (h / 1440.0) as f32, (0.85 + 0.15 * (tw * 0.05 + ph[4]).sin()) as f32],
            orb_p: f4(pa, vv[0]),
            orb_q: f4(qa, vv[1]),
            orb_h: f4(wa, vv[2]),
            body: [dot(b1, right) as f32, dot(b1, up) as f32, -dot(b1, fwd) as f32, MOUNT as f32],
        });

        if let Some(atlas) = &self.atlas {
            let g = out.globals.as_ref().unwrap();
            self.layout_text(atlas, tw, &st, sim_t, w as f32, h as f32, g.beam, &mut out.text);
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn layout_text(&self, atlas: &Atlas, tw: f64, st: &State, sim_t: f64, w: f32, h: f32, beam: [f32; 4], out: &mut Vec<Glyph>) {
        let u = h / 1440.0;
        // Every letter is printed twice: a red plate a few pixels off
        // register under the peach/cream one, as on the cheap offset prints.
        let ghost_off = 3.5 * u;
        let put = |out: &mut Vec<Glyph>, s: &str, x: f32, y: f32, cap: f32, tr: f32, rgb: [f32; 3], a: f32| {
            atlas.push(out, s, x + ghost_off, y + ghost_off * 0.7, cap, tr, GHOST, a * 0.72);
            atlas.push(out, s, x, y, cap, tr, rgb, a);
        };
        // A solid bar (a glyph with an empty uv box).
        let bar = |out: &mut Vec<Glyph>, x: f32, y: f32, bw: f32, bh: f32, rgb: [f32; 3], a: f32| {
            if a > 0.003 {
                out.push(Glyph { rect: [x, y, bw, bh], uv: [0.0; 4], color: [rgb[0], rgb[1], rgb[2], a] });
            }
        };
        let fade = |into: f64, len: f64, fi: f64| (into / fi).min((len - into) / fi).clamp(0.0, 1.0) as f32;
        let mix_hash = |k: i64, salt: u32| {
            let mut z = (k as u64).wrapping_mul(0x9e37_79b9_7f4a_7c15) ^ ((self.seed ^ salt) as u64).wrapping_mul(0xbf58_476d_1ce4_e5b9);
            z = (z ^ (z >> 30)).wrapping_mul(0x94d0_49bb_1331_11eb);
            (z ^ (z >> 31)) as usize
        };
        let left = 0.075 * h;

        // The slogan, bottom left on the orange, a new one every so often,
        // under a red rule.
        let slot = 40.0;
        let k = (tw / slot).floor() as i64;
        let mut pick = mix_hash(k, 1) % SLOGANS.len();
        if k > 0 && SLOGANS[pick][0] == SLOGANS[mix_hash(k - 1, 1) % SLOGANS.len()][0] {
            pick = (pick + 2) % SLOGANS.len();
        }
        let lines = SLOGANS[pick];
        let a = fade(tw - k as f64 * slot, slot, 2.4);
        // As big as it can be while staying clear of the beam's upper edge
        // (the shader's beam(), in half-heights from the centre).
        let beam_left = |y_px: f32| {
            let yv = (0.5 * h - y_px) / (0.5 * h);
            let (ca, sa) = (beam[2].cos(), beam[2].sin());
            let mut x = beam[0];
            for _ in 0..4 {
                let s = (x - beam[0]) * ca + (yv - beam[1]) * sa;
                let half = (0.205 + 0.075 * s) * beam[3];
                // q = -(x-Sx) sa + (y-Sy) ca = ctr + half
                x = beam[0] + ((yv - beam[1]) * ca - (-0.045 + half)) / sa;
            }
            0.5 * w + x * 0.5 * h
        };
        let mut cap = (if lines.len() <= 2 { 0.068 } else { 0.050 }) * h;
        let y_last = h - 0.085 * h;
        for _ in 0..3 {
            let lh = cap * 1.32;
            let y_first = y_last - (lines.len() - 1) as f32 * lh - cap;
            let room = beam_left(y_first).min(beam_left(y_last)) - left - 0.035 * h;
            let tr = cap * 0.05;
            let bw = lines.iter().map(|s| atlas.width(s, cap, tr)).fold(0.0, f32::max);
            if bw > room {
                cap *= (room / bw).max(0.5);
            }
        }
        let lh = cap * 1.32;
        let tr = cap * 0.05;
        let y_first = y_last - (lines.len() - 1) as f32 * lh;
        bar(out, left, y_first - cap - 0.032 * h, 0.16 * h, 0.009 * h, RULE, a);
        for (i, s) in lines.iter().enumerate() {
            put(out, s, left, y_first + i as f32 * lh, cap, tr, PEACH, a);
        }

        // Live readouts, top left, one row at a time changing, set like
        // poster captions beside a red bar.
        let alt = st.r - RE;
        let orbit_no = (sim_t / self.orbit.period()).floor() as i64 + 1;
        let day = (sim_t / 86_400.0).floor() as i64 + 1;
        let rows: [[(&str, String); 4]; 3] = [
            [("ВЫСОТА", format!("{:.0} КМ", alt)), ("ВЫСОТА", format!("{:.0} КМ", alt)), ("ПЕРИГЕЙ", "215 КМ".into()), ("АПОГЕЙ", "939 КМ".into())],
            [("СКОРОСТЬ", format!("{:.2} КМ/С", st.speed).replace('.', ",")), ("СКОРОСТЬ", format!("{:.2} КМ/С", st.speed).replace('.', ",")), ("ПЕРИОД", "96,2 МИН".into()), ("НАКЛОНЕНИЕ", "65,1°".into())],
            [("ВИТОК", format!("№ {orbit_no}")), ("ВИТОК", format!("№ {orbit_no}")), ("СУТКИ", format!("{day}")), ("ЧАСТОТА", "20,005 МГЦ".into())],
        ];
        let (label_cap, value_cap) = (0.017 * h, 0.036 * h);
        let top = 0.105 * h;
        let pitch = 0.098 * h;
        bar(out, left, top - label_cap - 0.004 * h, 0.006 * h, 2.0 * pitch + label_cap + value_cap * 1.4 + 0.004 * h, RULE, 0.95);
        for (j, row) in rows.iter().enumerate() {
            let rslot = 16.0;
            let tj = tw + j as f64 * 5.3;
            let kj = (tj / rslot).floor() as i64;
            let item = &row[mix_hash(kj, 10 + j as u32) % 4];
            let a = fade(tj - kj as f64 * rslot, rslot, 0.9);
            let y = top + j as f32 * pitch;
            let x = left + 0.022 * h;
            atlas.push(out, item.0, x, y, label_cap, label_cap * 0.22, PEACH, a);
            put(out, &item.1, x, y + value_cap * 1.3, value_cap, value_cap * 0.04, CREAM, a);
        }
    }
}
