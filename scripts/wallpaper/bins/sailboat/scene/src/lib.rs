//! The sailboat wallpaper's scene, without any GPU API: the shader, the boat
//! mesh, the sky (real sun, moon and stars over Daytona Beach) and the sea
//! state (real wind, clouds, rain, thunder and waves from Open-Meteo), eased
//! so nothing pops. Drawn by the wallpaper renderer
//! (`scripts/wallpaper/bins/spinning_globe`, see its sailboat.rs) and by the
//! selector/lock Bevy app (`bevy/apps/sailboat`), which both follow this:
//!
//! 1. **sky** (`vs_full`/`fs_sky`) into an Rgba16Float texture of
//!    [`sky_size`] (half the output), only when [`World::sky_due`]; alpha is
//!    the clouds' transmittance;
//! 2. **boat** (`vs_boat`/`fs_boat`) with [`boat::build`]'s mesh (u16 index
//!    list, one [`BoatVertex`] each) into an Rgba8Unorm box of [`box_size`]
//!    with a Depth32Float buffer, 4× MSAA resolved, cleared to transparent;
//! 3. **composite** (`vs_full`/`fs_main`) onto the output, sampling both
//!    (bindings: 0 uniforms, 1 sky, 2 boat, 3 linear clamp sampler).
//!
//! Every pass reads the same [`Globals`] (binding 0) and draws its full-screen
//! pass as 3 vertices with no buffers. The output is 8-bit non-sRGB, no blending.
pub mod astro;
pub mod boat;
pub mod stars;
pub mod sync;
pub mod weather;

use std::f64::consts::{PI, TAU};
use std::time::{SystemTime, UNIX_EPOCH};

pub use bytemuck;
pub use weather::{Overrides, Weather};

pub const SHADER: &str = include_str!("sailboat.wgsl");
pub const BG: [f64; 3] = [0.05, 0.07, 0.12];

/// Daytona Beach, FL. The marine model is sampled a few km offshore (its grid
/// cell on the beach is land).
pub const LAT: f64 = 29.21;
pub const LON: f64 = -81.02;
const MARINE: (f64, f64) = (29.21, -80.90);

// --- Camera and layout --------------------------------------------------------

/// Looking east from the beach, over the Atlantic.
const CAM_HEADING: f64 = 90.0;
const CAM_HEIGHT: f64 = 3.6;
const TAN_HALF_FOV: f64 = 0.364; // 40° vertical
/// Down-tilt: puts the horizon about 58% of the way down the screen.
const CAM_PITCH: f64 = 3.3;
/// The sky texture's camera sees a little more than the screen so the bobbing
/// camera never looks past it.
const SKY_MARGIN: f64 = 1.08;
/// Where the boat floats: metres ahead and to the right of the camera.
const BOAT_AHEAD: f64 = 64.0;
const BOAT_RIGHT: f64 = 11.5;
/// The sky is redrawn this often (s) at most; the composite reads it every frame.
pub const SKY_INTERVAL: f64 = 0.1;
/// Noise used for drifting layers tiles every this many lattice cells, so
/// offsets wrap without a seam.
const NOISE_PERIOD: f64 = 64.0;

const KT: f64 = 0.514_444;
const G: f64 = 9.81;

