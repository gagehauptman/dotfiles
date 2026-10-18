//! The sloop's mesh, built once: a lofted hull, deck, cabin, mast and boom as
//! real geometry, and the two sails as (u, v) grids that the vertex shader
//! shapes every frame (trim, camber, twist, reef, furl, flutter).
//!
//! Boat frame: metres, x forward (from midships), y up (from the waterline),
//! z to starboard. About a 10 m (33 ft) masthead-ish sloop.
use crate::BoatVertex;

pub const PART_HULL: f32 = 0.0;
pub const PART_DECK: f32 = 1.0;
pub const PART_CABIN: f32 = 2.0;
pub const PART_MAST: f32 = 3.0;
pub const PART_BOOM: f32 = 4.0;
pub const PART_MAIN: f32 = 5.0;
pub const PART_JIB: f32 = 6.0;
pub const PART_PULPIT: f32 = 7.0;
pub const PART_RIG: f32 = 8.0;
pub const PART_TRIM: f32 = 9.0;
pub const PART_CREW: f32 = 10.0;
pub const PART_LIGHT: f32 = 11.0;
pub const PART_FLAG: f32 = 12.0;

pub const STERN_X: f64 = -4.8;
pub const BOW_X: f64 = 5.2;
pub const MAST_X: f64 = 0.9;
pub const MAST_TOP: f64 = 14.4;
pub const HALF_BEAM: f64 = 1.65;

/// Half-beam at the sheer, t = 0 at the transom, 1 at the stem.
pub fn half_beam(t: f64) -> f64 {
    if t < 0.45 {
        let s = (t / 0.45).clamp(0.0, 1.0);
        HALF_BEAM * (0.78 + 0.22 * s * s * (3.0 - 2.0 * s))
    } else {
        let s = ((t - 0.45) / 0.55).clamp(0.0, 1.0);
        HALF_BEAM * (1.0 - s.powf(1.9)).max(0.0).sqrt()
    }
}

/// Sheer height above the waterline.
pub fn sheer(t: f64) -> f64 {
    let s = t - 0.42;
    0.86 + 1.1 * s * s + 0.18 * t.powi(4)
}

/// Depth of the canoe body below the waterline.
fn draft(t: f64) -> f64 {
    let body = 0.62 * (std::f64::consts::PI * t.clamp(0.0, 1.0)).sin().powf(0.7);
    // Transom bottom just under the water, forefoot rising to the stem.
    let stern = if t < 0.12 { 0.12 * (1.0 - t / 0.12) } else { 0.0 };
    (body + stern * 0.3).max(0.05) - if t > 0.9 { (t - 0.9) * 3.0 } else { 0.0 }
}

struct Mesh {
    verts: Vec<BoatVertex>,
    idx: Vec<u16>,
}

impl Mesh {
    fn v(&mut self, p: [f64; 3], n: [f64; 3], part: f32, uv: [f32; 2]) -> u16 {
        let len = (n[0] * n[0] + n[1] * n[1] + n[2] * n[2]).sqrt().max(1e-9);
        self.verts.push(BoatVertex {
            pos: [p[0] as f32, p[1] as f32, p[2] as f32, part],
            normal: [(n[0] / len) as f32, (n[1] / len) as f32, (n[2] / len) as f32, uv[0]],
            extra: [uv[1], 0.0, 0.0, 0.0],
        });
        (self.verts.len() - 1) as u16
    }
    fn quad(&mut self, a: u16, b: u16, c: u16, d: u16) {
        self.idx.extend_from_slice(&[a, b, c, a, c, d]);
    }
    /// An axis-aligned-ish box from 8 corners (bottom 4 then top 4, CCW).
    fn boxy(&mut self, c: [[f64; 3]; 8], part: f32) {
        let faces = [[0, 1, 2, 3], [4, 7, 6, 5], [0, 4, 5, 1], [1, 5, 6, 2], [2, 6, 7, 3], [3, 7, 4, 0]];
        for f in faces {
            let p = |i: usize| c[f[i]];
            let e1 = sub(p(1), p(0));
            let e2 = sub(p(3), p(0));
            let n = cross(e2, e1);
            let n = if dot(n, sub(p(0), centroid(&c))) < 0.0 { [-n[0], -n[1], -n[2]] } else { n };
            let a = self.v(p(0), n, part, [0.0, 0.0]);
            let b = self.v(p(1), n, part, [1.0, 0.0]);
            let cc = self.v(p(2), n, part, [1.0, 1.0]);
            let d = self.v(p(3), n, part, [0.0, 1.0]);
            self.quad(a, b, cc, d);
        }
    }
    /// A thin spar between two points, square section of half-width r.
    fn spar(&mut self, a: [f64; 3], b: [f64; 3], r0: f64, r1: f64, part: f32) {
        let axis = norm(sub(b, a));
        let side = norm(cross(axis, if axis[1].abs() > 0.9 { [1.0, 0.0, 0.0] } else { [0.0, 1.0, 0.0] }));
        let up = cross(side, axis);
        let ring = |p: [f64; 3], r: f64| {
            [
                add(p, add(mul(side, -r), mul(up, -r))),
                add(p, add(mul(side, r), mul(up, -r))),
                add(p, add(mul(side, r), mul(up, r))),
                add(p, add(mul(side, -r), mul(up, r))),
            ]
        };
        let lo = ring(a, r0);
        let hi = ring(b, r1);
        self.boxy([lo[0], lo[1], lo[2], lo[3], hi[0], hi[1], hi[2], hi[3]], part);
    }
}

