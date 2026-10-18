//! Sun, Moon and sky rotation for one place, from the clock alone (no network).
//! Sun: the low-precision almanac formulae (about 0.01°). Moon: Schlyter's
//! method with the larger perturbation terms and topocentric parallax (about
//! 0.3°), plenty for a wallpaper.
//!
//! Directions are in the scene's world frame: x east, y up, z south
//! (right-handed).
use std::f64::consts::PI;

const DEG: f64 = PI / 180.0;

pub type V3 = [f64; 3];

/// Days since J2000.0 (2000-01-01 12:00 TT ≈ UTC here).
pub fn days_j2000(unix: f64) -> f64 {
    unix / 86_400.0 + 2_440_587.5 - 2_451_545.0
}

fn rev(x: f64) -> f64 {
    x.rem_euclid(360.0)
}

/// Greenwich mean sidereal time, degrees.
pub fn gmst_deg(d: f64) -> f64 {
    rev(280.460_618_37 + 360.985_647_366_29 * d)
}

/// Equatorial (right ascension, declination; radians) to a world direction for
/// an observer at `lat` (radians) with local sidereal time `lst` (radians).
fn equatorial_to_world(ra: f64, dec: f64, lat: f64, lst: f64) -> V3 {
    let h = lst - ra;
    let east = -dec.cos() * h.sin();
    let north = lat.cos() * dec.sin() - lat.sin() * dec.cos() * h.cos();
    let up = lat.sin() * dec.sin() + lat.cos() * dec.cos() * h.cos();
    [east, up, -north]
}

/// Precession from the J2000 equator/equinox to the mean equator/equinox of date (IAU 1976, Meeus
/// ch. 21): `v_date = P · v_J2000`. `d` = days since J2000.
pub fn precession(d: f64) -> [[f64; 3]; 3] {
    let t = d / 36_525.0;
    let asec = DEG / 3600.0;
    let zeta = (2306.2181 * t + 0.30188 * t * t + 0.017998 * t * t * t) * asec;
    let z = (2306.2181 * t + 1.09468 * t * t + 0.018203 * t * t * t) * asec;
    let th = (2004.3109 * t - 0.42665 * t * t - 0.041833 * t * t * t) * asec;
    let (sz, cz) = zeta.sin_cos();
    let (sy, cy) = z.sin_cos();
    let (st, ct) = th.sin_cos();
    [
        [cz * ct * cy - sz * sy, -sz * ct * cy - cz * sy, -st * cy],
        [cz * ct * sy + sz * cy, -sz * ct * sy + cz * cy, -st * sy],
        [cz * st, -sz * st, ct],
    ]
}

