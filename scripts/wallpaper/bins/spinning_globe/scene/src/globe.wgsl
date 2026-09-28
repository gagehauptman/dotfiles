// GPU version of the old CPU renderer: the lat/lon grid, continent outlines
// and globe outline are uploaded once as instance buffers and projected here.
// Screen coordinates are pixels with (0, 0) at the top-left, like the old
// canvas, so the maths below mirrors project_point() one to one.

struct Globals {
    viewport: vec2<f32>,
    center: vec2<f32>,
    radius: f32,
    rotation: f32,
    _pad: vec2<f32>,
};

@group(0) @binding(0) var<uniform> globals: Globals;

// Catppuccin Mocha colors, same as the old CPU constants
const BG: vec3<f32> = vec3<f32>(30.0, 30.0, 46.0) / 255.0;      // Base #1e1e2e
const GREEN: vec3<f32> = vec3<f32>(166.0, 227.0, 161.0) / 255.0; // Green #a6e3a1
const TEAL: vec3<f32> = vec3<f32>(148.0, 226.0, 213.0) / 255.0;  // Teal #94e2d5

// Position that is always clipped away, used to drop back-side geometry.
const CLIPPED: vec4<f32> = vec4<f32>(0.0, 0.0, 2.0, 1.0);

// Same projection as project_point(): xy = screen pixel, z = 1.0 when the
// point is on the visible hemisphere.
fn project(lon_lat: vec2<f32>) -> vec3<f32> {
    let lon = lon_lat.x + globals.rotation;
    let lat = lon_lat.y;
    let x = cos(lat) * cos(lon);
    let y = cos(lat) * sin(lon);
    let z = sin(lat);
    return vec3<f32>(
        globals.center.x + y * globals.radius,
        globals.center.y - z * globals.radius,
        select(0.0, 1.0, x > 0.0),
    );
}

fn to_clip(pixel: vec2<f32>) -> vec4<f32> {
    let ndc = vec2<f32>(
        pixel.x / globals.viewport.x * 2.0 - 1.0,
        1.0 - pixel.y / globals.viewport.y * 2.0,
    );
    return vec4<f32>(ndc, 0.0, 1.0);
}

// ---------------------------------------------------------------------------
// Points: grid dots and the globe outline, one 1x1 pixel quad per instance,
// drawn as a 4-vertex triangle strip. Additive blending reproduces
// draw_glow_pixel().
// ---------------------------------------------------------------------------

struct PointIn {
    @location(0) lon_lat: vec2<f32>, // radians; for the outline .x is the screen angle
    @location(1) intensity: f32,
    @location(2) kind: f32,          // 0 = point on the globe, 1 = outline
};

struct PointOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) color: vec3<f32>,
};

@vertex
fn vs_point(@builtin(vertex_index) vi: u32, in: PointIn) -> PointOut {
    var out: PointOut;
    var pixel: vec2<f32>;

    if in.kind > 0.5 {
        // Globe outline: a fixed circle in screen space, no rotation.
        pixel = globals.center + globals.radius * vec2<f32>(cos(in.lon_lat.x), sin(in.lon_lat.x));
    } else {
        let p = project(in.lon_lat);
        if p.z < 0.5 {
            out.pos = CLIPPED;
            return out;
        }
        pixel = p.xy;
    }

    // floor() matches the old `sx as i32` truncation for on-screen pixels;
    // the quad from floor(p) to floor(p) + 1 covers exactly one pixel centre.
    let corner = vec2<f32>(f32(vi & 1u), f32(vi >> 1u));
    out.pos = to_clip(floor(pixel) + corner);
    out.color = TEAL * in.intensity;
    return out;
}

@fragment
fn fs_point(in: PointOut) -> @location(0) vec4<f32> {
    return vec4<f32>(in.color, 1.0);
}

// ---------------------------------------------------------------------------
// Lines: continent outline sub-segments, one quad per instance, expanded in
// the vertex shader and shaded by distance to the segment in the fragment
// shader. Uses MAX blending so heavily overlapping sub-segments don't
// accumulate, which mirrors what the old Bresenham+glow pass looked like.
// ---------------------------------------------------------------------------

