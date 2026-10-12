//! Cube-sphere geometry. `CubeFace` and `cube_to_sphere` are the mapping from
//! downrange's `terrain/src/patch.rs`; the quadtree, LOD and heightmaps that
//! surround them there are deliberately left out. One fixed grid per face is
//! all a dashboard globe needs.
//!
//! Frame: y is the north pole, `lat = asin(y)`, `lon = atan2(-z, x)`, so the
//! prime meridian is on +x and east is towards -z.
use bevy::prelude::*;
use bevy::render::mesh::{Indices, PrimitiveTopology};
use bevy::render::render_asset::RenderAssetUsages;

#[derive(Clone, Copy, Debug)]
pub enum CubeFace {
    PosX,
    NegX,
    PosY,
    NegY,
    PosZ,
    NegZ,
}

impl CubeFace {
    pub const ALL: [CubeFace; 6] = [CubeFace::PosX, CubeFace::NegX, CubeFace::PosY, CubeFace::NegY, CubeFace::PosZ, CubeFace::NegZ];
}

/// Point on the unit sphere for face coordinates `u, v` in `[-1, 1]`
/// (plain normalisation, so neighbouring faces share their edge vertices).
pub fn cube_to_sphere(face: CubeFace, u: f32, v: f32) -> Vec3 {
    let raw = match face {
        CubeFace::PosX => Vec3::new(1.0, u, v),
        CubeFace::NegX => Vec3::new(-1.0, u, v),
        CubeFace::PosY => Vec3::new(u, 1.0, v),
        CubeFace::NegY => Vec3::new(u, -1.0, v),
        CubeFace::PosZ => Vec3::new(u, v, 1.0),
        CubeFace::NegZ => Vec3::new(u, v, -1.0),
    };
    raw.normalize()
}

/// The whole sphere as six `n x n` grids, outward-facing triangles.
pub fn mesh(n: u32) -> Mesh {
    let mut positions: Vec<[f32; 3]> = Vec::with_capacity((6 * (n + 1) * (n + 1)) as usize);
    let mut indices: Vec<u32> = Vec::with_capacity((6 * n * n * 6) as usize);
    for face in CubeFace::ALL {
        let base = positions.len() as u32;
        for i in 0..=n {
            for j in 0..=n {
                let u = -1.0 + 2.0 * i as f32 / n as f32;
                let v = -1.0 + 2.0 * j as f32 / n as f32;
                positions.push(cube_to_sphere(face, u, v).to_array());
            }
        }
        for i in 0..n {
            for j in 0..n {
                let a = base + i * (n + 1) + j;
                let b = a + 1;
                let c = a + (n + 1);
                let d = c + 1;
                for tri in [[a, c, b], [b, c, d]] {
                    let p = |k: u32| Vec3::from_array(positions[k as usize]);
                    let outward = (p(tri[1]) - p(tri[0])).cross(p(tri[2]) - p(tri[0])).dot(p(tri[0])) > 0.0;
                    if outward {
                        indices.extend_from_slice(&tri);
                    } else {
                        indices.extend_from_slice(&[tri[0], tri[2], tri[1]]);
                    }
                }
            }
        }
    }
    let normals = positions.clone();
    Mesh::new(PrimitiveTopology::TriangleList, RenderAssetUsages::default())
        .with_inserted_attribute(Mesh::ATTRIBUTE_POSITION, positions)
        .with_inserted_attribute(Mesh::ATTRIBUTE_NORMAL, normals)
        .with_inserted_indices(Indices::U32(indices))
}

