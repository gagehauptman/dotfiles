#!/usr/bin/env python3
"""Converts NASA's Space Shuttle orbiter model (NASA 3D Resources, "Space
Shuttle (C)", public domain) into the wallpaper's compact wireframe asset,
orbiter.bin. Offline, run once; needs numpy and DracoPy (the .glb is Draco
compressed) and glb.py next to it.

    orbiter_edges.py <Space Shuttle (C).glb> <out orbiter.bin> [--preview out.npz]

What it keeps:
- the surface triangles (welded), only to hide the edges behind them;
- feature edges: open boundaries and creases sharper than CREASE degrees,
  except in coarse rounds (the wings' leading edges: a few facets a hand
  wide, 40-47 degrees apart), which are silhouette candidates instead:
  drawn as creases, they fan out into streaks near the wing tips;
- silhouette candidates: the remaining edges between faces that aren't
  coplanar, with both face normals, so the shader can draw the ones on the
  outline for the current pose (a smooth fuselage has no creases there).
  Even nearly flat ones: the aft belly curves by under 2 degrees per facet,
  and without them its outline, seen edge-on, isn't drawn at all.

What it adds: the model's payload bay is open and has no doors, so closed
doors are added (see add_doors): their surface, continuing the fuselage's
section just forward of the bay, and their outline, centreline seam, hinge
lines, segment joints and curve. The bay lining's lines, now shut in, go.

Output frame: metres, x toward the nose, y up (payload bay side), z to
starboard, origin at mid-length and mid-height.

orbiter.bin, little endian: u32 vertex count, u32 triangle count, u32 line
count; vertices f32 x3; triangles u16 x3; lines (u16 a, u16 b, u32 n0,
u32 n1): n0 = 0 for a crease/boundary, else an outline candidate, its two
face normals 12-bit octahedral, n0 = 1 + (x0 | y0 << 12) (<= 2^24) and
n1 = x1 | y1 << 12 (< 2^24), so both are exact as f32s. 6 bits (2 degrees)
was too coarse for the nearly flat candidates.
"""
import struct
import sys

import numpy as np

import glb

INCH = 0.0254
WELD = 0.05 * INCH       # vertex weld tolerance (m)
CREASE = 38.0            # degrees: sharper than this is a drawn edge
FLAT = 0.1               # degrees: flatter than this can't make an outline
ROUND = 50.0             # degrees: a crease up to this, between faces
ROUND_WIDTH = 0.35       # m: this narrow together across it, is a round
SLIVER = 0.015           # m: unless one is a sliver this narrow
MIN_CHAIN = 0.6          # m: drop connected crease/boundary pieces shorter than this

# NASA's model has the payload bay open with no doors, so they're added:
BAY = (-8.65, 10.02)     # m: x of the bay's aft and forward bulkheads
HINGE_Y = -3.0           # m: door hinge lines, on top of the sills
DOOR_ARC = 12            # segments per door across its curve
DOOR_PANELS = 4          # segments per door along the bay


def oct_encode(n, bits=12):
    n = n / np.abs(n).sum(axis=1, keepdims=True)
    x, y = n[:, 0].copy(), n[:, 1].copy()
    neg = n[:, 2] < 0
    x[neg], y[neg] = ((1 - np.abs(n[neg, 1])) * np.sign(n[neg, 0] + 1e-30),
                      (1 - np.abs(n[neg, 0])) * np.sign(n[neg, 1] + 1e-30))
    q = (1 << bits) - 1
    return (np.clip(np.round((x * 0.5 + 0.5) * q), 0, q).astype(np.int64),
            np.clip(np.round((y * 0.5 + 0.5) * q), 0, q).astype(np.int64))


