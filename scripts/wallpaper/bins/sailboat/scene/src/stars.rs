//! The real sky's stars: the Yale Bright Star Catalogue (`stars.bin`, baked by `tools/gen_stars.py`)
//! binned into a cube-map grid the fragment shader reads as one storage buffer.
//!
//! Grid: 6 faces × [`GRID`]² cells, the same gnomonic cube map the shader uses on the celestial
//! direction (face = dominant axis, uv = the other two / |dominant|). Every star is listed in every
//! cell its glow can reach ([`reach_px`]), so a pixel reads its own cell only: no neighbour logic, no
//! halo clipped at cell or face edges.
//!
//! Buffer (`vec4<f32>` each): `[0, 6·GRID²)` one entry per cell = (first, count, 0, 0) with `first`
//! an absolute index; then the star records = (x, y, z, packed), x/y/z the J2000 unit vector and
//! packed = magq · 1024 + bvq, magq = round((V + 2) · 50), bvq = clamp(round((B−V + 0.5) · 200), 0, 1023).
//! The shader mirrors [`reach_px`] and the packing; keep them in step.
/// Cells per cube-face edge.
pub const GRID: usize = 64;

const CATALOG: &[u8] = include_bytes!("stars.bin");

pub struct Star {
    /// J2000 right ascension and declination, radians (proper motion applied to 2025.0).
    pub ra: f64,
    pub dec: f64,
    pub vmag: f64,
    /// B−V colour index (0.65, a Sun-like white, when the catalogue has none).
    pub bv: f64,
    /// Harvard Revised (Bright Star) number.
    pub hr: u32,
}

impl Star {
    /// Unit vector in the J2000 equatorial frame (x to RA 0, z to the north celestial pole).
    pub fn dir(&self) -> [f64; 3] {
        [self.dec.cos() * self.ra.cos(), self.dec.cos() * self.ra.sin(), self.dec.sin()]
    }
}

pub fn catalog() -> Vec<Star> {
    assert_eq!(&CATALOG[..4], b"SBST");
    let n = u32::from_le_bytes(CATALOG[4..8].try_into().unwrap()) as usize;
    (0..n)
        .map(|i| {
            let r = &CATALOG[8 + 14 * i..22 + 14 * i];
            let f = |o: usize| f32::from_le_bytes(r[o..o + 4].try_into().unwrap()) as f64;
            let h = |o: usize| i16::from_le_bytes(r[o..o + 2].try_into().unwrap());
            let bv = h(10);
            Star {
                ra: f(0),
                dec: f(4),
                vmag: h(8) as f64 / 100.0,
                bv: if bv == i16::MIN { 0.65 } else { bv as f64 / 100.0 },
                hr: u16::from_le_bytes(r[12..14].try_into().unwrap()) as u32,
            }
        })
        .collect()
}

/// How far a star's glow reaches, in pixels of a 1440-line output (the shader scales it with the
/// output height): halo and glint fade to nothing here. MUST match `star_reach()` in sailboat.wgsl.
pub fn reach_px(vmag: f64) -> f64 {
    (5.0 + 8.2 * (4.5 - vmag)).clamp(3.2, 60.0)
}

/// Radians per pixel at the centre of a 1440-line output (the widest a pixel is).
fn rad_per_px() -> f64 {
    2.0 * crate::TAN_HALF_FOV / 1440.0
}

/// Cube face and uv (−1..1) of a direction, as the shader does it.
pub fn face_uv(c: [f64; 3]) -> (usize, [f64; 2]) {
    let a = [c[0].abs(), c[1].abs(), c[2].abs()];
    if a[0] >= a[1] && a[0] >= a[2] {
        (if c[0] < 0.0 { 1 } else { 0 }, [c[1] / a[0], c[2] / a[0]])
    } else if a[1] >= a[2] {
        (if c[1] < 0.0 { 3 } else { 2 }, [c[0] / a[1], c[2] / a[1]])
    } else {
        (if c[2] < 0.0 { 5 } else { 4 }, [c[0] / a[2], c[1] / a[2]])
    }
}