/// Distance from the centre to the faceted surface of `mesh(n)` along `dir`:
/// the flat triangle the ray crosses, so slightly under 1 away from the
/// vertices. Overlays that must sit on the ground (the drives) use it, as a
/// line at radius 1 floats over the facets when seen from street level.
pub fn surface_radius(n: u32, dir: Vec3) -> f32 {
    let d = dir.normalize();
    let a = d.abs();
    // the cube face the ray leaves through, and its (u, v) there, as in `cube_to_sphere`
    let (face, u, v) = if a.x >= a.y && a.x >= a.z {
        (if d.x > 0.0 { CubeFace::PosX } else { CubeFace::NegX }, d.y / a.x, d.z / a.x)
    } else if a.y >= a.z {
        (if d.y > 0.0 { CubeFace::PosY } else { CubeFace::NegY }, d.x / a.y, d.z / a.y)
    } else {
        (if d.z > 0.0 { CubeFace::PosZ } else { CubeFace::NegZ }, d.x / a.z, d.y / a.z)
    };
    let g = |x: f32| ((x + 1.0) * 0.5 * n as f32).clamp(0.0, n as f32);
    let (gu, gv) = (g(u), g(v));
    let (i, j) = ((gu.floor() as u32).min(n - 1), (gv.floor() as u32).min(n - 1));
    let (fu, fv) = (gu - i as f32, gv - j as f32);
    let at = |i: u32, j: u32| cube_to_sphere(face, -1.0 + 2.0 * i as f32 / n as f32, -1.0 + 2.0 * j as f32 / n as f32);
    // the cell is split along its (i, j+1)-(i+1, j) diagonal, as in `mesh`
    let tri = if fu + fv <= 1.0 { [at(i, j), at(i + 1, j), at(i, j + 1)] } else { [at(i, j + 1), at(i + 1, j), at(i + 1, j + 1)] };
    let normal = (tri[1] - tri[0]).cross(tri[2] - tri[0]);
    let den = normal.dot(d);
    if den.abs() < 1e-12 {
        return 1.0;
    }
    (normal.dot(tri[0]) / den).clamp(0.9, 1.0)
}

/// Unit vector for a latitude and longitude in radians.
pub fn latlon(lat: f32, lon: f32) -> Vec3 {
    Vec3::new(lat.cos() * lon.cos(), lat.sin(), -lat.cos() * lon.sin())
}

/// Append a lat/lon polyline (degrees) to an indexed line list on a sphere
/// of radius `r`, following the surface: a segment longer than half a degree
/// is subdivided (linearly in lat/lon, the short way round in longitude) so
/// that no chord dips below the surface. A straight border such as the 49th
/// parallel stays a parallel, which is what the data means.
pub fn surface_polyline(points: impl IntoIterator<Item = (f32, f32)>, r: f32, positions: &mut Vec<[f32; 3]>, indices: &mut Vec<u32>) {
    const MAX_STEP_DEG: f32 = 0.5;
    let mut prev: Option<(f32, f32)> = None;
    let mut last = 0u32;
    for (lat, lon) in points {
        match prev {
            None => {
                positions.push((latlon(lat.to_radians(), lon.to_radians()) * r).to_array());
                last = positions.len() as u32 - 1;
            }
            Some((plat, plon)) => {
                let mut dlon = lon - plon;
                if dlon > 180.0 {
                    dlon -= 360.0;
                } else if dlon < -180.0 {
                    dlon += 360.0;
                }
                let dlat = lat - plat;
                let span = dlat.abs().max(dlon.abs() * ((plat + lat) * 0.5).to_radians().cos().abs());
                let n = (span / MAX_STEP_DEG).ceil().max(1.0) as u32;
                for k in 1..=n {
                    let t = k as f32 / n as f32;
                    positions.push((latlon((plat + dlat * t).to_radians(), (plon + dlon * t).to_radians()) * r).to_array());
                    let idx = positions.len() as u32 - 1;
                    indices.push(last);
                    indices.push(idx);
                    last = idx;
                }
            }
        }
        prev = Some((lat, lon));
    }
}

/// How far a draped chord may stray from the facets (about 6 m): well under
/// the least lift of the overlays laid on the ground, so none dips under a crease.
const DRAPE_TOL: f32 = 1e-6;

/// `dir` (any length) put on the faceted surface of `mesh(n)`.
pub fn ground(n: u32, dir: Vec3) -> Vec3 {
    let d = dir.normalize();
    d * surface_radius(n, d)
}

