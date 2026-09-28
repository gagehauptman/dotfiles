// The space shuttle wallpaper: a wireframe orbiter drifting over the Earth's
// limb, with stars. Same look as the globe (globe.wgsl): lines whose core
// saturates to near-white with a faint green halo (the orbiter's are
// thicker, `proj.w` px), faint teal dot grid,
// Catppuccin Mocha on Base, 8-bit non-sRGB target.
//
// Screen coordinates are output pixels, (0, 0) top-left; `offset` shifts
// them into the render target (a centre crop for the selector preview).
// Depth is 1/z-linear so it interpolates exactly in screen space; the
// background sits at depth 1 and is masked where the orbiter is.

struct Globals {
    viewport: vec2<f32>,
    offset: vec2<f32>,
    output: vec2<f32>,
    time: f32,    // twinkle clock, 0..1000 s, wrapping seamlessly
    hidden: f32,  // intensity of the orbiter's hidden edges (0: not drawn)
    earth: vec4<f32>, // centre x, y (output px), radius, 0
    er0: vec4<f32>,   // Earth rotation rows (x toward viewer, y right, z up)
    er1: vec4<f32>,
    er2: vec4<f32>,
    m0: vec4<f32>,    // orbiter model -> view rows, w = translation (m)
    m1: vec4<f32>,
    m2: vec4<f32>,
    proj: vec4<f32>,  // focal length px, principal point x, y (output px), line width px
    depth: vec4<f32>, // 1/near, 1/near - 1/far, line bias, 0
};

@group(0) @binding(0) var<uniform> g: Globals;
// The orbiter's surfaces' depth (the prepass), for the edges' hidden-line
// test.
@group(1) @binding(0) var hull_depth: texture_depth_2d;

// Catppuccin Mocha
const BG: vec3<f32> = vec3<f32>(30.0, 30.0, 46.0) / 255.0;          // Base
const GREEN: vec3<f32> = vec3<f32>(166.0, 227.0, 161.0) / 255.0;    // Green
const TEAL: vec3<f32> = vec3<f32>(148.0, 226.0, 213.0) / 255.0;     // Teal
const SAPPHIRE: vec3<f32> = vec3<f32>(116.0, 199.0, 236.0) / 255.0; // Sapphire
const TEXT: vec3<f32> = vec3<f32>(205.0, 214.0, 244.0) / 255.0;     // Text
const LAVENDER: vec3<f32> = vec3<f32>(180.0, 190.0, 254.0) / 255.0; // Lavender
const ROSEWATER: vec3<f32> = vec3<f32>(245.0, 224.0, 220.0) / 255.0; // Rosewater

const TAU: f32 = 6.283185307;
const CLIPPED: vec4<f32> = vec4<f32>(0.0, 0.0, 2.0, 1.0);

fn to_clip(pixel: vec2<f32>, depth: f32) -> vec4<f32> {
    let p = pixel - g.offset;
    return vec4<f32>(p.x / g.viewport.x * 2.0 - 1.0, 1.0 - p.y / g.viewport.y * 2.0, depth, 1.0);
}

// ---------------------------------------------------------------------------
// Lines: one quad per segment, shaded by distance like the globe's
// continents (a saturating core and a 0.3 halo, here `proj.w` px wide),
// antialiased analytically and MAX blended.
// ---------------------------------------------------------------------------

struct LineOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) @interpolate(flat) p0: vec2<f32>, // target pixels
    @location(1) @interpolate(flat) p1: vec2<f32>,
    @location(2) @interpolate(flat) k: f32,
    @location(3) @interpolate(flat) tint: f32, // 0 green, 1 teal
    @location(4) @interpolate(flat) width: f32, // core width, px
};