/// The five naked-eye planets (Mercury, Venus, Mars, Jupiter, Saturn) as `[x, y, z, magnitude]`: world
/// direction (see the module docs) and apparent visual magnitude. Paul Schlyter's low-precision method
/// ("How to compute planetary positions", with the Jupiter/Saturn perturbations): about 1-2 arcminutes,
/// magnitudes within ~0.2. `d` = days since J2000.
fn planets(d: f64, lat: f64, lst: f64) -> [[f64; 4]; 5] {
    let ds = d + 1.5; // Schlyter's day number: days since 1999-12-31 0h UT
    let sin_d = |x: f64| (x * DEG).sin();
    let cos_d = |x: f64| (x * DEG).cos();
    let ecl = (23.4393 - 3.563e-7 * ds) * DEG;
    // The Sun, geocentric, ecliptic.
    let ws = 282.9404 + 4.70935e-5 * ds;
    let es = 0.016709 - 1.151e-9 * ds;
    let ms = rev(356.0470 + 0.9856002585 * ds);
    let mut ea = ms + (es / DEG) * sin_d(ms) * (1.0 + es * cos_d(ms));
    ea = ea - (ea - (es / DEG) * sin_d(ea) - ms) / (1.0 - es * cos_d(ea));
    let (xv, yv) = (cos_d(ea) - es, (1.0 - es * es).sqrt() * sin_d(ea));
    let vs = yv.atan2(xv) / DEG;
    let rs = (xv * xv + yv * yv).sqrt();
    let lon_s = rev(vs + ws);
    let (xs, ys) = (rs * cos_d(lon_s), rs * sin_d(lon_s));
    // (N, i, w, a, e, M) with their daily rates, as (value, rate).
    #[rustfmt::skip]
    let el: [[(f64, f64); 6]; 5] = [
        [(48.3313, 3.24587e-5), (7.0047, 5.00e-8), (29.1241, 1.01444e-5), (0.387098, 0.0), (0.205635, 5.59e-10), (168.6562, 4.0923344368)],
        [(76.6799, 2.46590e-5), (3.3946, 2.75e-8), (54.8910, 1.38374e-5), (0.723330, 0.0), (0.006773, -1.302e-9), (48.0052, 1.6021302244)],
        [(49.5574, 2.11081e-5), (1.8497, -1.78e-8), (286.5016, 2.92961e-5), (1.523688, 0.0), (0.093405, 2.516e-9), (18.6021, 0.5240207766)],
        [(100.4542, 2.76854e-5), (1.3030, -1.557e-7), (273.8777, 1.64505e-5), (5.20256, 0.0), (0.048498, 4.469e-9), (19.8950, 0.0830853001)],
        [(113.6634, 2.38980e-5), (2.4886, -1.081e-7), (339.3939, 2.97661e-5), (9.55475, 0.0), (0.055546, -9.499e-9), (316.9670, 0.0334442282)],
    ];
    let mj = rev(el[3][5].0 + el[3][5].1 * ds);
    let msat = rev(el[4][5].0 + el[4][5].1 * ds);
    let mut out = [[0.0; 4]; 5];
    for (k, e) in el.iter().enumerate() {
        let v = |i: usize| e[i].0 + e[i].1 * ds;
        let (n, inc, w, a, ecc, m) = (v(0), v(1), v(2), v(3), v(4), rev(v(5)));
        let mut ee = m + (ecc / DEG) * sin_d(m) * (1.0 + ecc * cos_d(m));
        for _ in 0..6 {
            ee -= (ee - (ecc / DEG) * sin_d(ee) - m) / (1.0 - ecc * cos_d(ee));
        }
        let (px, py) = (a * (cos_d(ee) - ecc), a * (1.0 - ecc * ecc).sqrt() * sin_d(ee));
        let r = (px * px + py * py).sqrt();
        let vv = py.atan2(px) / DEG;
        let (xh, yh, zh) = (
            r * (cos_d(n) * cos_d(vv + w) - sin_d(n) * sin_d(vv + w) * cos_d(inc)),
            r * (sin_d(n) * cos_d(vv + w) + cos_d(n) * sin_d(vv + w) * cos_d(inc)),
            r * sin_d(vv + w) * sin_d(inc),
        );
        let mut lon = yh.atan2(xh) / DEG;
        let mut lat_e = zh.atan2((xh * xh + yh * yh).sqrt()) / DEG;
        if k == 3 {
            lon += -0.332 * sin_d(2.0 * mj - 5.0 * msat - 67.6) - 0.056 * sin_d(2.0 * mj - 2.0 * msat + 21.0)
                + 0.042 * sin_d(3.0 * mj - 5.0 * msat + 21.0)
                - 0.036 * sin_d(mj - 2.0 * msat)
                + 0.022 * cos_d(mj - msat)
                + 0.023 * sin_d(2.0 * mj - 3.0 * msat + 52.0)
                - 0.016 * sin_d(mj - 5.0 * msat - 69.0);
        } else if k == 4 {
            lon += 0.812 * sin_d(2.0 * mj - 5.0 * msat - 67.6) - 0.229 * cos_d(2.0 * mj - 4.0 * msat - 2.0)
                + 0.119 * sin_d(mj - 2.0 * msat - 3.0)
                + 0.046 * sin_d(2.0 * mj - 6.0 * msat - 69.0)
                + 0.014 * sin_d(mj - 3.0 * msat + 32.0);
            lat_e += -0.020 * cos_d(2.0 * mj - 4.0 * msat - 2.0) + 0.018 * sin_d(2.0 * mj - 6.0 * msat - 49.0);
        }
        let (xh, yh, zh) = (r * cos_d(lon) * cos_d(lat_e), r * sin_d(lon) * cos_d(lat_e), r * sin_d(lat_e));
        // Geocentric ecliptic, then equatorial.
        let (xg, yg, zg) = (xh + xs, yh + ys, zh);
        let big_r = (xg * xg + yg * yg + zg * zg).sqrt();
        let (xe, ye, ze) = (xg, yg * ecl.cos() - zg * ecl.sin(), yg * ecl.sin() + zg * ecl.cos());
        let ra = ye.atan2(xe);
        let dec = ze.atan2((xe * xe + ye * ye).sqrt());
        let dir = equatorial_to_world(ra, dec, lat, lst);
        // Phase angle and magnitude.
        let cos_fv = ((r * r + big_r * big_r - rs * rs) / (2.0 * r * big_r)).clamp(-1.0, 1.0);
        let fv = cos_fv.acos() / DEG;
        let l5 = 5.0 * (r * big_r).log10();
        let mag = match k {
            0 => -0.36 + l5 + 0.027 * fv + 2.2e-13 * fv.powi(6),
            1 => -4.34 + l5 + 0.013 * fv + 4.2e-7 * fv.powi(3),
            2 => -1.51 + l5 + 0.016 * fv,
            3 => -9.25 + l5 + 0.014 * fv,
            _ => {
                let lg = yg.atan2(xg) / DEG;
                let bg = zg.atan2((xg * xg + yg * yg).sqrt()) / DEG;
                let nr = 169.51 + 3.82e-5 * ds;
                let b = (sin_d(bg) * cos_d(28.06) - cos_d(bg) * sin_d(28.06) * sin_d(lg - nr)).asin();
                -9.0 + l5 + 0.044 * fv - 2.6 * b.sin().abs() + 1.2 * b.sin().powi(2)
            }
        };
        out[k] = [dir[0], dir[1], dir[2], mag];
    }
    out
}