/// Where a direction lands on face `f`'s plane: (u, v, cos of the angle to the face axis).
fn on_face(f: usize, c: [f64; 3]) -> (f64, f64, f64) {
    let (ax, a, b, s) = match f {
        0 => (0, 1, 2, 1.0),
        1 => (0, 1, 2, -1.0),
        2 => (1, 0, 2, 1.0),
        3 => (1, 0, 2, -1.0),
        4 => (2, 0, 1, 1.0),
        _ => (2, 0, 1, -1.0),
    };
    let w = c[ax] * s;
    (c[a] / w, c[b] / w, w)
}

/// The packed `w` of a star record.
pub fn pack(vmag: f64, bv: f64) -> f32 {
    let m = ((vmag + 2.0) * 50.0).round().clamp(0.0, 1023.0);
    let b = ((bv + 0.5) * 200.0).round().clamp(0.0, 1023.0);
    (m * 1024.0 + b) as f32
}

/// The grid + star records the shader reads (see the module docs).
pub fn gpu_table() -> Vec<[f32; 4]> {
    let stars = catalog();
    let cells = 6 * GRID * GRID;
    let mut lists: Vec<Vec<u32>> = vec![Vec::new(); cells];
    let n = GRID as f64;
    for (i, s) in stars.iter().enumerate() {
        let c = s.dir();
        // Reach as an angle, padded; on a face the plane distance grows by up to (1 + u² + v²).
        let r = reach_px(s.vmag) * rad_per_px() * 1.1 + 0.002;
        for f in 0..6 {
            let (u, v, w) = on_face(f, c);
            if w < 0.3 {
                continue;
            }
            let k = r.tan() * (1.0 + u * u + v * v);
            if u.abs() - k > 1.0 || v.abs() - k > 1.0 {
                continue;
            }
            let idx = |x: f64| (((x * 0.5 + 0.5) * n).floor() as i64).clamp(0, GRID as i64 - 1) as usize;
            for cy in idx(v - k)..=idx(v + k) {
                for cx in idx(u - k)..=idx(u + k) {
                    // The cell rectangle must come within k of the star (corners of the box don't).
                    let (x0, x1) = ((cx as f64 / n) * 2.0 - 1.0, ((cx + 1) as f64 / n) * 2.0 - 1.0);
                    let (y0, y1) = ((cy as f64 / n) * 2.0 - 1.0, ((cy + 1) as f64 / n) * 2.0 - 1.0);
                    let dx = (x0 - u).max(0.0).max(u - x1);
                    let dy = (y0 - v).max(0.0).max(v - y1);
                    if dx * dx + dy * dy <= k * k {
                        lists[f * GRID * GRID + cy * GRID + cx].push(i as u32);
                    }
                }
            }
        }
    }
    let total: usize = lists.iter().map(Vec::len).sum();
    let mut out = vec![[0.0f32; 4]; cells];
    out.reserve(total);
    for (cell, list) in lists.iter().enumerate() {
        out[cell] = [out.len() as f32, list.len() as f32, 0.0, 0.0];
        for &i in list {
            let s = &stars[i as usize];
            let d = s.dir();
            out.push([d[0] as f32, d[1] as f32, d[2] as f32, pack(s.vmag, s.bv)]);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    #[test]
    fn table_stats() {
        let t = super::gpu_table();
        let cells = 6 * super::GRID * super::GRID;
        let maxc = t[..cells].iter().map(|c| c[1] as usize).max().unwrap();
        let occupied = t[..cells].iter().filter(|c| c[1] > 0.0).count();
        println!("entries {} (cells {cells}), records {}, max/cell {maxc}, occupied cells {occupied}", t.len(), t.len() - cells);
        assert!(super::catalog().len() > 8900);
    }
}