fn line_quad(vi: u32, a: vec2<f32>, b: vec2<f32>, da: f32, db: f32, k: f32, tint: f32, width: f32) -> LineOut {
    var out: LineOut;
    // Exact endpoints: snapping them to pixel centres kinks the joints
    // between segments.
    let p0 = a;
    let p1 = b;
    var dir = p1 - p0;
    let len = length(dir);
    if len < 1e-4 {
        dir = vec2<f32>(1.0, 0.0);
    } else {
        dir = dir / len;
    }
    let normal = vec2<f32>(-dir.y, dir.x);
    let at_end = (vi >> 1u) == 1u;
    // Covers the core, the halo and its 1 px falloff, plus a pixel spare.
    let half_width = 0.5 * width + HALO + 1.5;
    let side = select(-half_width, half_width, (vi & 1u) == 1u);
    let along = select(-half_width, half_width, at_end);
    out.pos = to_clip(select(p0, p1, at_end) + dir * along + normal * side, select(da, db, at_end));
    out.p0 = p0 - g.offset;
    out.p1 = p1 - g.offset;
    out.k = k;
    out.tint = tint;
    out.width = width;
    return out;
}

// The point of the segment nearest this pixel.
fn line_centre(in: LineOut) -> vec2<f32> {
    let seg = in.p1 - in.p0;
    let len2 = dot(seg, seg);
    var t = 0.0;
    if len2 > 0.0 {
        t = clamp(dot(in.pos.xy - in.p0, seg) / len2, 0.0, 1.0);
    }
    return in.p0 + seg * t;
}

// The globe's line model: a core at twice the intensity, which saturates to
// near-white, and a 0.3 halo a pixel wider. Each is saturated first and
// then scaled by its coverage (a 1 px smoothstep at its edge), so the edge
// fades evenly instead of clipping to a stair-step.
fn shade_line(in: LineOut, d: f32, k: f32) -> vec4<f32> {
    let colour = mix(GREEN, TEAL, in.tint);
    let core_extent = 0.5 * in.width;
    let core = min(BG + colour * 2.0 * k, vec3<f32>(1.0)) - BG;
    let halo = colour * 0.3 * k;
    let lit = max(core * coverage(d, core_extent), halo * coverage(d, core_extent + HALO));
    return vec4<f32>(BG + lit, 1.0);
}

@fragment
fn fs_line(in: LineOut) -> @location(0) vec4<f32> {
    let centre = line_centre(in);
    let d = distance(in.pos.xy, centre);
    // Hidden-line test: the orbiter's surfaces' depth where the line's
    // centre is, not under this pixel, so a line's whole width is shown or
    // hidden together; the surface's own silhouette, one sample per pixel,
    // would otherwise cut into the lines along it, and crawl as it moves.
    // Filtered over the 4x4 texels around it (a tent RADIUS px wide), so
    // the change is smooth: over 2x2 texels, a line along the edge of a
    // thin surface (the fin's tip, the OMS pods), a pixel behind it, still
    // flickered on and off with the edge's stair-step.
    let texel = centre - 0.5;
    let size = vec2<i32>(textureDimensions(hull_depth)) - 1;
    let base = vec2<i32>(floor(texel)) - 1;
    var shown = 0.0;
    var total = 0.0;
    for (var i = 0; i < 16; i++) {
        let o = vec2<i32>(i & 3, i >> 2);
        let hull = textureLoad(hull_depth, clamp(base + o, vec2<i32>(0), size), 0);
        let r = abs(vec2<f32>(base + o) - texel) / RADIUS;
        let w = max(1.0 - r.x, 0.0) * max(1.0 - r.y, 0.0);
        total += w;
        shown += w * select(0.0, 1.0, in.pos.z <= hull);
    }
    shown /= total;
    return shade_line(in, d, in.k * mix(g.hidden, 1.0, shown));
}

// Half-width of the hidden-line test's filter, px.
const RADIUS: f32 = 2.0;

// Halo width beyond the core, px.
const HALO: f32 = 1.0;

// How much of a pixel at distance `d` from a line's centre lies within
// `extent` of it: 1 inside, 0 outside, a 1 px smoothstep across the edge.
fn coverage(d: f32, extent: f32) -> f32 {
    return 1.0 - smoothstep(extent - 0.5, extent + 0.5, d);
}

// Orbiter edges: model-space endpoints (a.xyz, n1), (b.xyz, n0). n0 = 0 is
// a crease or open boundary, always drawn. Otherwise it's an outline
// candidate, drawn only while one face turns toward the camera and the
// other away: its two faces' normals, 12-bit octahedral, n0 = 1 + (x0 | y0
// << 12) and n1 = x1 | y1 << 12 (see tools/orbiter_edges.py).

