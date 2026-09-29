//! The circular restricted three-body problem in the Earth-Moon rotating
//! frame, nondimensional: the Earth-Moon distance is 1, the Moon's orbital
//! period is 2π, the barycentre is the origin, the Earth sits at (-μ, 0) and
//! the Moon at (1 - μ, 0).
//!
//! Everything here runs once at startup: the free-return trajectory, the
//! Lagrange points and the zero-velocity curves through them.

/// Moon / (Earth + Moon) mass ratio.
pub const MU: f64 = 0.012_150_585;
/// Length unit: the mean Earth-Moon distance (km).
pub const LENGTH_KM: f64 = 384_400.0;
/// Time unit (s): sqrt(L^3 / G(M_earth + M_moon)).
pub const TIME_S: f64 = 375_196.0;
/// Hours per time unit.
pub const TIME_SCALE_HOURS: f64 = TIME_S / 3600.0;

pub const EARTH_RADIUS: f64 = 6378.137 / LENGTH_KM;
pub const MOON_RADIUS: f64 = 1737.4 / LENGTH_KM;

/// The parking orbit: circular, 185 km up, prograde (the Moon's sense).
const PARKING_RADIUS: f64 = (6378.137 + 185.0) / LENGTH_KM;

/// The trans-lunar injection: where on the parking orbit (radians from the
/// Earth-Moon line, in the rotating frame) and the inertial speed right
/// after the burn (nondimensional, ~10.96 km/s). Found by shooting on both
/// in this same integrator (tools/shoot.py) for a 250 km perilune over the
/// lunar far side and a vacuum perigee at the Earth's surface on return:
/// the figure eight of Apollo 8's free return, 5.8 days TLI to entry.
const TLI_ANGLE: f64 = 3.968_553_504_711_296_3;
const TLI_SPEED: f64 = 10.700_733_638_577_667;

/// Parking orbit coast before TLI shown, in revolutions.
const PARKING_REVS: f64 = 1.5;

/// A state: x, y, vx, vy.
type State = [f64; 4];

fn accel(s: &State) -> [f64; 2] {
    let [x, y, vx, vy] = *s;
    let (dx1, dx2) = (x + MU, x - 1.0 + MU);
    let r1 = (dx1 * dx1 + y * y).powf(1.5);
    let r2 = (dx2 * dx2 + y * y).powf(1.5);
    [
        2.0 * vy + x - (1.0 - MU) * dx1 / r1 - MU * dx2 / r2,
        -2.0 * vx + y - (1.0 - MU) * y / r1 - MU * y / r2,
    ]
}

fn deriv(s: &State) -> State {
    let a = accel(s);
    [s[2], s[3], a[0], a[1]]
}

fn rk4(s: &State, h: f64) -> State {
    let add = |s: &State, k: &State, f: f64| [s[0] + f * k[0], s[1] + f * k[1], s[2] + f * k[2], s[3] + f * k[3]];
    let k1 = deriv(s);
    let k2 = deriv(&add(s, &k1, h / 2.0));
    let k3 = deriv(&add(s, &k2, h / 2.0));
    let k4 = deriv(&add(s, &k3, h));
    let mut out = *s;
    for i in 0..4 {
        out[i] += h / 6.0 * (k1[i] + 2.0 * k2[i] + 2.0 * k3[i] + k4[i]);
    }
    out
}

/// Distances to the Earth and the Moon.
fn radii(x: f64, y: f64) -> (f64, f64) {
    (((x + MU).powi(2) + y * y).sqrt(), ((x - 1.0 + MU).powi(2) + y * y).sqrt())
}

/// Step size: small near either body (the Moon weighted up, it's where the
/// path is most sensitive), capped out in the coast.
fn step_size(x: f64, y: f64) -> f64 {
    let (r1, r2) = radii(x, y);
    (0.01 * r1.min(4.0 * r2).powf(1.5)).min(0.004)
}

/// A trajectory sample: position and time since TLI (nondimensional).
#[derive(Clone, Copy)]
pub struct Sample {
    pub x: f64,
    pub y: f64,
    pub t: f64,
}