def door_profile(verts, tris):
    """(|z|, y) points of one door's curve, hinge to centreline: the closed
    fuselage's outer skin just forward of the bay, which the doors continue.
    Ray cast from the bay axis at hinge height, both sides averaged."""
    X = BAY[1] + 0.18
    p = verts[tris]
    s = p[..., 0] - X
    # Each crossing triangle gives one segment: its two crossing points.
    per_tri = {}
    for i, j in ((0, 1), (1, 2), (2, 0)):
        m = np.nonzero((s[:, i] < 0) != (s[:, j] < 0))[0]
        u = s[m, i] / (s[m, i] - s[m, j])
        q = p[m, i] + u[:, None] * (p[m, j] - p[m, i])
        for t, pt in zip(m, q):
            per_tri.setdefault(t, []).append(pt[[2, 1]] - [0.0, HINGE_Y])
    segs = np.array([v[:2] for v in per_tri.values() if len(v) >= 2])
    a, b = segs[:, 0], segs[:, 1]
    out = []
    for th in np.linspace(0.0, np.pi / 2, DOOR_ARC + 1):
        r = []
        for side in (1.0, -1.0):
            d = np.array([side * np.cos(th), np.sin(th)])
            # Solve a + u (b - a) = t d for the farthest hit with t > 0.
            e = b - a
            den = e[:, 0] * d[1] - e[:, 1] * d[0]
            ok = np.abs(den) > 1e-12
            u = np.where(ok, (a[:, 1] * d[0] - a[:, 0] * d[1]) / np.where(ok, den, 1), -1)
            t = np.where(ok, (e[:, 0] * a[:, 1] - e[:, 1] * a[:, 0]) / np.where(ok, den, 1), -1)
            hit = ok & (u >= -1e-6) & (u <= 1 + 1e-6) & (t > 0)
            r.append(t[hit].max())
        rr = 0.5 * (r[0] + r[1])
        out.append((rr * np.cos(th), HINGE_Y + rr * np.sin(th)))
    return np.array(out)


def add_doors(verts, tris, fn, lines):
    """Closed payload bay doors: a surface (hides what's behind it) and the
    edges: outline, centreline seam, hinge lines, the joints between each
    door's DOOR_PANELS segments, and outline candidates along the curve.
    Drops the bay lining's lines, now shut in."""
    prof = door_profile(verts, tris)
    xs = np.linspace(BAY[0], BAY[1], DOOR_PANELS + 1)
    new_v, new_t, new_fn, new_lines = [], [], [], []
    base_v, base_t = len(verts), len(tris)
    for side in (1.0, -1.0):
        grid = []
        for x in xs:
            row = []
            for z, y in prof:
                row.append(len(new_v))
                new_v.append((x, y, side * z))
            grid.append(row)
        g = lambda j, k: base_v + grid[j][k]
        face = {}
        for j in range(DOOR_PANELS):
            for k in range(DOOR_ARC):
                q = [g(j, k), g(j + 1, k), g(j + 1, k + 1), g(j, k + 1)]
                for tri in ((q[0], q[1], q[2]), (q[0], q[2], q[3])):
                    P = np.array([new_v[i - base_v] for i in tri])
                    n = np.cross(P[1] - P[0], P[2] - P[0])
                    n /= np.linalg.norm(n)
                    c = P.mean(0)
                    if n[1] * (c[1] - HINGE_Y) + n[2] * c[2] < 0:
                        tri, n = (tri[0], tri[2], tri[1]), -n
                    face.setdefault((j, k), base_t + len(new_t))
                    new_t.append(tri)
                    new_fn.append(n)
        for j in range(DOOR_PANELS):
            new_lines.append((g(j, 0), g(j + 1, 0), 0))                # hinge
            if side > 0:
                new_lines.append((g(j, DOOR_ARC), g(j + 1, DOOR_ARC), 0))  # seam
            for k in range(1, DOOR_ARC):                               # curve
                new_lines.append((g(j, k), g(j + 1, k), [face[j, k - 1], face[j, k]]))
        for j in range(DOOR_PANELS + 1):                               # ends, joints
            for k in range(DOOR_ARC):
                new_lines.append((g(j, k), g(j, k + 1), 0))

    def shut_in(p):
        return ((BAY[0] + 0.05 < p[:, 0]) & (p[:, 0] < BAY[1] - 0.05)
                & (np.abs(p[:, 2]) < 2.45) & (p[:, 1] > -6.0))
    ab = np.array([(a, b) for a, b, _ in lines])
    keep = ~(shut_in(verts[ab[:, 0]]) & shut_in(verts[ab[:, 1]]))
    lines = [l for l, k in zip(lines, keep) if k] + new_lines
    verts = np.vstack([verts, np.array(new_v)])
    tris = np.vstack([tris, np.array(new_t)])
    fn = np.vstack([fn, np.array(new_fn)])
    return verts, tris, fn, lines, int((~keep).sum())