pub struct Sky {
    pub sun: V3,
    pub moon: V3,
    /// Illuminated fraction of the Moon's disc, 0..1.
    pub moon_illum: f64,
    /// Rows of the matrix taking a world direction to celestial (equatorial)
    /// J2000 coordinates (the frame of the star catalogue and the galactic pole),
    /// so the stars turn with the real sky.
    pub celestial: [V3; 3],
    /// Mercury, Venus, Mars, Jupiter, Saturn: world direction and magnitude (see `planets`).
    pub planets: [[f64; 4]; 5],
}

pub fn sky(unix: f64, lat_deg: f64, lon_deg: f64) -> Sky {
    let d = days_j2000(unix);
    let lat = lat_deg * DEG;
    let lst = (gmst_deg(d) + lon_deg).rem_euclid(360.0) * DEG;

    // --- Sun
    let g = rev(357.529 + 0.985_600_28 * d) * DEG;
    let q = rev(280.459 + 0.985_647_36 * d);
    let l = (q + 1.915 * g.sin() + 0.020 * (2.0 * g).sin()) * DEG;
    let e = (23.439 - 0.000_000_36 * d) * DEG;
    let sun_ra = (e.cos() * l.sin()).atan2(l.cos());
    let sun_dec = (e.sin() * l.sin()).asin();
    let sun = equatorial_to_world(sun_ra, sun_dec, lat, lst);

    // --- Moon (Schlyter)
    let n = rev(125.1228 - 0.052_953_808_3 * d) * DEG;
    let i = 5.1454 * DEG;
    let w = rev(318.0634 + 0.164_357_322_3 * d) * DEG;
    let a = 60.2666;
    let ecc = 0.054_900;
    let m = rev(115.3654 + 13.064_992_950_9 * d) * DEG;
    let mut big_e = m + ecc * m.sin() * (1.0 + ecc * m.cos());
    for _ in 0..5 {
        big_e -= (big_e - ecc * big_e.sin() - m) / (1.0 - ecc * big_e.cos());
    }
    let xv = a * (big_e.cos() - ecc);
    let yv = a * (1.0 - ecc * ecc).sqrt() * big_e.sin();
    let v = yv.atan2(xv);
    let mut r = (xv * xv + yv * yv).sqrt();
    let xh = r * (n.cos() * (v + w).cos() - n.sin() * (v + w).sin() * i.cos());
    let yh = r * (n.sin() * (v + w).cos() + n.cos() * (v + w).sin() * i.cos());
    let zh = r * (v + w).sin() * i.sin();
    let mut lon = yh.atan2(xh) / DEG;
    let mut latm = zh.atan2((xh * xh + yh * yh).sqrt()) / DEG;

    let ms = rev(356.0470 + 0.985_600_258_5 * d) * DEG;
    let ws = 282.9404 + 4.709_35e-5 * d;
    let ls = rev(ms / DEG + ws) * DEG;
    let lm = n + w + m;
    let dd = lm - ls;
    let f = lm - n;
    lon += -1.274 * (m - 2.0 * dd).sin() + 0.658 * (2.0 * dd).sin() - 0.186 * ms.sin()
        - 0.059 * (2.0 * m - 2.0 * dd).sin()
        - 0.057 * (m - 2.0 * dd + ms).sin()
        + 0.053 * (m + 2.0 * dd).sin()
        + 0.046 * (2.0 * dd - ms).sin()
        + 0.041 * (m - ms).sin()
        - 0.035 * dd.sin()
        - 0.031 * (m + ms).sin()
        - 0.015 * (2.0 * f - 2.0 * dd).sin()
        + 0.011 * (m - 4.0 * dd).sin();
    latm += -0.173 * (f - 2.0 * dd).sin() - 0.055 * (m - f - 2.0 * dd).sin() - 0.046 * (m + f - 2.0 * dd).sin()
        + 0.033 * (f + 2.0 * dd).sin()
        + 0.017 * (2.0 * m + f).sin();
    r += -0.58 * (m - 2.0 * dd).cos() - 0.46 * (2.0 * dd).cos();
    let (lon, latm) = (lon * DEG, latm * DEG);
    // Ecliptic -> equatorial
    let xe = latm.cos() * lon.cos();
    let ye = latm.cos() * lon.sin() * e.cos() - latm.sin() * e.sin();
    let ze = latm.cos() * lon.sin() * e.sin() + latm.sin() * e.cos();
    let moon_ra = ye.atan2(xe);
    let moon_dec = ze.atan2((xe * xe + ye * ye).sqrt());
    let mut moon = equatorial_to_world(moon_ra, moon_dec, lat, lst);
    // Topocentric parallax: the Moon sits lower by asin(1/r)·cos(alt).
    let alt = moon[1].clamp(-1.0, 1.0).asin();
    let alt_topo = alt - (1.0 / r).asin() * alt.cos();
    let horiz = (moon[0] * moon[0] + moon[2] * moon[2]).sqrt().max(1e-9);
    let k = alt_topo.cos() / horiz;
    moon = [moon[0] * k, alt_topo.sin(), moon[2] * k];

    // Phase: elongation from the sun's ecliptic longitude.
    let elong = (sun[0] * moon[0] + sun[1] * moon[1] + sun[2] * moon[2]).clamp(-1.0, 1.0).acos();
    let moon_illum = (1.0 - elong.cos()) * 0.5;

    // World -> celestial: hour-angle frame, then rotate by the sidereal time.
    // hx = cosδ cosH = up cosφ - north sinφ; hy = cosδ sinH = -east;
    // hz = sinδ = up sinφ + north cosφ, with north = -z.
    let (sl, cl) = lat.sin_cos();
    let hx = [0.0, cl, sl]; // dot with (e, u, z): up·cosφ − north·sinφ = u·cl + z·sl
    let hy = [-1.0, 0.0, 0.0];
    let hz = [0.0, sl, -cl];
    let (sl_, cl_) = lst.sin_cos();
    let row = |a: V3, ka: f64, b: V3, kb: f64| [a[0] * ka + b[0] * kb, a[1] * ka + b[1] * kb, a[2] * ka + b[2] * kb];
    let of_date = [row(hx, cl_, hy, sl_), row(hx, sl_, hy, -cl_), hz];
    // Back from the equator of date to J2000: v_J2000 = Pᵀ · v_date, so row i is Σₖ P[k][i] · of_date[k].
    let p = precession(d);
    let celestial = [0, 1, 2].map(|i| {
        let mut r = [0.0; 3];
        for k in 0..3 {
            for j in 0..3 {
                r[j] += p[k][i] * of_date[k][j];
            }
        }
        r
    });

    Sky { sun, moon, moon_illum, celestial, planets: planets(d, lat, lst) }
}