pub fn unix_secs(t: SystemTime) -> f64 {
    t.duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

/// The sky texture's size for an output.
pub fn sky_size(w: u32, h: u32) -> (u32, u32) {
    (w.div_ceil(2).max(1), h.div_ceil(2).max(1))
}

/// The sky-and-sea pass renders at this fraction of the output (the boat,
/// stars, rain and grade stay at full resolution). SAILBOAT_SCALE overrides.
pub fn scene_scale(_w: u32, h: u32) -> f64 {
    static FORCED: std::sync::OnceLock<Option<f64>> = std::sync::OnceLock::new();
    let forced = *FORCED.get_or_init(|| {
        std::env::var("SAILBOAT_SCALE").ok().and_then(|v| v.parse::<f64>().ok()).filter(|&s| s > 0.1 && s <= 1.0)
    });
    // Small targets (the selector's card) are cheap at full size.
    forced.unwrap_or(if h <= 800 { 1.0 } else { 0.6 })
}

/// Motion tunables, read once from the environment (`SAILBOAT_HEAVE`, `SAILBOAT_PITCH`,
/// `SAILBOAT_ROLL`: how much of the waves the hull follows; `SAILBOAT_GULL_SPEED`: gull
/// circling speed multiplier). Unset or invalid values keep the defaults.
#[derive(Clone, Copy)]
struct Tunables {
    heave: f64,
    pitch: f64,
    roll: f64,
    gull_speed: f64,
}

fn tunables() -> Tunables {
    static T: std::sync::OnceLock<Tunables> = std::sync::OnceLock::new();
    *T.get_or_init(|| {
        let num = |k: &str, d: f64| {
            std::env::var(k).ok().and_then(|v| v.trim().parse::<f64>().ok()).filter(|v| v.is_finite() && *v >= 0.0).unwrap_or(d)
        };
        Tunables {
            heave: num("SAILBOAT_HEAVE", 1.0),
            pitch: num("SAILBOAT_PITCH", 0.25),
            roll: num("SAILBOAT_ROLL", 0.25),
            gull_speed: num("SAILBOAT_GULL_SPEED", 1.0),
        }
    })
}

/// The scene pass's texture size for an output.
pub fn scene_size(w: u32, h: u32) -> (u32, u32) {
    let s = scene_scale(w, h);
    (((w as f64 * s).round() as u32).max(1), ((h as f64 * s).round() as u32).max(1))
}

/// The boat box's size (px) for an output.
pub fn box_size(_w: u32, h: u32) -> (u32, u32) {
    let s = ((h as f64 * 0.46) as u32).clamp(64, 2048);
    (s, s)
}

// --- GPU data -------------------------------------------------------------------

#[repr(C)]
#[derive(Clone, Copy, Debug, bytemuck::Pod, bytemuck::Zeroable)]
pub struct BoatVertex {
    /// Position (boat frame, m), part id.
    pub pos: [f32; 4],
    /// Normal, u.
    pub normal: [f32; 4],
    /// v, unused.
    pub extra: [f32; 4],
}

/// The uniform block; field for field the `G` struct in sailboat.wgsl.
#[repr(C)]
#[derive(Clone, Copy, Debug, bytemuck::Pod, bytemuck::Zeroable)]
pub struct Globals {
    /// Output width, height (px), animation seconds (mod 3600), lightning flash.
    pub res: [f32; 4],
    /// Camera position (world m), tan(half vertical fov).
    pub cam_pos: [f32; 4],
    /// Camera axes; right.w = aspect.
    pub cam_right: [f32; 4],
    pub cam_up: [f32; 4],
    pub cam_fwd: [f32; 4],
    /// The sky texture's steady camera; right.w = tan(half fov), up.w = aspect.
    pub sky_right: [f32; 4],
    pub sky_up: [f32; 4],
    pub sky_fwd: [f32; 4],
    /// Sun direction, disc strength (0 below the horizon or hidden).
    pub sun: [f32; 4],
    /// Moon direction, illuminated fraction.
    pub moon: [f32; 4],
    /// Direct light colours, w = intensity.
    pub sun_col: [f32; 4],
    pub moon_col: [f32; 4],
    pub zenith: [f32; 4],
    pub horizon: [f32; 4],
    /// Twilight glow towards the sun, w = strength.
    pub glow: [f32; 4],
    /// Belt of Venus opposite the sun, w = strength (earth shadow under it).
    pub belt: [f32; 4],
    /// Ambient sky light, w = star visibility.
    pub ambient: [f32; 4],
    /// Deep water colour, w = night (0 day .. 1 night).
    pub water: [f32; 4],
    /// Wind (0..1), storm (0..1), rain (0..1), low cloud cover (0..1).
    pub wx: [f32; 4],
    /// High cloud, haze, whitecaps, gust now (0..1).
    pub wx2: [f32; 4],
    /// Direction the wind blows TO (x, z), wind in knots, cumulus towers (0..1).
    pub wind: [f32; 4],
    /// Cumulus deck offset (xy), cirrus offset (zw), in noise cells.
    pub cloud_off: [f32; 4],
    /// Per wave: direction of travel (x, z), wavenumber (rad/m), amplitude (m).
    pub waves: [[f32; 4]; 6],
    /// Wave phases 0..5; [1].z ripple amplitude, [1].w ripple frequency (cells/m).
    pub phase: [[f32; 4]; 2],
    /// Crest sharpness 0..5; [1].zw gust-patch offset (cells).
    pub sharp: [[f32; 4]; 2],
    /// Ripple layer offsets (cells): xy fine, zw coarse.
    pub ripple_off: [f32; 4],
    /// Short chop for the normals only: direction (x, z), wavenumber, amplitude.
    pub detail: [[f32; 4]; 12],
    /// Their phases.
    pub dphase: [[f32; 4]; 3],
    /// Boat frame in world: forward.w = heel, up.w = pitch, starboard.w = boat
    /// speed (m/s), position.w = wake strength.
    pub boat_f: [f32; 4],
    pub boat_u: [f32; 4],
    pub boat_s: [f32; 4],
    pub boat_p: [f32; 4],
    /// Main: trim (rad, + = boom to starboard), camber, reef (0..1), slack (0..1).
    pub sail: [f32; 4],
    /// Jib trim, jib furled (0..1), flutter phase, horizon towers' drift (cells).
    pub sail2: [f32; 4],
    /// The boat box on the output (px): x0, y0, x1, y1.
    pub boat_box: [f32; 4],
    /// Waterline y at the boat (px), boat x (px), px per metre at the boat, nav light.
    pub boat_misc: [f32; 4],
    /// World direction -> celestial (equatorial) rows.
    pub cel: [[f32; 4]; 3],
    /// Flash (0..1+), bolt alpha, bolt width (px), seed.
    pub lightning: [f32; 4],
    /// Bolt polyline, 8 points (px).
    pub bolt: [[f32; 4]; 4],
    /// Gulls: x, y (px), size (px, 0 = none), wing (−1..1).
    pub birds: [[f32; 4]; 3],
    /// Masthead tricolour: x, y (px), radius (px, 0 = off), colour (0 white, 1 red, 2 green).
    pub nav: [f32; 4],
    /// Exposure, saturation, grain seed, vignette.
    pub grade: [f32; 4],
    /// Rain drift (cells), rain slant, foam, horizon y (px).
    pub misc: [f32; 4],
    /// Sunlight on the clouds (they keep it a few degrees after sunset), w = strength.
    pub cloud_light: [f32; 4],
    /// The scene pass's scale (fraction of the output), its inverse.
    pub scale: [f32; 4],
    /// Mercury, Venus, Mars, Jupiter, Saturn: world direction, apparent magnitude.
    pub planets: [[f32; 4]; 5],
}

// --- Small maths -------------------------------------------------------------------

type V3 = [f64; 3];
fn add(a: V3, b: V3) -> V3 { [a[0] + b[0], a[1] + b[1], a[2] + b[2]] }
fn sub(a: V3, b: V3) -> V3 { [a[0] - b[0], a[1] - b[1], a[2] - b[2]] }
fn mul(a: V3, k: f64) -> V3 { [a[0] * k, a[1] * k, a[2] * k] }
fn dot(a: V3, b: V3) -> f64 { a[0] * b[0] + a[1] * b[1] + a[2] * b[2] }
fn cross(a: V3, b: V3) -> V3 { [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]] }
fn norm(a: V3) -> V3 { mul(a, 1.0 / dot(a, a).sqrt().max(1e-12)) }
fn f4(a: V3, w: f64) -> [f32; 4] { [a[0] as f32, a[1] as f32, a[2] as f32, w as f32] }
fn rot(v: V3, axis: V3, ang: f64) -> V3 {
    // Rodrigues
    let (s, c) = ang.sin_cos();
    add(add(mul(v, c), mul(cross(axis, v), s)), mul(axis, dot(axis, v) * (1.0 - c)))
}
fn smoothstep(e0: f64, e1: f64, x: f64) -> f64 {
    let t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}
fn mix(a: f64, b: f64, t: f64) -> f64 { a + (b - a) * t }
fn mix3(a: V3, b: V3, t: f64) -> V3 { [mix(a[0], b[0], t), mix(a[1], b[1], t), mix(a[2], b[2], t)] }
/// Compass bearing (degrees, from north) to a horizontal world direction.
fn compass(deg: f64) -> V3 {
    let r = deg.to_radians();
    [r.sin(), 0.0, -r.cos()]
}
fn hex(c: u32) -> V3 {
    [((c >> 16) & 255) as f64 / 255.0, ((c >> 8) & 255) as f64 / 255.0, (c & 255) as f64 / 255.0]
}
fn hash(n: u64) -> f64 {
    let mut z = n.wrapping_add(0x9e37_79b9_7f4a_7c15);
    z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    ((z ^ (z >> 31)) >> 11) as f64 / (1u64 << 53) as f64
}
/// Eases `x` towards `target` with time constant `tau` over `dt`.
fn ease(x: &mut f64, target: f64, dt: f64, tau: f64) {
    *x += (target - *x) * (1.0 - (-dt / tau).exp());
}
fn ease_v(v: &mut [f64; 2], target: [f64; 2], dt: f64, tau: f64) {
    ease(&mut v[0], target[0], dt, tau);
    ease(&mut v[1], target[1], dt, tau);
}
fn wrap(x: f64) -> f64 { x.rem_euclid(NOISE_PERIOD) }

// --- Sky palette, keyed on the sun's altitude ------------------------------------

struct Palette {
    zenith: V3,
    horizon: V3,
    glow: V3,
    glow_k: f64,
    belt_k: f64,
    sun: V3,
    sun_k: f64,
}