/// The whole mission: the parking orbit coast, TLI, the lunar flyby and
/// back until the path meets the Earth's surface (entry).
pub fn free_return() -> Vec<Sample> {
    let mut out = Vec::new();

    // Parking orbit, analytically: a circle turning at the orbit's rate
    // less the frame's.
    let rate = ((1.0 - MU) / PARKING_RADIUS.powi(3)).sqrt() - 1.0;
    let coast = PARKING_REVS * std::f64::consts::TAU / rate;
    let steps = 360;
    for i in 0..steps {
        let t = -coast * (1.0 - i as f64 / steps as f64);
        let a = TLI_ANGLE + rate * t;
        out.push(Sample { x: -MU + PARKING_RADIUS * a.cos(), y: PARKING_RADIUS * a.sin(), t });
    }

    // TLI: prograde burn, the velocity taken into the rotating frame.
    let (x, y) = (-MU + PARKING_RADIUS * TLI_ANGLE.cos(), PARKING_RADIUS * TLI_ANGLE.sin());
    let (tx, ty) = (-TLI_ANGLE.sin(), TLI_ANGLE.cos());
    let mut s: State = [x, y, TLI_SPEED * tx + y, TLI_SPEED * ty - x];
    let mut t = 0.0;
    out.push(Sample { x, y, t });
    let mut left = false;
    while t < 2.5 {
        let h = step_size(s[0], s[1]);
        let next = rk4(&s, h);
        let (r1, _) = radii(next[0], next[1]);
        if r1 > 0.5 {
            left = true;
        }
        if left && r1 <= EARTH_RADIUS {
            // Entry: the last bit, cut at the surface.
            let (r0, _) = radii(s[0], s[1]);
            let f = ((r0 - EARTH_RADIUS) / (r0 - r1)).clamp(0.0, 1.0);
            out.push(Sample { x: s[0] + f * (next[0] - s[0]), y: s[1] + f * (next[1] - s[1]), t: t + f * h });
            break;
        }
        s = next;
        t += h;
        out.push(Sample { x: s[0], y: s[1], t });
    }
    out
}

/// Twice the effective potential; the Jacobi constant of a body at rest
/// there. The zero-velocity curves are its level sets.
pub fn two_omega(x: f64, y: f64) -> f64 {
    let (r1, r2) = radii(x, y);
    x * x + y * y + 2.0 * (1.0 - MU) / r1 + 2.0 * MU / r2
}

/// L1..L5, in order.
pub fn lagrange_points() -> [(f64, f64); 5] {
    // The collinear ones: roots of the x-axis force balance, by Newton.
    let force = |x: f64| x - (1.0 - MU) * (x + MU) / (x + MU).abs().powi(3) - MU * (x - 1.0 + MU) / (x - 1.0 + MU).abs().powi(3);
    let root = |mut x: f64| {
        for _ in 0..60 {
            let d = 1e-7;
            let f = force(x);
            x -= f / ((force(x + d) - f) / d);
        }
        x
    };
    let h = std::f64::consts::FRAC_PI_3.sin();
    [(root(0.84), 0.0), (root(1.16), 0.0), (root(-1.0), 0.0), (0.5 - MU, h), (0.5 - MU, -h)]
}