// --- Civil time in America/New_York --------------------------------------------

/// Days since 1970-01-01 of a civil date (Howard Hinnant's algorithm).
pub fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

pub fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// The n-th Sunday (1-based) of a month, as days since the epoch.
fn nth_sunday(y: i64, m: i64, n: i64) -> i64 {
    let first = days_from_civil(y, m, 1);
    let wd = (first + 4).rem_euclid(7); // 0 = Sunday (1970-01-01 was a Thursday)
    first + (7 - wd) % 7 + 7 * (n - 1)
}

/// UTC offset of US Eastern time (hours) at a unix time.
pub fn eastern_offset_hours(unix: f64) -> f64 {
    let days = (unix / 86_400.0).floor() as i64;
    let (y, _, _) = civil_from_days(days);
    // DST: 2nd Sunday of March 07:00 UTC .. 1st Sunday of November 06:00 UTC.
    let start = nth_sunday(y, 3, 2) as f64 * 86_400.0 + 7.0 * 3600.0;
    let end = nth_sunday(y, 11, 1) as f64 * 86_400.0 + 6.0 * 3600.0;
    if unix >= start && unix < end { -4.0 } else { -5.0 }
}

/// Unix time of a local (America/New_York) date and time.
pub fn eastern_to_unix(y: i64, m: i64, d: i64, secs_of_day: f64) -> f64 {
    let base = days_from_civil(y, m, d) as f64 * 86_400.0 + secs_of_day;
    // Guess with EST, then correct once with the offset at that instant.
    let guess = base + 5.0 * 3600.0;
    base - eastern_offset_hours(guess) * 3600.0
}