/// The points strictly between `a` and `b` (both on the ground of `mesh(n)`)
/// that keep the chords through them on the facets: a piece is halved while
/// its middle is more than `DRAPE_TOL` off the ground, which only happens
/// where it crosses a crease (within one facet a chord lies on it).
fn drape(n: u32, a: Vec3, b: Vec3, depth: u32, out: &mut Vec<Vec3>) {
    let m = ground(n, a + b);
    if depth == 0 || (m.length() - ((a + b) * 0.5).length()).abs() <= DRAPE_TOL {
        return;
    }
    drape(n, a, m, depth - 1, out);
    out.push(m);
    drape(n, m, b, depth - 1, out);
}

/// `surface_polyline` on the faceted surface of `mesh(n)` rather than a
/// sphere: every point on the facets and every piece draped over the
/// creases, so the line lies on the ground the globe is drawn with, seen
/// from any height. The overlays built so are lifted off it by their
/// transform (the globe's `Grounded`).
pub fn ground_polyline(n: u32, points: impl IntoIterator<Item = (f32, f32)>, positions: &mut Vec<[f32; 3]>, indices: &mut Vec<u32>) {
    let (mut pos, mut idx) = (Vec::new(), Vec::new());
    surface_polyline(points, 1.0, &mut pos, &mut idx);
    let base = positions.len() as u32;
    positions.extend(pos.iter().map(|p| ground(n, Vec3::from_array(*p)).to_array()));
    let mut mid = Vec::new();
    for pair in idx.chunks_exact(2) {
        let (i, j) = (base + pair[0], base + pair[1]);
        mid.clear();
        drape(n, Vec3::from_array(positions[i as usize]), Vec3::from_array(positions[j as usize]), 20, &mut mid);
        let mut last = i;
        for p in &mid {
            positions.push(p.to_array());
            let k = positions.len() as u32 - 1;
            indices.extend([last, k]);
            last = k;
        }
        indices.extend([last, j]);
    }
}

/// Local east and north unit vectors at a point on the sphere.
pub fn frame(p: Vec3) -> (Vec3, Vec3) {
    let east = Vec3::Y.cross(p).try_normalize().unwrap_or(Vec3::NEG_Z);
    let north = p.cross(east).normalize();
    (east, north)
}

/// Line segments with per-vertex colours, built up then turned into a mesh.
#[derive(Default)]
pub struct Lines {
    positions: Vec<[f32; 3]>,
    colors: Vec<[f32; 4]>,
}

impl Lines {
    pub fn seg(&mut self, a: Vec3, b: Vec3, color: [f32; 4]) {
        self.positions.push(a.to_array());
        self.positions.push(b.to_array());
        self.colors.push(color);
        self.colors.push(color);
    }

    /// Polyline through `points` (already scaled to their radius).
    pub fn path(&mut self, points: impl IntoIterator<Item = Vec3>, color: [f32; 4]) {
        let mut prev: Option<Vec3> = None;
        for p in points {
            if let Some(q) = prev {
                self.seg(q, p, color);
            }
            prev = Some(p);
        }
    }

    /// Polyline through `points` (directions) laid on the faceted surface of
    /// `mesh(n)`, draped over its creases like `ground_polyline`.
    pub fn ground_path(&mut self, n: u32, points: impl IntoIterator<Item = Vec3>, color: [f32; 4]) {
        let mut prev: Option<Vec3> = None;
        let mut mid = Vec::new();
        for p in points {
            let p = ground(n, p);
            if let Some(q) = prev {
                mid.clear();
                drape(n, q, p, 20, &mut mid);
                let mut last = q;
                for m in mid.iter().copied().chain(std::iter::once(p)) {
                    self.seg(last, m, color);
                    last = m;
                }
            }
            prev = Some(p);
        }
    }