fn view_of(p: vec3<f32>) -> vec3<f32> {
    return vec3<f32>(
        dot(g.m0.xyz, p) + g.m0.w,
        dot(g.m1.xyz, p) + g.m1.w,
        dot(g.m2.xyz, p) + g.m2.w,
    );
}

fn rotate(n: vec3<f32>) -> vec3<f32> {
    return vec3<f32>(dot(g.m0.xyz, n), dot(g.m1.xyz, n), dot(g.m2.xyz, n));
}

fn oct_decode(bits: u32) -> vec3<f32> {
    let e = vec2<f32>(f32(bits & 4095u), f32((bits >> 12u) & 4095u)) / 4095.0 * 2.0 - 1.0;
    var n = vec3<f32>(e, 1.0 - abs(e.x) - abs(e.y));
    if n.z < 0.0 {
        let s = select(vec2<f32>(-1.0), vec2<f32>(1.0), n.xy >= vec2<f32>(0.0));
        n = vec3<f32>((1.0 - abs(n.yx)) * s, n.z);
    }
    return normalize(n);
}

// How much of the edge a-b with these normals is drawn in the current pose,
// 0..1.
const OUTLINE_SLACK: f32 = 0.04;
const OUTLINE_SLACK_MIN: f32 = 0.004;
fn edge_shown(a: vec3<f32>, b: vec3<f32>, n0: f32, n1: f32) -> f32 {
    if n0 < 0.5 {
        return 1.0;
    }
    let to_eye = normalize(-view_of(0.5 * (a + b)));
    let f0 = dot(rotate(oct_decode(u32(n0) - 1u)), to_eye);
    let f1 = dot(rotate(oct_decode(u32(n1))), to_eye);
    // Fully on the outline while one face turns toward the camera and the
    // other away, fading out as both turn the same way by the slack: a hard
    // cut-off pops whole segments on and off, and hands the outline from
    // one edge to the next with a jump. The slack is half the angle between
    // the faces, up to OUTLINE_SLACK: on a nearly flat surface (the aft
    // belly, a degree or less per facet), a fixed one would light a dozen
    // neighbouring edges at once, streaks along the outline.
    let slack = clamp(0.5 * abs(f0 - f1), OUTLINE_SLACK_MIN, OUTLINE_SLACK);
    return saturate(1.0 - min(f0, f1) / slack) * saturate(1.0 + max(f0, f1) / slack);
}

// xy = output pixel, z = depth (0 near .. 1 far)
fn project_model(p: vec3<f32>) -> vec3<f32> {
    let v = view_of(p);
    let z = -v.z;
    let pixel = g.proj.yz + g.proj.x * vec2<f32>(v.x, -v.y) / z;
    let depth = (g.depth.x - 1.0 / z) / g.depth.y;
    return vec3<f32>(pixel, depth);
}

fn orbiter_edge(vi: u32, a: vec4<f32>, b: vec4<f32>) -> LineOut {
    let shown = edge_shown(a.xyz, b.xyz, b.w, a.w);
    if shown <= 0.0 {
        var out: LineOut;
        out.pos = CLIPPED;
        return out;
    }
    let pa = project_model(a.xyz);
    let pb = project_model(b.xyz);
    let bias = g.depth.z;
    return line_quad(vi, pa.xy, pb.xy, pa.z - bias, pb.z - bias, shown, 0.0, g.proj.w);
}

@vertex
fn vs_shuttle(@builtin(vertex_index) vi: u32, @location(0) a: vec4<f32>, @location(1) b: vec4<f32>) -> LineOut {
    return orbiter_edge(vi, a, b);
}

// Depth-only pass of the orbiter's surfaces (triangle list, xyz + 1).
@vertex
fn vs_mesh(@location(0) p: vec4<f32>) -> @builtin(position) vec4<f32> {
    let q = project_model(p.xyz);
    return to_clip(q.xy, q.z);
}

@fragment
fn fs_mesh() -> @location(0) vec4<f32> {
    return vec4<f32>(BG, 1.0);
}

// ---------------------------------------------------------------------------
// The Earth: a big sphere below the screen, orthographic like the globe.
// ---------------------------------------------------------------------------