/// Local (Eastern) civil date of a unix time.
pub fn eastern_date(unix: f64) -> (i64, i64, i64) {
    let local = unix + eastern_offset_hours(unix) * 3600.0;
    civil_from_days((local / 86_400.0).floor() as i64)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::stars;

    /// Altitude and azimuth (degrees, azimuth from north through east) of a J2000 direction.
    fn alt_az(sky: &Sky, v: V3) -> (f64, f64) {
        let c = sky.celestial;
        // world = Cᵀ · v (C is a rotation).
        let w = [
            c[0][0] * v[0] + c[1][0] * v[1] + c[2][0] * v[2],
            c[0][1] * v[0] + c[1][1] * v[1] + c[2][1] * v[2],
            c[0][2] * v[0] + c[1][2] * v[1] + c[2][2] * v[2],
        ];
        // world: x east, y up, z south.
        (w[1].asin() / DEG, (w[0].atan2(-w[2]) / DEG).rem_euclid(360.0))
    }

    fn star(hr: u32) -> V3 {
        stars::catalog().iter().find(|s| s.hr == hr).expect("star in catalogue").dir()
    }

    #[test]
    fn precession_is_a_rotation_and_small_now() {
        let d = days_j2000(eastern_to_unix(2026, 10, 18, 22.0 * 3600.0));
        let p = precession(d);
        for i in 0..3 {
            let n: f64 = (0..3).map(|j| p[i][j] * p[i][j]).sum();
            assert!((n - 1.0).abs() < 1e-12);
        }
        // About 0.36° of general precession in 26.8 years (50.3″/yr).
        let ang = (p[0][0].clamp(-1.0, 1.0)).acos() / DEG + 0.0;
        assert!(ang > 0.2 && ang < 0.5, "{ang}");
    }

    #[test]
    fn polaris_altitude_matches_latitude() {
        let t = eastern_to_unix(2026, 10, 18, 22.0 * 3600.0); // 22:00 EDT
        let s = sky(t, 29.2, -81.0);
        let (alt, az) = alt_az(&s, star(424)); // Polaris
        // Polaris is ~0.65° from the pole: altitude = latitude ± that, due north within ~1.2°.
        assert!((alt - 29.2).abs() < 0.7, "alt {alt}");
        assert!(az < 1.5 || az > 358.5, "az {az}");
    }

    #[test]
    fn orion_and_big_dipper_where_they_belong() {
        // 2026-01-15 21:00 EST (LST ~4.3 h): Orion rising high in the SE, Sirius lower in the SE.
        let s = sky(eastern_to_unix(2026, 1, 15, 21.0 * 3600.0), 29.2, -81.0);
        let (alt, az) = alt_az(&s, star(1713)); // Rigel
        assert!(alt > 42.0 && alt < 58.0 && az > 135.0 && az < 175.0, "Rigel {alt} {az}");
        let (alt, az) = alt_az(&s, star(1948)); // Alnilam, the middle belt star, on the equator
        assert!(alt > 48.0 && alt < 62.0 && az > 105.0 && az < 145.0, "Alnilam {alt} {az}");
        let (alt, az) = alt_az(&s, star(2491)); // Sirius
        assert!(alt > 15.0 && alt < 45.0 && az > 110.0 && az < 160.0, "Sirius {alt} {az}");
        // 2026-04-15 22:00 EDT: the Big Dipper high overhead-ish in the north.
        let s = sky(eastern_to_unix(2026, 4, 15, 22.0 * 3600.0), 29.2, -81.0);
        let (alt, _) = alt_az(&s, star(4301)); // Dubhe
        assert!(alt > 50.0, "Dubhe {alt}");
    }

    /// Prints alt/az for a few stars (cargo test dump_altaz -- --ignored --nocapture) to compare with astropy.
    #[test]
    #[ignore]
    fn dump_altaz() {
        for (y, m, d, h) in [(2026, 10, 18, 22.0), (2026, 1, 15, 21.0), (2026, 7, 4, 23.0)] {
            let s = sky(eastern_to_unix(y, m, d, h * 3600.0), 29.2, -81.0);
            for hr in [424, 2491, 1713, 5340, 7001, 4301, 603, 6134, 1017, 5056] {
                let (alt, az) = alt_az(&s, star(hr));
                println!("{y}-{m}-{d} {h} HR{hr} {alt:.3} {az:.3}");
            }
        }
    }

    /// cargo test dump_planets -- --ignored --nocapture, compared with pyephem.
    #[test]
    #[ignore]
    fn dump_planets() {
        for (y, m, d, h) in [(2026, 10, 18, 22.0), (2026, 1, 15, 21.0), (2026, 7, 4, 23.0), (2026, 12, 9, 5.0)] {
            let s = sky(eastern_to_unix(y, m, d, h * 3600.0), 29.2, -81.0);
            for (k, p) in s.planets.iter().enumerate() {
                let alt = p[1].asin() / DEG;
                let az = p[0].atan2(-p[2]) / DEG;
                println!("PL {y}-{m}-{d} {h} {k} {alt:.3} {:.3} {:.2}", az.rem_euclid(360.0), p[3]);
            }
        }
    }
}
