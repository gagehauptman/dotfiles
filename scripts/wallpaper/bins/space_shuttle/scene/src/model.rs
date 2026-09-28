//! The Space Shuttle orbiter's wireframe, from NASA's public-domain model
//! (NASA 3D Resources, "Space Shuttle (C)",
//! github.com/nasa/NASA-3D-Resources; NASA media are not copyrighted).
//! `orbiter.bin` is baked offline from it by `tools/orbiter_edges.py`, which
//! documents the format. The model's payload bay is open with no doors; the
//! baker adds closed ones, shaped to the fuselage.
//!
//! Coordinates are metres: x toward the nose, y up (payload bay side), z to
//! starboard, origin at mid-length and mid-height. Gives the edges to draw
//! and a triangle mesh of the surfaces, only for hiding the edges behind
//! them.
use crate::Instance;

const ASSET: &[u8] = include_bytes!("orbiter.bin");

/// The hiding mesh is shrunk this far (m) along its vertex normals, about
/// 3 px on screen: the thick lines sit on the hull, and without it the
/// curved surface just inside an outline (0.4 m nearer the camera 1 px in
/// on the nose) or next to a crease hides half the line or all of it.
const INSET: f32 = 0.08;

pub struct Orbiter {
    pub mesh: Vec<[f32; 4]>,
    pub lines: Vec<Instance>,
}

fn u16_at(i: usize) -> u16 {
    u16::from_le_bytes([ASSET[i], ASSET[i + 1]])
}

fn u32_at(i: usize) -> u32 {
    u32::from_le_bytes(ASSET[i..i + 4].try_into().unwrap())
}

fn f32_at(i: usize) -> f32 {
    f32::from_bits(u32_at(i))
}

pub fn build() -> Orbiter {
    let (nv, nt, nl) = (u32_at(0) as usize, u32_at(4) as usize, u32_at(8) as usize);
    let vert_at = 12;
    let tri_at = vert_at + 12 * nv;
    let line_at = tri_at + 6 * nt;
    assert_eq!(ASSET.len(), line_at + 12 * nl, "orbiter.bin size");

    let vertex = |i: u16| {
        let o = vert_at + 12 * i as usize;
        [f32_at(o), f32_at(o + 4), f32_at(o + 8)]
    };

    let tris: Vec<[usize; 3]> = (0..nt)
        .map(|t| [0, 1, 2].map(|j| u16_at(tri_at + 6 * t + 2 * j) as usize))
        .collect();
    let verts: Vec<[f32; 3]> = (0..nv).map(|i| vertex(i as u16)).collect();
    let normals = vertex_normals(&verts, &tris);
    let mesh = tris
        .iter()
        .flatten()
        .map(|&i| {
            let (p, n) = (verts[i], normals[i]);
            [p[0] - INSET * n[0], p[1] - INSET * n[1], p[2] - INSET * n[2], 1.0]
        })
        .collect();

    let lines = (0..nl)
        .map(|k| {
            let o = line_at + 12 * k;
            let (a, b) = (vertex(u16_at(o)), vertex(u16_at(o + 2)));
            // The face normals' codes are <= 2^24, so exact as f32s.
            let (n0, n1) = (u32_at(o + 4), u32_at(o + 8));
            Instance { a: [a[0], a[1], a[2], n1 as f32], b: [b[0], b[1], b[2], n0 as f32] }
        })
        .collect();

    Orbiter { mesh, lines }
}

fn sub(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

fn cross(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
}

fn dot(a: [f32; 3], b: [f32; 3]) -> f32 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

/// Outward unit normals per vertex (area weighted). NASA's winding is
/// consistent within each piece of the model but not its sense, so each
/// connected piece is turned to face away from its own centre.
fn vertex_normals(verts: &[[f32; 3]], tris: &[[usize; 3]]) -> Vec<[f32; 3]> {
    let mut parent: Vec<usize> = (0..verts.len()).collect();
    fn find(parent: &mut [usize], mut x: usize) -> usize {
        while parent[x] != x {
            parent[x] = parent[parent[x]];
            x = parent[x];
        }
        x
    }
    for t in tris {
        for j in 1..3 {
            let (a, b) = (find(&mut parent, t[0]), find(&mut parent, t[j]));
            parent[a] = b;
        }
    }
    let piece: Vec<usize> = (0..verts.len()).map(|i| find(&mut parent, i)).collect();

    // Area-weighted face normals (twice the area) and centroids.
    let faces: Vec<([f32; 3], [f32; 3])> = tris
        .iter()
        .map(|t| {
            let [a, b, c] = t.map(|i| verts[i]);
            let centre = [(a[0] + b[0] + c[0]) / 3.0, (a[1] + b[1] + c[1]) / 3.0, (a[2] + b[2] + c[2]) / 3.0];
            (cross(sub(b, a), sub(c, a)), centre)
        })
        .collect();
    let mut centre = vec![[0.0f32; 4]; verts.len()];
    for (t, (n, c)) in tris.iter().zip(&faces) {
        let (w, r) = (dot(*n, *n).sqrt(), &mut centre[piece[t[0]]]);
        for j in 0..3 {
            r[j] += w * c[j];
        }
        r[3] += w;
    }
    let mut sense = vec![0.0f32; verts.len()];
    for (t, (n, c)) in tris.iter().zip(&faces) {
        let r = centre[piece[t[0]]];
        let o = [r[0] / r[3], r[1] / r[3], r[2] / r[3]];
        sense[piece[t[0]]] += dot(*n, sub(*c, o));
    }

    let mut normals = vec![[0.0f32; 3]; verts.len()];
    for (t, (n, _)) in tris.iter().zip(&faces) {
        let s = if sense[piece[t[0]]] < 0.0 { -1.0 } else { 1.0 };
        for &i in t {
            for j in 0..3 {
                normals[i][j] += s * n[j];
            }
        }
    }
    for n in &mut normals {
        let l = dot(*n, *n).sqrt();
        if l > 0.0 {
            *n = n.map(|x| x / l);
        }
    }
    normals
}
