//! The land mask under the globe's flat inks: Natural Earth's 1:50m
//! coastlines (the shuttle scene's coastline.bin, as the Sputnik wallpaper's
//! printed Earth uses) filled into an equirectangular R8 texture, 255 on
//! land, softened so the shader's 0.5 contour is a smooth coast. Built once
//! per process on a worker thread (a recreated widget reuses it); the globe
//! shows plain ocean until it lands.
use std::sync::OnceLock;

const COASTLINE: &[u8] = include_bytes!("../../../../scripts/wallpaper/bins/space_shuttle/scene/src/coastline.bin");

pub const LAND_W: u32 = 4096;
pub const LAND_H: u32 = 2048;
/// Lighter than the Sputnik poster's (0.8 degrees, islands over 6 square
/// degrees): the globe zooms in, so the mask keeps the coast's shape and
/// every island the 50m data has.
const COAST_TOLERANCE: f64 = 0.03;
const MIN_ISLAND: f64 = 0.02;

static MASK: OnceLock<Vec<u8>> = OnceLock::new();

/// The mask, built on first use (~0.1 s).
pub fn mask() -> &'static [u8] {
    MASK.get_or_init(build)
}

/// The mask if it is built.
pub fn ready() -> Option<&'static [u8]> {
    MASK.get().map(Vec::as_slice)
}

/// Douglas-Peucker: the points of `pts` (an open polyline) that keep it
/// within `tol` of the original (as in sputnik_scene).
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

/// Every coastline ring filled (even-odd, per ring) into the mask; the data's polylines
/// are rings, except Antarctica's, which runs round the coast and is closed
/// through the pole. Then two box passes each way (wrapping in longitude).
fn build() -> Vec<u8> {
    let (w, h) = (LAND_W as usize, LAND_H as usize);
    let mut mask = vec![0u8; w * h];
    if COASTLINE.len() < 4 {
        return mask;
    }
    let rd = |o: usize| u32::from_le_bytes(COASTLINE[o..o + 4].try_into().unwrap());
    let rf = |o: usize| f32::from_le_bytes(COASTLINE[o..o + 4].try_into().unwrap()) as f64;
    let mut off = 4;
    let count = rd(0) as usize;
    let mut xs: Vec<f64> = Vec::new();
    for _ in 0..count {
        if off + 4 > COASTLINE.len() {
            break;
        }
        let n = rd(off) as usize;
        off += 4;
        if off + n * 8 > COASTLINE.len() {
            break;
        }
        // longitude unwrapped across the antimeridian
        let mut pts: Vec<(f64, f64)> = Vec::with_capacity(n + 2);
        let (mut prev, mut shift) = (0.0, 0.0);
        for i in 0..n {
            let (lon, lat) = (rf(off), rf(off + 4));
            off += 8;
            if i > 0 {
                if lon + shift - prev > 180.0 {
                    shift -= 360.0
                } else if lon + shift - prev < -180.0 {
                    shift += 360.0
                }
            }
            prev = lon + shift;
            pts.push((prev, lat));
        }
        if pts.len() < 3 {
            continue;
        }
        let span = pts.iter().map(|p| p.0).fold(f64::MIN, f64::max) - pts.iter().map(|p| p.0).fold(f64::MAX, f64::min);
        if span > 300.0 {
            pts = simplify(&pts, COAST_TOLERANCE);
            let (first, last) = (pts[0], pts[pts.len() - 1]);
            pts.push((last.0, -90.0));
            pts.push((first.0, -90.0));
        } else {
            let twice_area: f64 = (0..pts.len())
                .map(|i| {
                    let (p, q) = (pts[i], pts[(i + 1) % pts.len()]);
                    p.0 * q.1 - q.0 * p.1
                })
                .sum();
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
        let (row0, row1) = ((ymin - 0.5).floor().max(0.0) as usize, ((ymax + 0.5).ceil().max(0.0) as usize).min(h - 1));
        for row in row0..=row1 {
            let yc = row as f64 + 0.5;
            xs.clear();
            for i in 0..px.len() {
                let (p0, p1) = (px[i], px[(i + 1) % px.len()]);
                if (p0.1 <= yc) != (p1.1 <= yc) {
                    xs.push(p0.0 + (yc - p0.1) / (p1.1 - p0.1) * (p1.0 - p0.0));
                }
            }
            xs.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
            for pair in xs.chunks_exact(2) {
                let (x0, x1) = ((pair[0] - 0.5).ceil() as i64, (pair[1] - 0.5).floor() as i64);
                for x in x0..=x1 {
                    mask[row * w + x.rem_euclid(w as i64) as usize] = 255;
                }
            }
        }
    }
    // Softened so the 0.5 contour runs between texels
    let r = 1usize;
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