fn palette(alt: f64) -> Palette {
    // (altitude°, zenith, horizon, glow towards the sun, glow strength, belt of Venus, sunlight, sunlight strength)
    const KEYS: [(f64, u32, u32, u32, f64, f64, u32, f64); 10] = [
        (-90.0, 0x05070f, 0x0c1222, 0x000000, 0.0, 0.0, 0x000000, 0.0),
        (-18.0, 0x070b18, 0x111a30, 0x101020, 0.0, 0.0, 0x000000, 0.0),
        (-12.0, 0x0c1634, 0x1d2a50, 0x2c1e3a, 0.35, 0.0, 0x000000, 0.0),
        (-7.0, 0x172a58, 0x3e4c7c, 0x9a4e52, 0.75, 0.25, 0x000000, 0.0),
        (-3.5, 0x24386a, 0x86607e, 0xe2743e, 1.0, 0.7, 0x000000, 0.0),
        (0.0, 0x2f4470, 0xd08c76, 0xff9448, 1.0, 0.8, 0xff7a3a, 0.55),
        (3.0, 0x2a4a7e, 0xe0a882, 0xffa456, 0.85, 0.35, 0xff9850, 0.85),
        (9.0, 0x355a8a, 0xd6c4ae, 0xffc88a, 0.5, 0.0, 0xffc488, 1.0),
        (25.0, 0x36659c, 0xb6c8d4, 0xfff0d2, 0.25, 0.0, 0xffefd8, 1.1),
        (90.0, 0x32649e, 0xaec6d8, 0xfff6e6, 0.2, 0.0, 0xfff6ea, 1.15),
    ];
    let mut i = 0;
    while i + 2 < KEYS.len() && alt > KEYS[i + 1].0 {
        i += 1;
    }
    let (a, b) = (KEYS[i], KEYS[i + 1]);
    let t = smoothstep(a.0, b.0, alt);
    Palette {
        zenith: mix3(hex(a.1), hex(b.1), t),
        horizon: mix3(hex(a.2), hex(b.2), t),
        glow: mix3(hex(a.3), hex(b.3), t),
        glow_k: mix(a.4, b.4, t),
        belt_k: mix(a.5, b.5, t),
        sun: mix3(hex(a.6), hex(b.6), t),
        sun_k: mix(a.7, b.7, t),
    }
}

// --- Waves (the shader evaluates the same) ---------------------------------------

#[derive(Clone, Copy, Default)]
struct Wave {
    dir: [f64; 2],
    k: f64,
    amp: f64,
    sharp: f64,
}

fn wave_height(waves: &[Wave; 6], phase: &[f64; 6], x: f64, z: f64) -> f64 {
    let mut h = 0.0;
    for (w, ph) in waves.iter().zip(phase) {
        let th = w.k * (w.dir[0] * x + w.dir[1] * z) - ph;
        let b = 0.5 * (th.sin() + 1.0);
        let k = w.sharp - 1.0;
        h += w.amp * (2.0 * (b + k * (b * b - b)) - 1.0);
    }
    h
}

// --- The world -----------------------------------------------------------------------

/// The weather as eased state (what the frame shows).
#[derive(Clone, Copy)]
struct Eased {
    wind: f64,
    gust: f64,
    wind_to: [f64; 2],
    cloud_low: f64,
    cloud_high: f64,
    cloud_total: f64,
    rain: f64,
    storm: f64,
    vis: f64,
    wave_m: f64,
    wave_to: [f64; 2],
    wave_t: f64,
    swell_m: f64,
    swell_to: [f64; 2],
    swell_t: f64,
}

impl Eased {
    fn target(w: &Weather) -> Self {
        let to = |from: f64| {
            let v = compass(from + 180.0);
            [v[0], v[2]]
        };
        let rain_codes = matches!(w.code, 61..=67 | 80..=82);
        Eased {
            wind: w.wind_kt.max(0.0),
            gust: w.gust_kt.max(w.wind_kt),
            wind_to: to(w.wind_from),
            cloud_low: w.cloud_low,
            cloud_high: w.cloud_high,
            cloud_total: w.cloud_total.max(w.cloud_low),
            rain: smoothstep(0.0, 6.0, w.rain_mm).max(if rain_codes { 0.25 } else { 0.0 }),
            storm: if w.thunder() { 1.0 } else { 0.0 },
            vis: w.visibility_m.clamp(500.0, 50_000.0),
            wave_m: w.wave_m.clamp(0.05, 6.0),
            wave_to: to(w.wave_from),
            wave_t: w.wave_period.clamp(2.5, 14.0),
            swell_m: w.swell_m.clamp(0.0, 4.0),
            swell_to: to(w.swell_from),
            swell_t: w.swell_period.clamp(5.0, 18.0),
        }
    }
    /// Field order of the shared state (see sync.rs).
    fn to_vec(&self) -> Vec<f64> {
        let e = self;
        vec![
            e.wind, e.gust, e.wind_to[0], e.wind_to[1], e.cloud_low, e.cloud_high, e.cloud_total, e.rain, e.storm, e.vis, e.wave_m,
            e.wave_to[0], e.wave_to[1], e.wave_t, e.swell_m, e.swell_to[0], e.swell_to[1], e.swell_t,
        ]
    }
    fn from_slice(v: &[f64]) -> Self {
        Eased {
            wind: v[0],
            gust: v[1],
            wind_to: [v[2], v[3]],
            cloud_low: v[4],
            cloud_high: v[5],
            cloud_total: v[6],
            rain: v[7],
            storm: v[8],
            vis: v[9],
            wave_m: v[10],
            wave_to: [v[11], v[12]],
            wave_t: v[13],
            swell_m: v[14],
            swell_to: [v[15], v[16]],
            swell_t: v[17],
        }
    }
    fn ease_to(&mut self, t: &Eased, dt: f64) {
        const TAU: f64 = 90.0;
        ease(&mut self.wind, t.wind, dt, TAU);
        ease(&mut self.gust, t.gust, dt, TAU);
        ease_v(&mut self.wind_to, t.wind_to, dt, TAU);
        ease(&mut self.cloud_low, t.cloud_low, dt, TAU * 1.5);
        ease(&mut self.cloud_high, t.cloud_high, dt, TAU * 1.5);
        ease(&mut self.cloud_total, t.cloud_total, dt, TAU * 1.5);
        ease(&mut self.rain, t.rain, dt, TAU * 0.6);
        ease(&mut self.storm, t.storm, dt, TAU);
        ease(&mut self.vis, t.vis, dt, TAU);
        ease(&mut self.wave_m, t.wave_m, dt, TAU * 1.5);
        ease_v(&mut self.wave_to, t.wave_to, dt, TAU * 1.5);
        ease(&mut self.wave_t, t.wave_t, dt, TAU * 1.5);
        ease(&mut self.swell_m, t.swell_m, dt, TAU * 1.5);
        ease_v(&mut self.swell_to, t.swell_to, dt, TAU * 1.5);
        ease(&mut self.swell_t, t.swell_t, dt, TAU * 1.5);
    }
}