struct LineIn {
    @location(0) a: vec2<f32>, // lon/lat radians
    @location(1) b: vec2<f32>,
};

struct LineOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) @interpolate(flat) p0: vec2<f32>,
    @location(1) @interpolate(flat) p1: vec2<f32>,
    // Distance between consecutive samples on this edge, in pixels
    @location(2) @interpolate(flat) spacing: f32,
};

// Half-width of the quad: 1px core + 1px halo + a little margin.
const LINE_HALF_WIDTH: f32 = 2.0;

@vertex
fn vs_line(@builtin(vertex_index) vi: u32, in: LineIn) -> LineOut {
    var out: LineOut;

    let pa = project(in.a);
    let pb = project(in.b);
    // The CPU version only drew a segment when both ends were visible.
    if pa.z < 0.5 || pb.z < 0.5 {
        out.pos = CLIPPED;
        return out;
    }

    // Snap to pixel centres like the old integer Bresenham endpoints.
    let p0 = floor(pa.xy) + 0.5;
    let p1 = floor(pb.xy) + 0.5;

    var dir = p1 - p0;
    let len = length(dir);
    if len < 1e-4 {
        dir = vec2<f32>(1.0, 0.0);
    } else {
        dir = dir / len;
    }
    let normal = vec2<f32>(-dir.y, dir.x);

    let at_end = (vi >> 1u) == 1u;
    let side = select(-LINE_HALF_WIDTH, LINE_HALF_WIDTH, (vi & 1u) == 1u);
    let along = select(-LINE_HALF_WIDTH, LINE_HALF_WIDTH, at_end);
    let base = select(p0, p1, at_end);

    out.pos = to_clip(base + dir * along + normal * side);
    out.p0 = p0;
    out.p1 = p1;
    out.spacing = distance(pa.xy, pb.xy);
    return out;
}

@fragment
fn fs_line(in: LineOut) -> @location(0) vec4<f32> {
    let p = in.pos.xy; // this fragment's pixel centre
    let seg = in.p1 - in.p0;
    let len2 = dot(seg, seg);
    var t = 0.0;
    var dir = vec2<f32>(1.0, 0.0);
    if len2 > 0.0 {
        t = clamp(dot(p - in.p0, seg) / len2, 0.0, 1.0);
        dir = abs(seg) / sqrt(len2);
    }
    let d = distance(p, in.p0 + seg * t);
    let major = max(dir.x, dir.y);

    // Model of the old rasteriser. Each edge was sampled every `spacing`
    // pixels and Bresenham lines drawn between the samples, so a line pixel
    // was hit about (1 + samples inside it) times at full intensity and its
    // 4-neighbours got 0.3 per hit. Densely sampled edges therefore had a
    // halo bright enough to saturate; sparse ones a faint one.
    let samples_per_pixel = 1.0 / (major * max(in.spacing, 1e-3));
    let hits = 1.0 + samples_per_pixel;

    // Pixels covered by the line: an 8-connected Bresenham line when the
    // samples are sparse, every pixel the ideal line crosses (4-connected)
    // when they are dense.
    let extent8 = 0.5 * major;
    let extent4 = 0.5 * (dir.x + dir.y);
    let core_extent = mix(extent8, extent4, clamp(samples_per_pixel, 0.0, 1.0));
    // The halo is the 4-neighbourhood of those pixels; on diagonals a halo
    // pixel touches two line pixels, on axis-aligned runs only one.
    let halo_extent = core_extent + major;
    let neighbours = 1.0 + min(dir.x, dir.y) / major;

    // Line pixels always saturate (hits >= 1 plus glow from their neighbours).
    let core = 2.0 * (1.0 - step(core_extent, d));
    let halo = 0.3 * hits * neighbours * (1.0 - step(halo_extent, d));
    let intensity = max(core, halo);

    return vec4<f32>(BG + GREEN * intensity, 1.0);
}