    /// A lat/lon polyline (degrees) on the surface, densified like
    /// `surface_polyline`, in one colour.
    pub fn surface_path(&mut self, points: impl IntoIterator<Item = (f32, f32)>, r: f32, color: [f32; 4]) {
        let (mut pos, mut idx) = (Vec::new(), Vec::new());
        surface_polyline(points, r, &mut pos, &mut idx);
        for pair in idx.chunks_exact(2) {
            self.seg(Vec3::from_array(pos[pair[0] as usize]), Vec3::from_array(pos[pair[1] as usize]), color);
        }
    }

    /// The segments' ends so far, two per segment.
    pub fn positions(&self) -> &[[f32; 3]] {
        &self.positions
    }

    pub fn mesh(mut self) -> Mesh {
        if self.positions.is_empty() {
            // wgpu will not draw from an empty vertex buffer; hide a segment inside the globe
            self.seg(Vec3::ZERO, Vec3::ZERO, [0.0; 4]);
        }
        Mesh::new(PrimitiveTopology::LineList, RenderAssetUsages::default())
            .with_inserted_attribute(Mesh::ATTRIBUTE_POSITION, self.positions)
            .with_inserted_attribute(Mesh::ATTRIBUTE_COLOR, self.colors)
    }
}

/// Filled shapes with per-vertex colours (triangle list), for markers that
/// should read as solid silhouettes rather than line art.
#[derive(Default)]
pub struct Shapes {
    positions: Vec<[f32; 3]>,
    colors: Vec<[f32; 4]>,
    indices: Vec<u32>,
}

impl Shapes {
    /// A convex polygon, fan-triangulated from its first vertex.
    pub fn convex(&mut self, points: &[Vec3], color: [f32; 4]) {
        if points.len() < 3 {
            return;
        }
        let base = self.positions.len() as u32;
        for p in points {
            self.positions.push(p.to_array());
            self.colors.push(color);
        }
        for i in 1..points.len() as u32 - 1 {
            self.indices.extend_from_slice(&[base, base + i, base + i + 1]);
        }
    }

    pub fn mesh(mut self) -> Mesh {
        if self.positions.is_empty() {
            self.convex(&[Vec3::ZERO, Vec3::ZERO, Vec3::ZERO], [0.0; 4]);
        }
        Mesh::new(PrimitiveTopology::TriangleList, RenderAssetUsages::default())
            .with_inserted_attribute(Mesh::ATTRIBUTE_POSITION, self.positions)
            .with_inserted_attribute(Mesh::ATTRIBUTE_COLOR, self.colors)
            .with_inserted_indices(Indices::U32(self.indices))
    }
}

/// An airliner seen from above, as convex pieces in glyph units: y is the
/// nose direction (span about 2, length about 2), x the wings. Each piece is
/// listed so `Shapes::convex` can fan it.
pub const AIRLINER: [&[[f32; 2]]; 5] = [
    // fuselage
    &[[0.0, 1.0], [0.13, 0.78], [0.13, -0.72], [0.07, -1.0], [-0.07, -1.0], [-0.13, -0.72], [-0.13, 0.78]],
    // wings
    &[[-0.13, 0.28], [-1.0, -0.38], [-1.0, -0.55], [-0.13, -0.18]],
    &[[0.13, 0.28], [0.13, -0.18], [1.0, -0.55], [1.0, -0.38]],
    // tailplane
    &[[-0.07, -0.72], [-0.46, -0.98], [-0.46, -1.08], [-0.07, -0.92]],
    &[[0.07, -0.72], [0.07, -0.92], [0.46, -1.08], [0.46, -0.98]],
];

/// A satellite: body, two solar panels and the boom between them, in glyph
/// units (x along the panels, span 2).
pub const SATELLITE: [&[[f32; 2]]; 4] = [
    &[[-0.3, 0.3], [0.3, 0.3], [0.3, -0.3], [-0.3, -0.3]],
    &[[-1.0, 0.24], [-0.42, 0.24], [-0.42, -0.24], [-1.0, -0.24]],
    &[[0.42, 0.24], [1.0, 0.24], [1.0, -0.24], [0.42, -0.24]],
    &[[-0.42, 0.06], [0.42, 0.06], [0.42, -0.06], [-0.42, -0.06]],
];