/// Everything that persists between frames. One per process; every output
/// asks it for its own [`Globals`].
pub struct World {
    over: Overrides,
    feed: weather::Feed,
    eased: Option<Eased>,
    last: Option<f64>,
    /// Animation clock (s since start, f64).
    anim: f64,
    /// Sky clock offset: forced time minus the wall clock at start.
    sky_shift: f64,
    waves: [Wave; 6],
    phase: [f64; 6],
    detail: [Wave; 12],
    dphase: [f64; 12],
    ripple: [f64; 4],
    gust_off: [f64; 2],
    cloud: [f64; 4],
    towers: f64,
    rain_off: f64,
    flutter: f64,
    heading: f64,
    tack_right: bool,
    speed: f64,
    heel: f64,
    motion: [f64; 3],
    cam_motion: [f64; 3],
    frames: u64,
    state: Option<FrameState>,
    debug: bool,
    sky_interval: f64,
    /// Where the animation state is shared with the other scene processes
    /// (None for forced previews, which must not mix with the live scene).
    sync_path: Option<std::path::PathBuf>,
    last_sync: f64,
}

impl World {
    /// With the SAILBOAT_* environment overrides.
    pub fn new() -> Self {
        Self::with_overrides(Overrides::from_env())
    }

    pub fn with_overrides(over: Overrides) -> Self {
        let feed = weather::Feed::new(LAT, LON, MARINE, over.offline);
        World {
            feed,
            eased: None,
            last: None,
            anim: 0.0,
            sky_shift: 0.0,
            waves: [Wave::default(); 6],
            phase: [0.0; 6],
            detail: [Wave::default(); 12],
            dphase: [0.0; 12],
            ripple: [0.0; 4],
            gust_off: [0.0; 2],
            cloud: [0.0; 4],
            towers: 0.0,
            rain_off: 0.0,
            flutter: 0.0,
            heading: f64::NAN,
            tack_right: true,
            speed: 0.0,
            heel: 0.0,
            motion: [0.0; 3],
            cam_motion: [0.0; 3],
            frames: 0,
            state: None,
            debug: std::env::var("SAILBOAT_DEBUG").is_ok_and(|v| v == "foam"),
            // SAILBOAT_SKY_HZ: how often the clouds are redrawn (default 10).
            sky_interval: std::env::var("SAILBOAT_SKY_HZ")
                .ok()
                .and_then(|v| v.parse::<f64>().ok())
                .filter(|&hz| hz > 0.0)
                .map_or(SKY_INTERVAL, |hz| 1.0 / hz),
            sync_path: if over.is_live() { sync::path() } else { None },
            last_sync: f64::NEG_INFINITY,
            over,
        }
    }

    /// Everything that integrates over time, in the order [`World::adopt`] reads it.
    fn snapshot(&self) -> Option<Vec<f64>> {
        let eased = self.eased?;
        let mut v = vec![self.anim];
        v.extend(self.phase);
        v.extend(self.dphase);
        v.extend(self.ripple);
        v.extend(self.gust_off);
        v.extend(self.cloud);
        v.extend([self.towers, self.rain_off, self.flutter, self.heading, if self.tack_right { 1.0 } else { 0.0 }, self.speed, self.heel]);
        v.extend(self.motion);
        v.extend(self.cam_motion);
        v.extend(eased.to_vec());
        Some(v)
    }

    /// Takes over the state another process wrote (see sync.rs) and runs it
    /// forward to `now`, so this instance continues the same sea and sky.
    fn adopt(&mut self, now: f64) {
        let Some(path) = &self.sync_path else { return };
        let Some((at, v)) = sync::read(path) else { return };
        if v.len() != 1 + 6 + 12 + 4 + 2 + 4 + 7 + 3 + 3 + 18
            || !(0.0..=sync::MAX_AGE).contains(&(now - at))
            || v.iter().enumerate().any(|(i, x)| !x.is_finite() && i != 1 + 6 + 12 + 4 + 2 + 4 + 3)
        {
            return;
        }
        let mut it = v.into_iter();
        let mut take = |n: usize| it.by_ref().take(n).collect::<Vec<f64>>();
        self.anim = take(1)[0];
        self.phase.copy_from_slice(&take(6));
        self.dphase.copy_from_slice(&take(12));
        self.ripple.copy_from_slice(&take(4));
        self.gust_off.copy_from_slice(&take(2));
        self.cloud.copy_from_slice(&take(4));
        let s = take(7);
        (self.towers, self.rain_off, self.flutter, self.heading, self.tack_right, self.speed, self.heel) =
            (s[0], s[1], s[2], s[3], s[4] > 0.5, s[5], s[6]);
        self.motion.copy_from_slice(&take(3));
        self.cam_motion.copy_from_slice(&take(3));
        self.eased = Some(Eased::from_slice(&take(18)));
        self.last = Some(at);
        // Same steps as the process that wrote it would have taken.
        let mut t = at;
        while now - t > 5.0 {
            t += 5.0;
            self.advance(t);
        }
    }

    /// Advances the world to `now` (unix seconds). Call once per frame; a
    /// second call at the same moment (another output) is a no-op.
    pub fn update(&mut self, now: f64) {
        let gap = self.last.map_or(f64::INFINITY, |l| now - l);
        if self.last.is_some() && gap <= 0.0 {
            return;
        }
        // First frame or back after a pause: continue from the freshest shared
        // state if there is one, else start (or snap) from the weather alone.
        if gap > 120.0 {
            self.adopt(now);
        }
        self.advance(now);
        if self.sync_path.is_some() && now - self.last_sync >= sync::WRITE_EVERY {
            self.last_sync = now;
            if let (Some(path), Some(v)) = (&self.sync_path, self.snapshot()) {
                sync::write(path, now, &v);
            }
        }
    }

