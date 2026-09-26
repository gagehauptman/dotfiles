//! Satellites from two-line elements, propagated with SGP4 and placed in the
//! globe's Earth-fixed frame (y north, x through longitude 0, east towards
//! -z), in Earth radii. The service hands the elements over from CelesTrak.
use bevy::prelude::*;
use sgp4::{Constants, Elements};

pub const EARTH_KM: f32 = 6371.0;

pub struct Sat {
    pub name: String,
    pub norad: u32,
    pub group: String,
    pub period_min: f32,
    pub inclination: f32,
    elements: Elements,
    constants: Constants,
    /// position now, Earth radii from the centre
    pub pos: Vec3,
    pub speed_kms: f32,
    pub alt_km: f32,
}

/// Parse the service's `/tle.json`; elements SGP4 rejects are skipped.
pub fn parse(json: &[u8]) -> Vec<Sat> {
    let v: serde_json::Value = match serde_json::from_slice(json) {
        Ok(v) => v,
        Err(_) => return Vec::new(),
    };
    let mut out = Vec::new();
    for s in v["sats"].as_array().map(|a| a.as_slice()).unwrap_or_default() {
        let (name, l1, l2) = (s["name"].as_str().unwrap_or(""), s["l1"].as_str().unwrap_or(""), s["l2"].as_str().unwrap_or(""));
        let Ok(elements) = Elements::from_tle(Some(name.to_string()), l1.as_bytes(), l2.as_bytes()) else { continue };
        let Ok(constants) = Constants::from_elements(&elements) else { continue };
        if elements.mean_motion <= 0.0 {
            continue;
        }
        out.push(Sat {
            name: name.to_string(),
            norad: elements.norad_id as u32,
            group: s["group"].as_str().unwrap_or("").to_string(),
            period_min: (1440.0 / elements.mean_motion) as f32,
            inclination: elements.inclination as f32,
            elements,
            constants,
            pos: Vec3::ZERO,
            speed_kms: 0.0,
            alt_km: 0.0,
        });
    }
    out
}

/// Greenwich mean sidereal time in radians at a unix time.
pub fn gmst(unix: f64) -> f64 {
    let n = unix / 86400.0 - 10957.5; // days since J2000
    (280.46061837 + 360.98564736629 * n).rem_euclid(360.0).to_radians()
}

/// TEME kilometres to the globe frame in Earth radii.
fn teme_to_globe(p: [f64; 3], theta: f64) -> Vec3 {
    let (s, c) = theta.sin_cos();
    let x = p[0] * c + p[1] * s;
    let y = -p[0] * s + p[1] * c;
    Vec3::new(x as f32, p[2] as f32, -y as f32) / EARTH_KM
}

impl Sat {
    /// Position (globe frame, Earth radii) and speed at a unix time.
    pub fn at(&self, unix: f64) -> Option<(Vec3, f32)> {
        let dt = chrono::DateTime::<chrono::Utc>::from_timestamp(unix.floor() as i64, (unix.fract() * 1e9) as u32)?.naive_utc();
        let minutes = self.elements.datetime_to_minutes_since_epoch(&dt).ok()?;
        let p = self.constants.propagate(minutes).ok()?;
        let speed = (p.velocity[0].powi(2) + p.velocity[1].powi(2) + p.velocity[2].powi(2)).sqrt() as f32;
        Some((teme_to_globe(p.position, gmst(unix)), speed))
    }

    pub fn update(&mut self, unix: f64) -> bool {
        match self.at(unix) {
            Some((p, v)) => {
                self.pos = p;
                self.speed_kms = v;
                self.alt_km = p.length() * EARTH_KM - EARTH_KM;
                true
            }
            None => false,
        }
    }

    /// `orbits` revolutions of its path in the Earth-fixed frame, `n` points
    /// centred on now.
    pub fn track(&self, unix: f64, n: usize, orbits: f32) -> Vec<Vec3> {
        let span = self.period_min as f64 * 60.0 * orbits as f64;
        (0..=n).filter_map(|i| self.at(unix - span / 2.0 + span * i as f64 / n as f64).map(|(p, _)| p)).collect()
    }
}