fn sub(a: [f64; 3], b: [f64; 3]) -> [f64; 3] { [a[0] - b[0], a[1] - b[1], a[2] - b[2]] }
fn add(a: [f64; 3], b: [f64; 3]) -> [f64; 3] { [a[0] + b[0], a[1] + b[1], a[2] + b[2]] }
fn mul(a: [f64; 3], k: f64) -> [f64; 3] { [a[0] * k, a[1] * k, a[2] * k] }
fn dot(a: [f64; 3], b: [f64; 3]) -> f64 { a[0] * b[0] + a[1] * b[1] + a[2] * b[2] }
fn cross(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
}
fn norm(a: [f64; 3]) -> [f64; 3] { mul(a, 1.0 / dot(a, a).sqrt().max(1e-12)) }
fn centroid(c: &[[f64; 3]; 8]) -> [f64; 3] {
    let mut s = [0.0; 3];
    for p in c {
        s = add(s, *p);
    }
    mul(s, 1.0 / 8.0)
}

/// Rows of the sail grids (chord, height).
pub const SAIL_U: usize = 10;
pub const SAIL_V: usize = 14;

/// Vertices and triangle indices (u16, a triangle list).
pub fn build() -> (Vec<BoatVertex>, Vec<u16>) {
    let mut m = Mesh { verts: Vec::new(), idx: Vec::new() };

    // --- Hull: stations from transom to stem, a half-section each side.
    const ST: usize = 20;
    const SEC: usize = 8;
    let section = |t: f64, j: usize, side: f64| -> [f64; 3] {
        let x = STERN_X + (BOW_X - STERN_X) * t;
        let a = j as f64 / SEC as f64 * std::f64::consts::FRAC_PI_2; // 0 at the sheer, π/2 at the keel
        let b = half_beam(t);
        let top = sheer(t);
        let bottom = -draft(t);
        // Topsides flare out a little, the bilge turns under.
        let z = b * a.cos().powf(0.55);
        let y = top - (top - bottom) * a.sin().powf(1.6);
        [x, y, z * side]
    };
    for side in [1.0f64, -1.0] {
        let base = m.verts.len() as u16;
        for i in 0..=ST {
            let t = i as f64 / ST as f64;
            for j in 0..=SEC {
                let p = section(t, j, side);
                // Normal from neighbours (finite differences).
                let dt = 1.0 / ST as f64;
                let pa = section((t + dt).min(1.0), j, side);
                let pb = section((t - dt).max(0.0), j, side);
                let pc = section(t, (j + 1).min(SEC), side);
                let pd = section(t, j.saturating_sub(1), side);
                let mut n = cross(sub(pa, pb), sub(pc, pd));
                if n[2] * side < 0.0 && j < SEC {
                    n = mul(n, -1.0);
                }
                if j == SEC {
                    n = [0.0, -1.0, 0.0];
                }
                m.v(p, n, PART_HULL, [t as f32, j as f32 / SEC as f32]);
            }
        }
        for i in 0..ST {
            for j in 0..SEC {
                let a = base + (i * (SEC + 1) + j) as u16;
                let b = a + (SEC + 1) as u16;
                if side > 0.0 {
                    m.quad(a, b, b + 1, a + 1);
                } else {
                    m.quad(a, a + 1, b + 1, b);
                }
            }
        }
    }
    // Transom: a fan from the sheer centre.
    {
        let c = m.v([STERN_X, sheer(0.0) - 0.15, 0.0], [-1.0, 0.0, 0.0], PART_HULL, [0.0, 0.5]);
        let mut ring = Vec::new();
        for j in 0..=SEC {
            ring.push(m.v(section(0.0, j, 1.0), [-1.0, 0.0, 0.0], PART_HULL, [0.0, j as f32 / SEC as f32]));
        }
        for j in (0..=SEC).rev() {
            ring.push(m.v(section(0.0, j, -1.0), [-1.0, 0.0, 0.0], PART_HULL, [0.0, j as f32 / SEC as f32]));
        }
        for w in ring.windows(2) {
            m.idx.extend_from_slice(&[c, w[0], w[1]]);
        }
    }

    // --- Deck: crowned strips between the sheers, with a toe rail lip.
    {
        let base = m.verts.len() as u16;
        for i in 0..=ST {
            let t = i as f64 / ST as f64;
            let x = STERN_X + (BOW_X - STERN_X) * t;
            let b = half_beam(t);
            let s = sheer(t);
            for k in 0..=4 {
                let f = k as f64 / 4.0 * 2.0 - 1.0;
                let crown = 0.07 * (1.0 - f * f) * (b / HALF_BEAM);
                m.v([x, s + crown, b * f], [0.0, 1.0, 0.0], PART_DECK, [t as f32, (f * 0.5 + 0.5) as f32]);
            }
        }
        for i in 0..ST {
            for k in 0..4 {
                let a = base + (i * 5 + k) as u16;
                let b = a + 5;
                m.quad(a, a + 1, b + 1, b);
            }
        }
    }

    // --- Cabin trunk and cockpit coaming.
    let deck_at = |x: f64| sheer((x - STERN_X) / (BOW_X - STERN_X)) + 0.05;
    {
        let (x0, x1) = (-1.3, 1.9);
        let (y0a, y0b) = (deck_at(x0) - 0.05, deck_at(x1) - 0.05);
        let h = 0.62;
        let (w0, w1, wt) = (1.0, 0.82, 0.86);
        m.boxy(
            [
                [x0, y0a, -w0],
                [x1, y0b, -w1],
                [x1, y0b, w1],
                [x0, y0a, w0],
                [x0, y0a + h, -wt * w0],
                [x1 - 0.35, y0b + h - 0.08, -wt * w1],
                [x1 - 0.35, y0b + h - 0.08, wt * w1],
                [x0, y0a + h, wt * w0],
            ],
            PART_CABIN,
        );
        // Sprayhood over the companionway
        let yc = deck_at(-1.6);
        m.boxy(
            [
                [-1.9, yc + 0.5, -0.8],
                [-1.25, yc + 0.6, -0.8],
                [-1.25, yc + 0.6, 0.8],
                [-1.9, yc + 0.5, 0.8],
                [-1.75, yc + 0.95, -0.7],
                [-1.3, yc + 1.05, -0.7],
                [-1.3, yc + 1.05, 0.7],
                [-1.75, yc + 0.95, 0.7],
            ],
            PART_CABIN,
        );
    }

    // --- Rig: mast (tapered), boom (rotated by trim in the shader), pulpit/rails.
    let mast_foot = deck_at(MAST_X) + 0.55;
    m.spar([MAST_X, mast_foot - 0.6, 0.0], [MAST_X, MAST_TOP, 0.0], 0.085, 0.05, PART_MAST);
    m.spar([MAST_X - 0.1, 1.95, 0.0], [-3.7, 2.0, 0.0], 0.06, 0.05, PART_BOOM);
    // Lifelines: thin rails along the sheer from bow to stern each side.
    for side in [1.0, -1.0] {
        let mut prev: Option<[f64; 3]> = None;
        for i in 1..ST {
            let t = i as f64 / ST as f64;
            let x = STERN_X + (BOW_X - STERN_X) * t;
            let p = [x, sheer(t) + 0.62, half_beam(t) * side * 0.97];
            if let Some(q) = prev {
                m.spar(q, p, 0.012, 0.012, PART_PULPIT);
            }
            if i % 4 == 1 {
                m.spar([x, sheer(t) + 0.04, half_beam(t) * side * 0.97], p, 0.014, 0.014, PART_PULPIT);
            }
            prev = Some(p);
        }
    }
    // Forestay and backstay as thin spars (the jib's luff runs on the forestay).
    m.spar([BOW_X - 0.15, sheer(1.0) + 0.05, 0.0], [MAST_X + 0.05, MAST_TOP - 0.3, 0.0], 0.012, 0.012, PART_PULPIT);
    m.spar([STERN_X + 0.15, sheer(0.0) + 0.05, 0.0], [MAST_X - 0.05, MAST_TOP, 0.0], 0.012, 0.012, PART_PULPIT);

    // --- Standing rigging: spreaders, cap shrouds over the spreader tips, lowers.
    let spr_y = 8.3;
    let chain_x = MAST_X - 0.2;
    let chain_t = (chain_x - STERN_X) / (BOW_X - STERN_X);
    for side in [1.0, -1.0] {
        let tip = [MAST_X - 0.05, spr_y, 0.95 * side];
        m.spar([MAST_X, spr_y, 0.0], tip, 0.03, 0.018, PART_MAST);
        let chain = [chain_x, sheer(chain_t) + 0.05, half_beam(chain_t) * side * 0.95];
        m.spar(chain, tip, 0.011, 0.011, PART_RIG);
        m.spar(tip, [MAST_X, MAST_TOP - 0.2, 0.04 * side], 0.011, 0.011, PART_RIG);
        let low = [chain_x + 0.45, sheer(chain_t) + 0.05, half_beam(chain_t) * side * 0.93];
        m.spar(low, [MAST_X, spr_y - 0.15, 0.05 * side], 0.01, 0.01, PART_RIG);
    }
    // Halyards slapping down the front of the mast, a burgee staff on top.
    m.spar([MAST_X + 0.1, MAST_TOP - 0.1, 0.03], [MAST_X + 0.13, mast_foot, 0.04], 0.007, 0.007, PART_RIG);
    m.spar([MAST_X, MAST_TOP, 0.0], [MAST_X, MAST_TOP + 0.45, 0.0], 0.012, 0.008, PART_MAST);

    // --- Toe rails: a teak strip along each sheer.
    for side in [1.0, -1.0] {
        let mut prev: Option<[f64; 3]> = None;
        for i in 0..=ST {
            let t = i as f64 / ST as f64;
            let x = STERN_X + (BOW_X - STERN_X) * t;
            let p = [x, sheer(t) + 0.06, half_beam(t) * side * 0.99];
            if let Some(q) = prev {
                m.spar(q, p, 0.03, 0.03, PART_TRIM);
            }
            prev = Some(p);
        }
    }
    // Bow pulpit and stern pushpit closing the lifelines.
    {
        let tb = (ST - 1) as f64 / ST as f64;
        let xb = STERN_X + (BOW_X - STERN_X) * tb;
        let nose = [BOW_X - 0.3, sheer(1.0) + 0.66, 0.0];
        for side in [1.0, -1.0] {
            m.spar([xb, sheer(tb) + 0.62, half_beam(tb) * side * 0.97], nose, 0.016, 0.016, PART_PULPIT);
        }
        m.spar([BOW_X - 0.3, sheer(1.0) + 0.04, 0.0], nose, 0.016, 0.016, PART_PULPIT);
        let ts = 1.0 / ST as f64;
        let xs = STERN_X + (BOW_X - STERN_X) * ts;
        let a = [xs, sheer(ts) + 0.62, half_beam(ts) * 0.97];
        let b = [xs, sheer(ts) + 0.62, -half_beam(ts) * 0.97];
        m.spar(a, [STERN_X + 0.1, sheer(0.0) + 0.62, half_beam(0.0) * 0.6], 0.016, 0.016, PART_PULPIT);
        m.spar(b, [STERN_X + 0.1, sheer(0.0) + 0.62, -half_beam(0.0) * 0.6], 0.016, 0.016, PART_PULPIT);
        m.spar([STERN_X + 0.1, sheer(0.0) + 0.62, half_beam(0.0) * 0.6], [STERN_X + 0.1, sheer(0.0) + 0.62, -half_beam(0.0) * 0.6], 0.016, 0.016, PART_PULPIT);
        // Ensign staff on the stern rail.
        m.spar([STERN_X + 0.12, sheer(0.0) + 0.1, -0.45], [STERN_X + 0.05, sheer(0.0) + 1.15, -0.45], 0.014, 0.01, PART_TRIM);
    }

    // --- Cockpit: coamings, a wheel on its pedestal.
    {
        for side in [1.0, -1.0] {
            let (x0, x1) = (-4.15, -1.3);
            let (ya, yb) = (deck_at(x0) - 0.03, deck_at(x1) - 0.03);
            m.boxy(
                [
                    [x0, ya, 1.0 * side],
                    [x1, yb, 1.0 * side],
                    [x1, yb, 1.1 * side],
                    [x0, ya, 1.1 * side],
                    [x0, ya + 0.3, 1.0 * side],
                    [x1, yb + 0.3, 1.0 * side],
                    [x1, yb + 0.3, 1.1 * side],
                    [x0, ya + 0.3, 1.1 * side],
                ],
                PART_CABIN,
            );
        }
        let wx = -3.75;
        let hub = [wx, deck_at(wx) + 0.62, 0.0];
        m.spar([wx + 0.15, deck_at(wx) - 0.05, 0.0], [wx + 0.05, hub[1] - 0.05, 0.0], 0.05, 0.04, PART_MAST);
        let segs = 12;
        for k in 0..segs {
            let a0 = k as f64 / segs as f64 * std::f64::consts::TAU;
            let a1 = (k + 1) as f64 / segs as f64 * std::f64::consts::TAU;
            let r = 0.4;
            m.spar(
                add(hub, [0.0, r * a0.cos(), r * a0.sin()]),
                add(hub, [0.0, r * a1.cos(), r * a1.sin()]),
                0.018,
                0.018,
                PART_MAST,
            );
        }
        // A helmsman in oilskins (the shader seats him on the windward side).
        let cx = -3.35;
        let cy = deck_at(cx) + 0.1;
        m.boxy(
            [
                [cx - 0.2, cy, 0.5],
                [cx + 0.15, cy, 0.5],
                [cx + 0.15, cy, 0.9],
                [cx - 0.2, cy, 0.9],
                [cx - 0.15, cy + 0.62, 0.55],
                [cx + 0.1, cy + 0.62, 0.55],
                [cx + 0.1, cy + 0.62, 0.85],
                [cx - 0.15, cy + 0.62, 0.85],
            ],
            PART_CREW,
        );
        m.spar([cx - 0.03, cy + 0.62, 0.7], [cx - 0.01, cy + 0.86, 0.7], 0.1, 0.085, PART_CREW);
        // Legs forward to the wheel side, an arm to the rim.
        m.spar([cx + 0.1, cy + 0.08, 0.6], [cx + 0.5, cy - 0.1, 0.55], 0.07, 0.06, PART_CREW);
        m.spar([cx + 0.05, cy + 0.5, 0.6], [wx + 0.02, hub[1] + 0.1, 0.32], 0.045, 0.04, PART_CREW);
    }

    // --- Navigation lights: sidelights on the pulpit, a stern light (lit at night).
    for side in [1.0, -1.0] {
        let p = [BOW_X - 0.45, sheer(0.97) + 0.62, 0.32 * side];
        m.spar(p, add(p, [0.08, 0.0, 0.0]), 0.04, 0.04, PART_LIGHT);
    }
    let p = [STERN_X + 0.08, sheer(0.0) + 0.66, 0.0];
    m.spar(p, add(p, [0.0, 0.0, 0.08]), 0.04, 0.04, PART_LIGHT);

    // --- Flags: the burgee at the masthead and the ensign astern, grids the shader streams downwind.
    for (k, id) in [(0, 0.0f32), (1, 1.0f32)] {
        let _ = k;
        let base = m.verts.len() as u16;
        let (nu, nv) = (8usize, 3usize);
        for j in 0..=nv {
            for i in 0..=nu {
                let u = i as f32 / nu as f32;
                let v = j as f32 / nv as f32;
                m.verts.push(BoatVertex { pos: [0.0, 0.0, 0.0, PART_FLAG], normal: [0.0, 0.0, 1.0, u], extra: [v, id, 0.0, 0.0] });
            }
        }
        for j in 0..nv {
            for i in 0..nu {
                let a = base + (j * (nu + 1) + i) as u16;
                let b = a + (nu + 1) as u16;
                m.quad(a, a + 1, b + 1, b);
            }
        }
    }

    // --- Sails: grids in (u, v); the shader places them.
    for part in [PART_MAIN, PART_JIB] {
        let base = m.verts.len() as u16;
        for j in 0..=SAIL_V {
            for i in 0..=SAIL_U {
                let u = i as f32 / SAIL_U as f32;
                let v = j as f32 / SAIL_V as f32;
                m.verts.push(BoatVertex { pos: [0.0, 0.0, 0.0, part], normal: [0.0, 0.0, 1.0, u], extra: [v, 0.0, 0.0, 0.0] });
            }
        }
        for j in 0..SAIL_V {
            for i in 0..SAIL_U {
                let a = base + (j * (SAIL_U + 1) + i) as u16;
                let b = a + (SAIL_U + 1) as u16;
                m.quad(a, a + 1, b + 1, b);
            }
        }
    }

    (m.verts, m.idx)
}
