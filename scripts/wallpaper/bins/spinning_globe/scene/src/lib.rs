//! The spinning globe wallpaper's scene, without any GPU API: the shader, the
//! instance data it draws and the per-frame parameters. Shared by the
//! wallpaper renderer (`../src/main.rs`, wgpu on a layer surface) and the
//! wallpaper selector's live preview (`bevy/apps/spinning_globe`, in-process
//! in Quickshell on wgpu 24), so both draw exactly the same globe.
//!
//! How to draw it (both renderers set this up with their own wgpu version):
//! clear to [`BG`], then `vs_line`/`fs_line` over [`build_continent_lines`]
//! with MAX colour blending, then `vs_point`/`fs_point` over [`build_points`]
//! with ADD blending (One/One both). Each is an instanced 4-vertex triangle
//! strip; one uniform buffer of [`Globals`] at group 0 binding 0 (vertex
//! stage). The target is an 8-bit *non-sRGB* view, so the additive maths and
//! its saturation happen on the encoded bytes, like the old CPU canvas.
mod continents;

use std::f32::consts::PI;

pub use bytemuck;
use continents::ALL_LANDMASSES;

pub const SHADER: &str = include_str!("globe.wgsl");

/// Catppuccin Mocha Base #1e1e2e, the clear colour (encoded 0..1).
pub const BG: [f64; 3] = [30.0 / 255.0, 30.0 / 255.0, 46.0 / 255.0];

const TEAL_GRID_INTENSITY: f32 = 0.25;
const TEAL_OUTLINE_INTENSITY: f32 = 0.5;

/// Radians per second.
pub const ROTATION_SPEED: f64 = 0.15;

/// Rotation at the Unix epoch and every whole spin after it (radians).
pub const BASE_ROTATION: f64 = 0.0;

/// The globe's rotation (radians, 0..2π) at wall-clock time `now`. Both the
/// wallpaper and the selector preview call this, so they show the same face
/// at the same moment however long either has been running or hidden.
pub fn rotation_at(now: std::time::SystemTime) -> f32 {
    use std::f64::consts::TAU;
    let secs = now.duration_since(std::time::UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64());
    let period = TAU / ROTATION_SPEED;
    (BASE_ROTATION + TAU * (secs / period).fract()).rem_euclid(TAU) as f32
}

/// [`rotation_at`] for the current CLOCK_REALTIME.
pub fn rotation_now() -> f32 {
    rotation_at(std::time::SystemTime::now())
}

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub struct Globals {
    pub viewport: [f32; 2],
    pub center: [f32; 2],
    pub radius: f32,
    pub rotation: f32,
    pub _pad: [f32; 2],
}

impl Globals {
    /// The wallpaper's layout for a `width` × `height` output: centred, radius
    /// 35% of the short side.
    pub fn for_output(width: u32, height: u32, rotation: f32) -> Self {
        Globals {
            viewport: [width as f32, height as f32],
            center: [width as f32 / 2.0, height as f32 / 2.0],
            radius: (height.min(width) as f32 * 0.35) as i32 as f32,
            rotation,
            _pad: [0.0; 2],
        }
    }

    /// The same globe, drawn into a `crop_w` × `crop_h` window centred on
    /// that output (what a centre crop of a screenshot would show).
    pub fn for_crop(output_w: u32, output_h: u32, crop_w: u32, crop_h: u32, rotation: f32) -> Self {
        let full = Self::for_output(output_w, output_h, rotation);
        let dx = (output_w as f32 - crop_w as f32) / 2.0;
        let dy = (output_h as f32 - crop_h as f32) / 2.0;
        Globals {
            viewport: [crop_w as f32, crop_h as f32],
            // Whole pixels so the shader's pixel snapping lands the same way.
            center: [full.center[0] - dx.floor(), full.center[1] - dy.floor()],
            ..full
        }
    }
}

/// One glowing pixel: a point on the globe (kind 0, lon/lat in radians) or a
/// point on the fixed outline circle (kind 1, screen angle in radians).
#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub struct PointInstance {
    pub lon_lat: [f32; 2],
    pub intensity: f32,
    pub kind: f32,
}

/// One continent sub-segment, both ends as lon/lat in radians.
#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub struct LineInstance {
    pub a: [f32; 2],
    pub b: [f32; 2],
}

/// Lat/lon grid dots and the globe outline, same sampling as the CPU loops.
pub fn build_points() -> Vec<PointInstance> {
    let mut points = Vec::new();

    // Latitude lines (every 30 degrees)
    for lat_deg in (-60..=60).step_by(30) {
        let lat = (lat_deg as f32).to_radians();
        for lon_deg in 0..360 {
            let lon = (lon_deg as f32).to_radians();
            points.push(PointInstance { lon_lat: [lon, lat], intensity: TEAL_GRID_INTENSITY, kind: 0.0 });
        }
    }

    // Longitude lines (every 30 degrees)
    for lon_deg in (0..180).step_by(30) {
        let lon = (lon_deg as f32).to_radians();
        for lat_deg in -90..=90 {
            let lat = (lat_deg as f32).to_radians();
            points.push(PointInstance { lon_lat: [lon, lat], intensity: TEAL_GRID_INTENSITY, kind: 0.0 });
            points.push(PointInstance { lon_lat: [lon + PI, lat], intensity: TEAL_GRID_INTENSITY, kind: 0.0 });
        }
    }

    // Globe outline
    for angle in 0..720 {
        let a = (angle as f32) * PI / 360.0;
        points.push(PointInstance { lon_lat: [a, 0.0], intensity: TEAL_OUTLINE_INTENSITY, kind: 1.0 });
    }

    points
}

/// Every landmass edge, interpolated in lat/lon space exactly like
/// draw_continent() did; each step becomes one line instance.
pub fn build_continent_lines() -> Vec<LineInstance> {
    let mut lines = Vec::new();

    for points in ALL_LANDMASSES {
        if points.len() < 2 {
            continue;
        }

        for i in 0..points.len() {
            let (lon1, lat1) = points[i];
            let (lon2, lat2) = points[(i + 1) % points.len()];

            let lat1_rad = lat1.to_radians();
            let lon1_rad = lon1.to_radians();
            let lat2_rad = lat2.to_radians();
            let lon2_rad = lon2.to_radians();

            // More interpolation steps for smoother lines
            let dist = ((lat2 - lat1).powi(2) + (lon2 - lon1).powi(2)).sqrt();
            let steps = ((dist * 3.0) as i32).max(20);

            let at = |s: i32| {
                let t = s as f32 / steps as f32;
                [lon1_rad + (lon2_rad - lon1_rad) * t, lat1_rad + (lat2_rad - lat1_rad) * t]
            };
            for s in 1..=steps {
                lines.push(LineInstance { a: at(s - 1), b: at(s) });
            }
        }
    }

    lines
}