// xy = output pixel, z = 1 when on the near hemisphere
fn project_earth(lon_lat: vec2<f32>) -> vec3<f32> {
    let c = cos(lon_lat.y);
    let p = vec3<f32>(c * cos(lon_lat.x), c * sin(lon_lat.x), sin(lon_lat.y));
    let v = vec3<f32>(dot(g.er0.xyz, p), dot(g.er1.xyz, p), dot(g.er2.xyz, p));
    return vec3<f32>(g.earth.x + v.y * g.earth.z, g.earth.y - v.z * g.earth.z, select(0.0, 1.0, v.x > 0.0));
}

// Lat/lon grid dots, generated from the instance index: 11 parallels
// (every 15 degrees) and 24 half-meridians, one dot every 0.1 degree.
const GRID_STEP: f32 = 0.0017453293; // 0.1 degree
const PARALLELS: u32 = 11u;
const PARALLEL_DOTS: u32 = 3600u;
const MERIDIAN_DOTS: u32 = 1800u;

struct DotOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) colour: vec3<f32>,
};

@vertex
fn vs_earth_grid(@builtin(vertex_index) vi: u32, @builtin(instance_index) ii: u32) -> DotOut {
    var out: DotOut;
    var lon_lat: vec2<f32>;
    let parallel_count = PARALLELS * PARALLEL_DOTS;
    if ii < parallel_count {
        let line = ii / PARALLEL_DOTS;
        lon_lat = vec2<f32>(f32(ii % PARALLEL_DOTS) * GRID_STEP, radians(-75.0 + 15.0 * f32(line)));
    } else {
        let j = ii - parallel_count;
        let line = j / MERIDIAN_DOTS;
        lon_lat = vec2<f32>(radians(15.0 * f32(line)), -1.5707963 + (f32(j % MERIDIAN_DOTS) + 0.5) * GRID_STEP);
    }
    let p = project_earth(lon_lat);
    if p.z < 0.5 {
        out.pos = CLIPPED;
        return out;
    }
    let corner = vec2<f32>(f32(vi & 1u), f32(vi >> 1u));
    out.pos = to_clip(floor(p.xy) + corner, 1.0);
    out.colour = BG + TEAL * 0.3;
    return out;
}

@fragment
fn fs_dot(in: DotOut) -> @location(0) vec4<f32> {
    return vec4<f32>(in.colour, 1.0);
}

// Coastlines (Natural Earth 50m): a segment per instance, its ends on the
// unit sphere (a.xyz, b.xyz), drawn as lines like the orbiter's but thinner
// and dimmer, at depth 1 so the orbiter masks them. Only segments wholly on
// the near hemisphere, fading out toward the limb, where they crowd
// together edge-on.
const COAST_K: f32 = 0.45;
const COAST_WIDTH: f32 = 0.5;      // of the orbiter's line width
const COAST_LIMB_FADE: f32 = 0.2;  // cos of the view angle they fade in over

fn earth_view(p: vec3<f32>) -> vec3<f32> {
    return vec3<f32>(dot(g.er0.xyz, p), dot(g.er1.xyz, p), dot(g.er2.xyz, p));
}

@vertex
fn vs_coast(@builtin(vertex_index) vi: u32, @location(0) a: vec4<f32>, @location(1) b: vec4<f32>) -> LineOut {
    let va = earth_view(a.xyz);
    let vb = earth_view(b.xyz);
    let facing = min(va.x, vb.x);
    let pa = g.earth.xy + vec2<f32>(va.y, -va.z) * g.earth.z;
    let pb = g.earth.xy + vec2<f32>(vb.y, -vb.z) * g.earth.z;
    let margin = 8.0;
    let lo = min(pa, pb);
    let hi = max(pa, pb);
    if facing <= 0.0 || any(hi < vec2<f32>(-margin)) || any(lo > g.output + margin) {
        var out: LineOut;
        out.pos = CLIPPED;
        return out;
    }
    let k = COAST_K * smoothstep(0.0, COAST_LIMB_FADE, facing);
    return line_quad(vi, pa, pb, 1.0, 1.0, k, 0.0, COAST_WIDTH * g.proj.w);
}

@fragment
fn fs_coast(in: LineOut) -> @location(0) vec4<f32> {
    return shade_line(in, distance(in.pos.xy, line_centre(in)), in.k);
}