/// The zero-velocity curve 2Ω(x, y) = `level` over `[x0, x1] × [y0, y1]`,
/// as polylines (closed ones repeat their first point), by marching
/// squares on a `cell`-sized grid.
pub fn contour(level: f64, (x0, x1): (f64, f64), (y0, y1): (f64, f64), cell: f64) -> Vec<Vec<(f64, f64)>> {
    let nx = ((x1 - x0) / cell).ceil() as usize + 1;
    let ny = ((y1 - y0) / cell).ceil() as usize + 1;
    let at = |i: usize, j: usize| (x0 + i as f64 * cell, y0 + j as f64 * cell);
    let v: Vec<f64> = (0..ny)
        .flat_map(|j| (0..nx).map(move |i| (i, j)))
        .map(|(i, j)| {
            let (x, y) = at(i, j);
            // Clamped near the bodies, where it runs off to infinity.
            two_omega(x, y).min(1e3) - level
        })
        .collect();
    let val = |i: usize, j: usize| v[j * nx + i];

    // Edge ids: 2 * (j * nx + i) for the edge from (i, j) to (i + 1, j),
    // one more for (i, j) to (i, j + 1).
    let h_edge = |i: usize, j: usize| 2 * (j * nx + i);
    let v_edge = |i: usize, j: usize| 2 * (j * nx + i) + 1;
    let crossing = |e: usize| -> (f64, f64) {
        let (k, vertical) = (e / 2, e % 2 == 1);
        let (i, j) = (k % nx, k / nx);
        let (i2, j2) = if vertical { (i, j + 1) } else { (i + 1, j) };
        let (a, b) = (val(i, j), val(i2, j2));
        let f = a / (a - b);
        let (xa, ya) = at(i, j);
        let (xb, yb) = at(i2, j2);
        (xa + f * (xb - xa), ya + f * (yb - ya))
    };

    let mut segments: Vec<(usize, usize)> = Vec::new();
    for j in 0..ny - 1 {
        for i in 0..nx - 1 {
            let corners = [val(i, j), val(i + 1, j), val(i + 1, j + 1), val(i, j + 1)];
            let mut case = 0;
            for (b, c) in corners.iter().enumerate() {
                if *c > 0.0 {
                    case |= 1 << b;
                }
            }
            // Edges: bottom, right, top, left.
            let e = [h_edge(i, j), v_edge(i + 1, j), h_edge(i, j + 1), v_edge(i, j)];
            let pairs: &[(usize, usize)] = match case {
                0 | 15 => &[],
                1 | 14 => &[(3, 0)],
                2 | 13 => &[(0, 1)],
                3 | 12 => &[(3, 1)],
                4 | 11 => &[(1, 2)],
                6 | 9 => &[(0, 2)],
                7 | 8 => &[(3, 2)],
                5 => &[(3, 2), (0, 1)],
                10 => &[(3, 0), (1, 2)],
                _ => unreachable!(),
            };
            segments.extend(pairs.iter().map(|&(a, b)| (e[a], e[b])));
        }
    }

    // Chain the segments through their shared edges.
    let mut by_edge: std::collections::HashMap<usize, Vec<usize>> = std::collections::HashMap::new();
    for (k, &(a, b)) in segments.iter().enumerate() {
        by_edge.entry(a).or_default().push(k);
        by_edge.entry(b).or_default().push(k);
    }
    let mut used = vec![false; segments.len()];
    let mut lines = Vec::new();
    // Open chains from their ends first, then whatever's left is loops.
    let ends: Vec<usize> = segments
        .iter()
        .enumerate()
        .filter(|(_, &(a, b))| by_edge[&a].len() == 1 || by_edge[&b].len() == 1)
        .map(|(k, _)| k)
        .collect();
    for k in ends.into_iter().chain(0..segments.len()) {
        if used[k] {
            continue;
        }
        let (a, b) = segments[k];
        let mut edge = if by_edge[&a].len() == 1 { a } else { b };
        let mut line = vec![crossing(edge)];
        let mut seg = k;
        loop {
            used[seg] = true;
            let (a, b) = segments[seg];
            edge = if a == edge { b } else { a };
            line.push(crossing(edge));
            match by_edge[&edge].iter().find(|&&n| !used[n]) {
                Some(&n) => seg = n,
                None => break,
            }
        }
        lines.push(line);
    }
    lines
}

/// Points every `spacing` along a polyline, carrying the remainder over so
/// the dots stay evenly spaced round the joints.
pub fn resample(line: &[(f64, f64)], spacing: f64) -> Vec<(f64, f64)> {
    let mut out = Vec::new();
    let mut next = 0.0;
    let mut walked = 0.0;
    for w in line.windows(2) {
        let (a, b) = (w[0], w[1]);
        let len = ((b.0 - a.0).powi(2) + (b.1 - a.1).powi(2)).sqrt();
        while next <= walked + len {
            let f = if len > 0.0 { (next - walked) / len } else { 0.0 };
            out.push((a.0 + f * (b.0 - a.0), a.1 + f * (b.1 - a.1)));
            next += spacing;
        }
        walked += len;
    }
    out
}