/// A diamond in glyph units.
pub const DIAMOND: [[f32; 2]; 4] = [[0.0, 1.0], [1.0, 0.0], [0.0, -1.0], [-1.0, 0.0]];

/// A unit circle as an `n`-gon in glyph units.
pub fn circle(n: usize) -> Vec<[f32; 2]> {
    (0..n).map(|i| {
        let a = i as f32 / n as f32 * std::f32::consts::TAU;
        [a.cos(), a.sin()]
    }).collect()
}

/// A convex polygon grown by `w` on every side (mitred corners, clamped at
/// sharp ones), for drawing an even rim under a shape.
pub fn offset_convex(pts: &[[f32; 2]], w: f32) -> Vec<[f32; 2]> {
    let n = pts.len();
    let v = |i: usize| Vec2::from_array(pts[i % n]);
    let area: f32 = (0..n).map(|i| v(i).perp_dot(v(i + 1))).sum();
    let sign = if area >= 0.0 { 1.0 } else { -1.0 };
    (0..n).map(|i| {
        let (prev, cur, next) = (v(i + n - 1), v(i), v(i + 1));
        let d0 = (cur - prev).normalize_or_zero();
        let d1 = (next - cur).normalize_or_zero();
        let n0 = Vec2::new(d0.y, -d0.x) * sign;
        let n1 = Vec2::new(d1.y, -d1.x) * sign;
        let m = n0 + n1;
        let out = if m.length() < 1e-4 { cur + n0 * w } else {
            let m = m.normalize();
            cur + m * (w / m.dot(n0).max(0.35))
        };
        out.to_array()
    }).collect()
}

/// Place a 2D glyph on the sphere: `p` its centre (unit vector), `up` the
/// glyph's y axis and `side` its x axis (unit tangents), `half` its half
/// size in world units, `radius` the sphere radius it sits at.
pub fn glyph(shapes: &mut Shapes, pieces: &[&[[f32; 2]]], p: Vec3, up: Vec3, side: Vec3, half: f32, radius: f32, color: [f32; 4]) {
    let mut pts: Vec<Vec3> = Vec::with_capacity(8);
    for piece in pieces {
        pts.clear();
        pts.extend(piece.iter().map(|[x, y]| (p + side * (x * half) + up * (y * half)) * radius));
        shapes.convex(&pts, color);
    }
}

/// The same glyph grown by `rim` glyph units on every side: drawn first, in
/// a dark colour, it gives the shape an even outline against any background.
pub fn glyph_rim(shapes: &mut Shapes, pieces: &[&[[f32; 2]]], p: Vec3, up: Vec3, side: Vec3, half: f32, rim: f32, radius: f32, color: [f32; 4]) {
    for piece in pieces {
        let grown = offset_convex(piece, rim);
        glyph(shapes, &[&grown], p, up, side, half, radius, color);
    }
}

/// A glyph floating in space, facing the camera: `right` and `up` are the
/// camera's axes, `p` the centre in world units.
pub fn billboard(shapes: &mut Shapes, pieces: &[&[[f32; 2]]], p: Vec3, right: Vec3, up: Vec3, half: f32, color: [f32; 4]) {
    let mut pts: Vec<Vec3> = Vec::with_capacity(8);
    for piece in pieces {
        pts.clear();
        pts.extend(piece.iter().map(|[x, y]| p + right * (x * half) + up * (y * half)));
        shapes.convex(&pts, color);
    }
}

pub fn billboard_rim(shapes: &mut Shapes, pieces: &[&[[f32; 2]]], p: Vec3, right: Vec3, up: Vec3, half: f32, rim: f32, color: [f32; 4]) {
    for piece in pieces {
        let grown = offset_convex(piece, rim);
        billboard(shapes, &[&grown], p, right, up, half, color);
    }
}