// The limb: a crisp teal line with a thin atmosphere glow above it, drawn
// as a band (triangle strip) along the part of the circle that's on screen.
const ATMO_SEGMENTS: u32 = 512u;
const ATMO_OUTER: f32 = 36.0;
const ATMO_INNER: f32 = 160.0;

struct AtmoOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) @interpolate(flat) centre: vec2<f32>, // target pixels
};

@vertex
fn vs_atmosphere(@builtin(vertex_index) vi: u32) -> AtmoOut {
    var out: AtmoOut;
    let r = g.earth.z;
    let reach = max(g.earth.x, g.output.x - g.earth.x) + ATMO_OUTER;
    let half_span = asin(clamp(reach / r, 0.0, 1.0));
    let k = f32(vi >> 1u) / f32(ATMO_SEGMENTS);
    let phi = -1.5707963 + half_span * (2.0 * k - 1.0);
    let radius = select(r - ATMO_INNER, r + ATMO_OUTER, (vi & 1u) == 1u);
    // The chord between samples cuts inside the circle; push the outer edge
    // out a little so the band always covers the glow.
    let pixel = g.earth.xy + radius * vec2<f32>(cos(phi), sin(phi)) / select(1.0, cos(half_span / f32(ATMO_SEGMENTS)), (vi & 1u) == 1u);
    out.pos = to_clip(pixel, 1.0);
    out.centre = g.earth.xy - g.offset;
    return out;
}

@fragment
fn fs_atmosphere(in: AtmoOut) -> @location(0) vec4<f32> {
    let d = distance(in.pos.xy, in.centre) - g.earth.z;
    // 1 px limb, saturating like a line core (saturated, then scaled by its
    // coverage so it doesn't stair-step), then glow falling off outward and
    // a faint rim and haze inside.
    let core = (min(BG + TEAL * 1.6, vec3<f32>(1.0)) - BG) * coverage(abs(d), 0.6);
    let glow = select(0.10 * exp(d / 2.5) + 0.035 * exp(d / 60.0), 0.42 * exp(-d / 7.0) + 0.06 * exp(-d / 22.0), d > 0.0);
    return vec4<f32>(min(BG + core + SAPPHIRE * glow, vec3<f32>(1.0)), 1.0);
}

// ---------------------------------------------------------------------------
// Stars: (x, y as 0..1 of the output, brightness, twinkle cycles per 1000 s),
// (phase, twinkle depth, big, colour). Additive.
// ---------------------------------------------------------------------------

struct StarOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) colour: vec3<f32>,
    @location(1) local: vec2<f32>,
    @location(2) @interpolate(flat) big: f32,
};

@vertex
fn vs_star(@builtin(vertex_index) vi: u32, @location(0) a: vec4<f32>, @location(1) b: vec4<f32>) -> StarOut {
    var out: StarOut;
    let pixel = floor(a.xy * g.output);
    if distance(pixel, g.earth.xy) < g.earth.z + 4.0 {
        out.pos = CLIPPED;
        return out;
    }
    // Whole cycles per 1000 s, so the wrap of `time` is seamless.
    let twinkle = 0.5 + 0.5 * sin(TAU * a.w * g.time / 1000.0 + b.x);
    let k = a.z * (1.0 - b.y * twinkle);
    var colour = TEXT;
    if b.w > 2.5 {
        colour = ROSEWATER;
    } else if b.w > 1.5 {
        colour = SAPPHIRE;
    } else if b.w > 0.5 {
        colour = LAVENDER;
    }
    let size = select(1.0, 3.0, b.z > 0.5);
    let corner = vec2<f32>(f32(vi & 1u), f32(vi >> 1u)) * size;
    out.pos = to_clip(pixel - floor(size / 2.0) + corner, 1.0);
    out.colour = colour * k;
    out.local = corner;
    out.big = b.z;
    return out;
}

@fragment
fn fs_star(in: StarOut) -> @location(0) vec4<f32> {
    var k = 1.0;
    if in.big > 0.5 {
        // A glow pixel like the globe's: full centre, 0.3 on its 4-neighbours.
        let cell = floor(in.local);
        let off = abs(cell - vec2<f32>(1.0, 1.0));
        k = select(select(0.0, 0.3, off.x + off.y < 1.5), 1.0, off.x + off.y < 0.5);
    }
    return vec4<f32>(in.colour * k, 1.0);
}