    fn advance(&mut self, now: f64) {
        let gap = self.last.map_or(f64::INFINITY, |l| now - l);
        if self.last.is_some() && gap <= 0.0 {
            return;
        }
        // After a long pause (another scene showed, or the screen was off)
        // snap to the present instead of easing in from hours ago.
        let resume = self.last.is_some() && gap > 120.0;
        if resume {
            self.eased = None;
            self.heading = f64::NAN;
        }
        let first = self.last.is_none() || resume;
        let dt = if first { 0.0 } else { gap.clamp(0.0, 5.0) };
        if self.last.is_none() {
            if let Some(t) = self.over.time {
                self.sky_shift = t - now;
            }
            // A fixed but time-dependent start so phases differ run to run.
            self.anim = now.rem_euclid(3600.0);
            // Scattered starting phases: all crests lined up at the camera would
            // draw an egg-crate pattern until they drift apart.
            for i in 0..6 {
                self.phase[i] = hash(i as u64 + 4242) * TAU;
            }
            for i in 0..12 {
                self.dphase[i] = hash(i as u64 + 9191) * TAU;
            }
        }
        self.last = Some(now);
        self.anim += dt;
        self.frames = self.frames.wrapping_add(1);

        self.feed.poll(now);
        let mut wx = self.feed.current(now);
        self.over.apply(&mut wx);
        let target = Eased::target(&wx);
        let e = self.eased.get_or_insert(target);
        e.ease_to(&target, dt);
        let e = *e;

        // --- Wind now: gusts come and go on a pseudo-random schedule.
        let t = self.anim;
        let g = (0.5 + 0.22 * (t * 0.071).sin() + 0.17 * (t * 0.163 + 1.3).sin() + 0.11 * (t * 0.37 + 4.1).sin()).clamp(0.0, 1.0);
        let gust_now = e.wind + (e.gust - e.wind) * smoothstep(0.45, 0.95, g);
        let wind_ms = gust_now * KT;
        let wind_to = norm([e.wind_to[0], 0.0, e.wind_to[1]]);

        // --- Boat: a reach on whichever tack is more broadside to the camera.
        let off_wind = |hdg: f64| {
            let f = compass(hdg);
            dot(f, mul(wind_to, -1.0)).clamp(-1.0, 1.0).acos().to_degrees()
        };
        let right = CAM_HEADING + 58.0;
        let left = CAM_HEADING - 58.0;
        let score = |hdg: f64| (off_wind(hdg) - 105.0).abs();
        let (sr, sl) = (score(right), score(left));
        if self.tack_right && sl + 25.0 < sr {
            self.tack_right = false;
        } else if !self.tack_right && sr + 25.0 < sl {
            self.tack_right = true;
        }
        let target_hdg = if self.tack_right { right } else { left };
        if self.heading.is_nan() {
            self.heading = target_hdg;
        } else {
            let d = ((target_hdg - self.heading + 540.0).rem_euclid(360.0)) - 180.0;
            self.heading += d * (1.0 - (-dt / 25.0).exp());
        }
        let fwd = compass(self.heading);
        let stbd = cross(fwd, [0.0, 1.0, 0.0]);
        // True wind angle off the bow and side (+ = wind from starboard).
        let twa = off_wind(self.heading).to_radians();
        let side = if dot(mul(wind_to, -1.0), stbd) >= 0.0 { 1.0 } else { -1.0 };
        let reef = smoothstep(21.0, 29.0, e.gust).max(e.storm);
        let sailing = smoothstep(0.6, 1.2, twa); // 0 in irons
        let target_speed = 3.7 * smoothstep(1.0, 15.0, gust_now) * sailing * (1.0 - 0.2 * reef);
        if first {
            self.speed = target_speed;
        }
        ease(&mut self.speed, target_speed, dt, 6.0);
        // Apparent wind
        let app = sub(mul(wind_to, wind_ms), mul(fwd, self.speed));
        let app_ms = dot(app, app).sqrt();
        let awa = dot(fwd, mul(norm(app), -1.0)).clamp(-1.0, 1.0).acos();
        let app_kt = app_ms / KT;
        let slack = 1.0 - smoothstep(2.0, 7.0, app_kt);
        let trim = (awa * 0.5).clamp(0.14, 1.45) * -side; // boom away from the wind
        let heel_target = 24.0 * smoothstep(3.0, 20.0, app_kt) * awa.sin().max(0.0).powf(0.6) * (1.0 - 0.35 * reef) * -side;
        if first {
            self.heel = heel_target;
        }
        ease(&mut self.heel, heel_target, dt, 2.5);

        // --- Waves: 2 swell + 4 wind-sea components from the eased sea state.
        let hs_wind = (e.wave_m * e.wave_m - e.swell_m * e.swell_m).max(0.0).sqrt().max(0.04 + 0.02 * e.wind);
        let calm = 1.0 - smoothstep(1.0, 8.0, e.wind);
        let hs_swell = e.swell_m.max(0.12);
        let rot2 = |v: [f64; 2], deg: f64| {
            let (s, c) = deg.to_radians().sin_cos();
            [v[0] * c - v[1] * s, v[0] * s + v[1] * c]
        };
        let n2 = |v: [f64; 2]| {
            let l = (v[0] * v[0] + v[1] * v[1]).sqrt().max(1e-9);
            [v[0] / l, v[1] / l]
        };
        let swell_dir = n2(e.swell_to);
        let sea_dir = n2(e.wave_to);
        let wind_t = e.wave_t.min(1.2 + 0.32 * e.wind.max(3.0)).max(2.5);
        let steep = smoothstep(8.0, 28.0, e.wind);
        // (direction, period, share of Hs², sharpness)
        let comps: [([f64; 2], f64, f64, f64); 6] = [
            (rot2(swell_dir, 8.0), e.swell_t, 0.6, 1.0),
            (rot2(swell_dir, -14.0), e.swell_t * 0.83, 0.4, 1.0),
            (sea_dir, wind_t, 0.42, 1.0 + 0.85 * steep),
            (rot2(sea_dir, 28.0), wind_t * 0.74, 0.28, 1.0 + 0.7 * steep),
            (rot2(sea_dir, -35.0), wind_t * 0.56, 0.18, 1.0 + 0.5 * steep),
            (rot2(sea_dir, 12.0), wind_t * 0.4, 0.12, 1.0 + 0.4 * steep),
        ];
        for (i, &(dir, period, share, sharp)) in comps.iter().enumerate() {
            let hs = if i < 2 { hs_swell } else { hs_wind };
            let omega = TAU / period.max(1.0);
            let k = omega * omega / G;
            // Hs = 4·sqrt(Σa²/2), shared out by `share`.
            let amp = hs / 4.0 * (2.0 * share).sqrt() * if i < 2 { 1.0 } else { 1.0 - 0.6 * calm };
            self.waves[i] = Wave { dir, k, amp, sharp };
            let doppler = k * (dir[0] * fwd[0] + dir[1] * fwd[2]) * self.speed;
            self.phase[i] = (self.phase[i] + (omega - doppler) * dt).rem_euclid(TAU);
        }

        // Short chop (normals only): a saturated slope spectrum around the wind,
        // a·k ≈ constant, so every scale is equally rough; nearly glassy in a calm.
        let slope = 0.008 + 0.13 * smoothstep(1.0, 24.0, gust_now) + 0.02 * e.rain;
        for i in 0..12 {
            let fi = i as f64;
            let k = 0.22 * 1.46f64.powf(fi) * (0.88 + 0.24 * hash(i as u64 * 53 + 1));
            let spread = (hash(i as u64 * 977 + 13) - 0.5) * 2.0 * 75.0;
            let dir = rot2(sea_dir, spread);
            let amp = slope / k * (0.55 + 0.9 * hash(i as u64 * 31 + 7)) * (1.0 - 0.5 * (spread / 75.0).powi(2)) / (1.0 + (k / 4.0).powi(2));
            self.detail[i] = Wave { dir, k, amp, sharp: 1.0 };
            let omega = (G * k).sqrt();
            let doppler = k * (dir[0] * fwd[0] + dir[1] * fwd[2]) * self.speed;
            self.dphase[i] = (self.dphase[i] + (omega - doppler) * dt).rem_euclid(TAU);
        }

        // --- Drifting layers (all in noise cells, wrapped).
        let water_v = [fwd[0] * self.speed, fwd[2] * self.speed];
        let ripple_freq = 0.55;
        // Water offsets in metres, wrapped at 1024 m: the shader's water noise
        // uses frequencies in sixteenths of a cycle per metre, so 1024 m is a
        // whole number of its 64-cell tiles and the wrap is seamless.
        let drift = 0.35 * e.wind * KT * 0.05; // short ripples creep with the wind
        let wrap_m = |x: f64| x.rem_euclid(1024.0);
        self.ripple[0] = wrap_m(self.ripple[0] + water_v[0] * dt);
        self.ripple[1] = wrap_m(self.ripple[1] + water_v[1] * dt);
        self.ripple[2] = wrap_m(self.ripple[2] + (water_v[0] + wind_to[0] * drift) * dt);
        self.ripple[3] = wrap_m(self.ripple[3] + (water_v[1] + wind_to[2] * drift) * dt);
        // Cat's paws: gust patches crossing the water with the wind.
        let gv = e.wind * KT * 0.9;
        self.gust_off[0] = wrap(self.gust_off[0] + (wind_to[0] * gv + water_v[0]) * dt * 0.02);
        self.gust_off[1] = wrap(self.gust_off[1] + (wind_to[2] * gv + water_v[1]) * dt * 0.02);
        // Clouds: wind aloft ~1.6× the surface wind, in km on a 1.4 km deck.
        let aloft = (e.wind * KT * 1.6).max(1.5);
        self.cloud[0] = wrap(self.cloud[0] + wind_to[0] * aloft * dt * 0.0005);
        self.cloud[1] = wrap(self.cloud[1] + wind_to[2] * aloft * dt * 0.0005);
        self.cloud[2] = wrap(self.cloud[2] + wind_to[0] * aloft * 1.8 * dt * 0.0004);
        self.cloud[3] = wrap(self.cloud[3] + wind_to[2] * aloft * 1.8 * dt * 0.0004);
        // Horizon towers slide sideways with the cross-screen wind.
        let cam_right = cross(compass(CAM_HEADING), [0.0, 1.0, 0.0]);
        self.towers = wrap(self.towers + dot(wind_to, cam_right) * aloft * dt * 0.0012);
        self.rain_off = wrap(self.rain_off + dt * 2.6);
        self.flutter = (self.flutter + dt * (5.0 + 9.0 * smoothstep(0.0, 12.0, app_kt))).rem_euclid(TAU);

        // --- Boat motion: the hull floats on the very surface the shader draws. Heave, pitch and
        // roll are a least-squares plane through that height field over the hull's footprint (so
        // waves shorter than the boat average out, as they do on a real hull), with no smoothing
        // or scaling: the waterline the shader cuts into the hull is where the water really is.
        let p = boat_pos();
        let hw = |q: V3| wave_height(&self.waves, &self.phase, q[0], q[2]);
        const XS: [f64; 5] = [-4.2, -2.1, 0.0, 2.2, 4.4];
        const ZS: [f64; 3] = [-1.3, 0.0, 1.3];
        let (mut sh, mut sx, mut sz) = (0.0, 0.0, 0.0);
        for &x in &XS {
            for &z in &ZS {
                let h = hw(add(p, add(mul(fwd, x), mul(stbd, z))));
                sh += h;
                sx += h * x;
                sz += h * z;
            }
        }
        let n = (XS.len() * ZS.len()) as f64;
        let xm = XS.iter().sum::<f64>() / XS.len() as f64;
        let hm = sh / n;
        let sxx: f64 = XS.iter().map(|x| (x - xm) * (x - xm)).sum::<f64>() * ZS.len() as f64;
        let szz: f64 = ZS.iter().map(|z| z * z).sum::<f64>() * XS.len() as f64;
        let slope_x = (sx - xm * sh) / sxx;
        let slope_z = sz / szz;
        // Rocking damped: pitch/roll were too lively; heave follows the waves fully.
        // SAILBOAT_HEAVE / SAILBOAT_PITCH / SAILBOAT_ROLL scale each (defaults 1.0 / 0.25 / 0.25).
        let tun = tunables();
        let target = [(hm - slope_x * xm) * tun.heave, slope_x.atan() * tun.pitch, slope_z.atan() * 0.9 * tun.roll];
        self.motion = target;
        let c = [0.0, 0.0, 0.0];
        // The camera only breathes with the sea: a little heave, at most about
        // a degree of pitch and roll even in a storm.
        let cam_target = [
            hw(c) * 0.25,
            (((hw([3.0, 0.0, 0.0]) - hw([-3.0, 0.0, 0.0])) / 6.0).atan() * 0.12).clamp(-0.012, 0.012),
            (((hw([0.0, 0.0, 3.0]) - hw([0.0, 0.0, -3.0])) / 6.0).atan() * 0.1).clamp(-0.02, 0.02),
        ];
        for i in 0..3 {
            if first {
                self.cam_motion[i] = cam_target[i];
            }
            ease(&mut self.cam_motion[i], cam_target[i], dt, 2.5);
        }

        self.state = Some(FrameState {
            e,
            gust_now,
            slack,
            trim,
            reef,
            fwd,
            app_kt,
            calm,
            ripple_freq,
        });
    }