def convert(path):
    _, prims = glb.load(path)
    pos = np.vstack([p[1] for p in prims])
    tris, base = [], 0
    for _, w, i in prims:
        tris.append(i + base)
        base += len(w)
    tris = np.vstack(tris)

    # NASA frame: inches, x nose, z up, y port -> ours.
    pos = np.stack([pos[:, 0], pos[:, 2], -pos[:, 1]], axis=1) * INCH
    lo, hi = pos.min(0), pos.max(0)
    pos -= [(lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2, 0.0]

    # Weld.
    key = np.round(pos / WELD).astype(np.int64)
    _, first, remap = np.unique(key, axis=0, return_index=True, return_inverse=True)
    verts = pos[first]
    tris = remap.reshape(-1)[tris]
    tris = tris[(tris[:, 0] != tris[:, 1]) & (tris[:, 1] != tris[:, 2]) & (tris[:, 0] != tris[:, 2])]

    fn = np.cross(verts[tris[:, 1]] - verts[tris[:, 0]], verts[tris[:, 2]] - verts[tris[:, 0]])
    area = np.linalg.norm(fn, axis=1)
    keep = area > 1e-12
    tris, fn, area = tris[keep], fn[keep], area[keep]
    fn /= area[:, None]

    edges = {}
    for f, t in enumerate(tris):
        for a, b in ((t[0], t[1]), (t[1], t[2]), (t[2], t[0])):
            edges.setdefault((min(a, b), max(a, b)), []).append(f)

    cos_crease, cos_flat = np.cos(np.radians(CREASE)), np.cos(np.radians(FLAT))
    cos_round = np.cos(np.radians(ROUND))

    def width(f, a, b):
        # How far face f reaches across its edge a-b.
        c = next(v for v in tris[f] if v != a and v != b)
        e = verts[b] - verts[a]
        return float(np.linalg.norm(np.cross(e, verts[c] - verts[a])) / np.linalg.norm(e))

    lines = []
    stats = dict(boundary=0, crease=0, round=0, nonmanifold=0, silhouette=0, flat=0)
    for (a, b), fs in edges.items():
        if len(fs) != 2:
            lines.append((a, b, 0))
            stats['boundary' if len(fs) == 1 else 'nonmanifold'] += 1
            continue
        c = float(np.dot(fn[fs[0]], fn[fs[1]]))
        if cos_round <= c < cos_crease:
            w = [width(f, a, b) for f in fs]
            if min(w) >= SLIVER and sum(w) < ROUND_WIDTH:
                lines.append((a, b, fs))
                stats['round'] += 1
                continue
        if c < cos_crease:
            lines.append((a, b, 0))
            stats['crease'] += 1
        elif c < cos_flat:
            lines.append((a, b, fs))
            stats['silhouette'] += 1
        else:
            stats['flat'] += 1

    # Decimate: crease/boundary pieces whose connected chain is shorter than
    # MIN_CHAIN are specks (bolts, slivers, panel overlaps) at wallpaper size.
    parent = {}

    def find(x):
        while parent.setdefault(x, x) != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x
    feats = [l for l in lines if l[2] == 0]
    for a, b, _ in feats:
        parent[find(a)] = find(b)
    chain = {}
    for a, b, _ in feats:
        r = find(a)
        chain[r] = chain.get(r, 0.0) + float(np.linalg.norm(verts[a] - verts[b]))
    before = len(lines)
    lines = [l for l in lines if l[2] != 0 or chain[find(l[0])] >= MIN_CHAIN]
    stats['dropped'] = before - len(lines)

    verts, tris, fn, lines, stats['shut_in'] = add_doors(verts, tris, fn, lines)

    sil = [l for l in lines if l[2] != 0]
    if sil:
        n = np.array([[fn[l[2][0]], fn[l[2][1]]] for l in sil])
        x0, y0 = oct_encode(n[:, 0])
        x1, y1 = oct_encode(n[:, 1])
        codes = iter(zip(1 + (x0 | y0 << 12), x1 | y1 << 12))
    lines = [(a, b, (0, 0) if f == 0 else tuple(map(int, next(codes)))) for a, b, f in lines]
    return verts, tris, lines, fn, stats


def main():
    src, out = sys.argv[1], sys.argv[2]
    verts, tris, lines, fn, stats = convert(src)
    assert len(verts) < 65536
    with open(out, 'wb') as f:
        f.write(struct.pack('<III', len(verts), len(tris), len(lines)))
        f.write(verts.astype('<f4').tobytes())
        f.write(tris.astype('<u2').tobytes())
        for a, b, (n0, n1) in lines:
            f.write(struct.pack('<HHII', a, b, n0, n1))
    lo, hi = verts.min(0), verts.max(0)
    print(f'{len(verts)} verts, {len(tris)} tris, {len(lines)} lines {stats}; '
          f'extent {np.round(lo, 2)} .. {np.round(hi, 2)} m')
    if '--preview' in sys.argv:
        np.savez(sys.argv[sys.argv.index('--preview') + 1], verts=verts, tris=tris,
                 lines=np.array([(a, b, *n) for a, b, n in lines], np.int64))


if __name__ == '__main__':
    main()