    /// Is the sky texture due for a redraw, given when it was last drawn?
    pub fn sky_due(&self, last_drawn: Option<f64>, now: f64) -> bool {
        last_drawn.is_none_or(|l| now - l >= self.sky_interval || now < l)
    }

    /// The uniforms for one output at the last [`World::update`].
    pub fn globals(&self, w: u32, h: u32) -> Globals {
        let mut g: Globals = bytemuck::Zeroable::zeroed();
        let Some(st) = self.state else { return g };
        let e = st.e;
        let (wf, hf) = (w.max(1) as f64, h.max(1) as f64);
        let aspect = wf / hf;
        let now = self.last.unwrap_or(0.0);
        let sky_t = now + self.sky_shift;
        let sky = astro::sky(sky_t, LAT, LON);

        // --- Cameras: the steady one for the sky texture, the bobbing one for the frame.
        let up0 = [0.0, 1.0, 0.0];
        let f0 = compass(CAM_HEADING);
        let r0 = cross(f0, up0);
        let pitch = CAM_PITCH.to_radians();
        let sky_f = rot(f0, r0, pitch);
        let sky_u = rot(up0, r0, pitch);
        let [heave, cpitch, croll] = self.cam_motion;
        let cf = rot(sky_f, r0, cpitch);
        let cu = rot(sky_u, r0, cpitch);
        let cu = rot(cu, cf, croll);
        let cr = cross(cf, cu);
        let cam = [0.0, CAM_HEIGHT + heave, 0.0];
        g.cam_pos = f4(cam, TAN_HALF_FOV);
        g.cam_right = f4(cr, aspect);
        g.cam_up = f4(cu, 0.0);
        g.cam_fwd = f4(cf, 0.0);
        g.sky_right = f4(r0, TAN_HALF_FOV * SKY_MARGIN);
        g.sky_up = f4(sky_u, aspect);
        g.sky_fwd = f4(sky_f, 0.0);
        let project = |p: V3| -> Option<[f64; 2]> {
            let rel = sub(p, cam);
            let z = dot(rel, cf);
            if z <= 0.1 {
                return None;
            }
            let x = dot(rel, cr) / (z * TAN_HALF_FOV * aspect);
            let y = dot(rel, cu) / (z * TAN_HALF_FOV);
            Some([(x * 0.5 + 0.5) * wf, (0.5 - y * 0.5) * hf])
        };

        // --- Light
        let sun_alt = sky.sun[1].asin().to_degrees();
        let moon_alt = sky.moon[1].asin().to_degrees();
        let pal = palette(sun_alt);
        let overcast = (smoothstep(0.6, 1.0, e.cloud_total) * 0.6 + e.storm * 0.6 + e.rain * 0.3).min(1.0);
        let grey = |c: V3, k: f64, dark: f64| {
            let l = 0.3 * c[0] + 0.55 * c[1] + 0.15 * c[2];
            mul(mix3(c, [l * 0.92, l * 0.97, l * 1.08], k), 1.0 - dark)
        };
        let gloom = e.storm * 0.55 + e.rain * 0.2;
        g.zenith = f4(grey(pal.zenith, overcast * 0.55, gloom * 0.6), 0.0);
        g.horizon = f4(grey(pal.horizon, overcast * 0.5, gloom * 0.5), 0.0);
        g.glow = f4(pal.glow, pal.glow_k * (1.0 - 0.6 * overcast));
        g.belt = f4(hex(0xd08ca0), pal.belt_k * (1.0 - 0.8 * overcast));
        let cl = palette(sun_alt + 4.5);
        g.cloud_light = f4(cl.sun, cl.sun_k * (1.0 - 0.55 * overcast) * (1.0 - 0.6 * e.storm));
        let sun_vis = smoothstep(-1.0, 1.5, sun_alt);
        let direct = pal.sun_k * (1.0 - 0.7 * overcast) * (1.0 - 0.5 * e.storm);
        g.sun = f4(sky.sun, sun_vis * (1.0 - 0.85 * e.storm));
        g.sun_col = f4(pal.sun, direct);
        let moon_up = smoothstep(-1.0, 6.0, moon_alt);
        g.moon = f4(sky.moon, sky.moon_illum);
        let night = 1.0 - smoothstep(-10.0, -1.0, sun_alt);
        g.moon_col = f4(hex(0xb8c8ec), 0.55 * sky.moon_illum.powf(1.5) * moon_up * night * (1.0 - 0.7 * overcast));
        let amb = mix3(pal.horizon, pal.zenith, 0.5);
        let star_vis = smoothstep(-5.0, -14.0, sun_alt) * (1.0 - 0.45 * sky.moon_illum * moon_up);
        g.ambient = f4(grey(amb, overcast * 0.6, gloom * 0.5), star_vis);
        let water = mix3(hex(0x0f3a4e), hex(0x0b2d3e), smoothstep(0.0, 1.0, e.wind / 25.0));
        g.water = f4(grey(water, e.storm * 0.4, 0.0), night);
        for (i, row) in sky.celestial.iter().enumerate() {
            g.cel[i] = f4(*row, 0.0);
        }
        for (i, p) in sky.planets.iter().enumerate() {
            g.planets[i] = [p[0] as f32, p[1] as f32, p[2] as f32, p[3] as f32];
        }

        // --- Weather
        let wind01 = smoothstep(0.0, 30.0, e.wind);
        let haze = 1.0 - smoothstep(2_000.0, 30_000.0, e.vis);
        let whitecap = smoothstep(10.0, 24.0, st.gust_now);
        let gust01 = smoothstep(0.0, 1.0, (st.gust_now - e.wind) / (e.gust - e.wind).max(1.0));
        g.wx = [wind01 as f32, e.storm as f32, e.rain as f32, e.cloud_low as f32];
        g.wx2 = [e.cloud_high as f32, haze as f32, whitecap as f32, gust01 as f32];
        let towers = smoothstep(0.03, 0.5, e.cloud_low).max(e.storm);
        g.wind = [e.wind_to[0] as f32, e.wind_to[1] as f32, e.wind as f32, towers as f32];
        g.cloud_off = [self.cloud[0] as f32, self.cloud[1] as f32, self.cloud[2] as f32, self.cloud[3] as f32];
        for i in 0..6 {
            let wv = self.waves[i];
            g.waves[i] = [wv.dir[0] as f32, wv.dir[1] as f32, wv.k as f32, wv.amp as f32];
            g.phase[i / 4][i % 4] = self.phase[i] as f32;
            g.sharp[i / 4][i % 4] = wv.sharp as f32;
        }
        for i in 0..12 {
            let wv = self.detail[i];
            g.detail[i] = [wv.dir[0] as f32, wv.dir[1] as f32, wv.k as f32, wv.amp as f32];
            g.dphase[i / 4][i % 4] = self.dphase[i] as f32;
        }
        let ripple_amp = 0.02 + 0.5 * smoothstep(1.5, 20.0, e.wind);
        g.phase[1][2] = ripple_amp as f32;
        g.phase[1][3] = st.ripple_freq as f32;
        g.sharp[1][2] = self.gust_off[0] as f32;
        g.sharp[1][3] = self.gust_off[1] as f32;
        g.ripple_off = [self.ripple[0] as f32, self.ripple[1] as f32, self.ripple[2] as f32, self.ripple[3] as f32];

        // --- Boat
        let p0 = boat_pos();
        let [heave_b, pitch_b, roll_b] = self.motion;
        let fwd = st.fwd;
        let mut bf = fwd;
        let mut bu = [0.0, 1.0, 0.0];
        let bs0 = cross(fwd, bu);
        // Bow-up pitch about starboard, then roll (heel + waves) about forward.
        bf = rot(bf, bs0, pitch_b);
        bu = rot(bu, bs0, pitch_b);
        let roll = self.heel.to_radians() + roll_b;
        bu = rot(bu, bf, roll);
        let bs = cross(bf, bu);
        let p = add(p0, [0.0, heave_b - 0.05, 0.0]);
        let wake = smoothstep(0.3, 3.0, self.speed);
        g.boat_f = f4(bf, self.heel);
        g.boat_u = f4(bu, pitch_b);
        g.boat_s = f4(bs, self.speed);
        g.boat_p = f4(p, wake);
        let camber = 0.07 + 0.07 * smoothstep(3.0, 14.0, st.app_kt) - 0.04 * st.reef;
        g.sail = [st.trim as f32, camber as f32, st.reef as f32, st.slack as f32];
        let furl = (smoothstep(24.0, 34.0, e.gust) * 0.55 + e.storm * 0.35).min(0.9);
        g.sail2 = [(st.trim * 0.82) as f32, furl as f32, self.flutter as f32, self.towers as f32];

        let (bw, bh) = box_size(w, h);
        let wl = project(p).unwrap_or([wf * 0.6, hf * 0.62]);
        let top = project(add(p, [0.0, 10.0, 0.0])).unwrap_or([wl[0], wl[1] - 100.0]);
        let px_per_m = (wl[1] - top[1]) / 10.0;
        let x0 = (wl[0] - bw as f64 * 0.5).round();
        let y0 = (wl[1] - bh as f64 * 0.8).round();
        g.boat_box = [x0 as f32, y0 as f32, (x0 + bw as f64) as f32, (y0 + bh as f64) as f32];
        // Masthead tricolour, its colour by the sector the camera is in.
        let nav_on = 1.0 - smoothstep(-6.0, 0.5, sun_alt);
        let top_world = add(p, add(mul(bu, boat::MAST_TOP + 0.15), mul(bf, boat::MAST_X)));
        let to_cam = norm(sub(cam, top_world));
        let ang = dot([to_cam[0], 0.0, to_cam[2]], fwd).clamp(-1.0, 1.0).acos().to_degrees();
        let kind = if ang > 112.5 { 0.0 } else if dot(to_cam, bs0) > 0.0 { 2.0 } else { 1.0 };
        g.boat_misc = [wl[1] as f32, wl[0] as f32, px_per_m as f32, nav_on as f32];
        if let Some(q) = project(top_world) {
            g.nav = [q[0] as f32, q[1] as f32, (nav_on * hf / 1440.0 * 3.0) as f32, kind as f32];
        }
        let horizon_y = project(add(cam, mul(f0, 5000.0))).map_or(hf * 0.58, |q| q[1]);

        // --- Lightning: flashes on a deterministic schedule while stormy.
        let mut flash = 0.0;
        if e.storm > 0.2 {
            let abs = now;
            let bucket = (abs / 1.5).floor() as i64;
            for b in [bucket - 1, bucket] {
                let hsh = hash(b as u64 ^ 0x51ab_0a7);
                if hsh > 0.11 * e.storm {
                    continue;
                }
                let start = b as f64 * 1.5 + hash(b as u64 ^ 0x77) * 0.7;
                let dtf = abs - start;
                if !(0.0..1.2).contains(&dtf) {
                    continue;
                }
                let mut env = 0.0;
                for (k, at) in [0.0, 0.09, 0.23, 0.41].iter().enumerate() {
                    let d = dtf - at;
                    if d >= 0.0 && hash((b as u64) * 7 + k as u64) < 0.75 - k as f64 * 0.12 {
                        env += (-d / 0.06).exp() * (1.0 - 0.18 * k as f64);
                    }
                }
                flash = f64::max(flash, env);
                let seed = hash(b as u64 ^ 0x1234);
                if seed < 0.6 {
                    // A bolt from the cloud base to the sea.
                    let mut x = wf * (0.08 + 0.84 * hash(b as u64 ^ 0x99));
                    let ytop = horizon_y - hf * (0.22 + 0.12 * hash(b as u64 ^ 0x5));
                    for k in 0..8 {
                        let f = k as f64 / 7.0;
                        let y = mix(ytop, horizon_y - 1.0, f);
                        if k > 0 {
                            x += (hash(b as u64 * 31 + k as u64) - 0.5) * hf * 0.05;
                        }
                        g.bolt[k / 2][(k % 2) * 2] = x as f32;
                        g.bolt[k / 2][(k % 2) * 2 + 1] = y as f32;
                    }
                    g.lightning[1] = (env.min(1.0) * smoothstep(1.2, 0.0, dtf)) as f32;
                    g.lightning[2] = (hf / 1440.0 * 2.2) as f32;
                    g.lightning[3] = seed as f32;
                }
            }
        }
        g.lightning[0] = (flash * e.storm.min(1.0)) as f32;

        // --- Gulls by day in fair weather.
        let birds_on = smoothstep(-2.0, 4.0, sun_alt) * (1.0 - smoothstep(0.2, 0.5, e.storm)) * (1.0 - smoothstep(22.0, 30.0, e.wind));
        if birds_on > 0.01 {
            let t = self.anim;
            for i in 0..3 {
                let fi = i as f64;
                let w_ang = (0.06 + 0.015 * fi) * tunables().gull_speed; // SAILBOAT_GULL_SPEED scales the circling
                let a = t * w_ang + fi * 2.1;
                let cx = wf * (0.26 + 0.12 * fi) + hf * 0.1 * (t * 0.022 + fi * 1.7).sin();
                let x = cx + hf * (0.16 + 0.05 * fi) * a.cos();
                let y = hf * (0.24 + 0.05 * fi) + hf * 0.04 * a.sin() + hf * 0.02 * (t * 0.5 + fi).sin();
                // Bursts of flapping between glides.
                let burst = smoothstep(0.3, 0.7, (t * 0.18 + fi * 0.37).sin() * 0.5 + 0.5);
                let wing = (t * (9.0 + 1.5 * fi)).sin() * burst + 0.35 * (1.0 - burst);
                let size = hf / 1440.0 * (13.0 - 2.5 * fi) * birds_on;
                g.birds[i] = [x as f32, y as f32, size as f32, wing as f32];
            }
        }

        g.res = [w as f32, h as f32, self.anim.rem_euclid(3600.0) as f32, if self.debug { 1.0 } else { 0.0 }];
        let exposure = 1.0 + 0.3 * night;
        g.grade = [exposure as f32, (1.0 - 0.35 * e.storm) as f32, (self.frames % 61) as f32, 0.35];
        let slant = -(dot(wind_vec(&e), cross(compass(CAM_HEADING), [0.0, 1.0, 0.0]))) * smoothstep(0.0, 25.0, e.wind) * 0.35;
        g.misc = [self.rain_off as f32, slant as f32, whitecap as f32, horizon_y as f32];
        let (sw, _) = scene_size(w, h);
        let k = sw as f64 / wf;
        g.scale = [k as f32, (1.0 / k) as f32, 0.0, 0.0];
        let _ = (st.calm, PI);
        g
    }
}

impl Default for World {
    fn default() -> Self {
        Self::new()
    }
}

fn wind_vec(e: &Eased) -> V3 {
    norm([e.wind_to[0], 0.0, e.wind_to[1]])
}

/// The boat's mean position (world, waterline).
fn boat_pos() -> V3 {
    let f = compass(CAM_HEADING);
    let r = cross(f, [0.0, 1.0, 0.0]);
    add(mul(f, BOAT_AHEAD), mul(r, BOAT_RIGHT))
}

/// What `update` worked out for `globals`.
#[derive(Clone, Copy)]
struct FrameState {
    e: Eased,
    gust_now: f64,
    slack: f64,
    trim: f64,
    reef: f64,
    fwd: V3,
    app_kt: f64,
    calm: f64,
    ripple_freq: f64,
}
