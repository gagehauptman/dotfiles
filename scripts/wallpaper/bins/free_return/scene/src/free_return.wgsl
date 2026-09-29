// The free-return wallpaper: the Earth-Moon rotating frame as a vector
// display. Same look as the globe (globe.wgsl) and the shuttle
// (shuttle.wgsl): lines whose core saturates to near-white with a faint
// halo, faint single-pixel dots, Catppuccin Mocha on Base, 8-bit non-sRGB
// target.
//
// Screen coordinates are output pixels, (0, 0) top-left; `offset` shifts
// them into the render target (a centre crop for the selector preview).
// Frame coordinates are the CR3BP's: barycentre at the origin, Earth-Moon
// distance 1, y up; `frame` maps them to pixels.

struct Globals {
    viewport: vec2<f32>,
    offset: vec2<f32>,
    output: vec2<f32>,
    time: f32,          // twinkle clock, 0..1000 s, wrapping seamlessly
    met: f32,           // mission elapsed time, hours from TLI
    frame: vec4<f32>,   // barycentre x, y (output px), px per unit, line width px
    craft: vec4<f32>,   // spacecraft x, y (output px), brightness, flown path brightness
    bodies: vec4<f32>,  // Earth radius px, Moon radius px, px per glyph unit, 0
};

@group(0) @binding(0) var<uniform> g: Globals;

// Catppuccin Mocha
const BG: vec3<f32> = vec3<f32>(30.0, 30.0, 46.0) / 255.0;          // Base
const GREEN: vec3<f32> = vec3<f32>(166.0, 227.0, 161.0) / 255.0;    // Green
const TEAL: vec3<f32> = vec3<f32>(148.0, 226.0, 213.0) / 255.0;     // Teal
const SAPPHIRE: vec3<f32> = vec3<f32>(116.0, 199.0, 236.0) / 255.0; // Sapphire
const TEXT: vec3<f32> = vec3<f32>(205.0, 214.0, 244.0) / 255.0;     // Text
const LAVENDER: vec3<f32> = vec3<f32>(180.0, 190.0, 254.0) / 255.0; // Lavender
const ROSEWATER: vec3<f32> = vec3<f32>(245.0, 224.0, 220.0) / 255.0; // Rosewater
const PEACH: vec3<f32> = vec3<f32>(250.0, 179.0, 135.0) / 255.0;    // Peach

const TAU: f32 = 6.283185307;
const MU: f32 = 0.012150585;
const CLIPPED: vec4<f32> = vec4<f32>(0.0, 0.0, 2.0, 1.0);

fn to_clip(pixel: vec2<f32>) -> vec4<f32> {
    let p = pixel - g.offset;
    return vec4<f32>(p.x / g.viewport.x * 2.0 - 1.0, 1.0 - p.y / g.viewport.y * 2.0, 0.0, 1.0);
}

// Frame units to output pixels.
fn to_pixel(p: vec2<f32>) -> vec2<f32> {
    return g.frame.xy + g.frame.z * vec2<f32>(p.x, -p.y);
}

// ---------------------------------------------------------------------------
// Lines: one quad per segment, shaded by distance like the globe's
// continents (a saturating core and a 0.3 halo), antialiased analytically
// and MAX blended.
// ---------------------------------------------------------------------------

struct LineOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) @interpolate(flat) p0: vec2<f32>, // target pixels
    @location(1) @interpolate(flat) p1: vec2<f32>,
    @location(2) @interpolate(flat) k: f32,
    @location(3) @interpolate(flat) colour: vec3<f32>,
    @location(4) @interpolate(flat) width: f32, // core width, px
};

// Halo width beyond the core, px.
const HALO: f32 = 1.0;

fn line_quad(vi: u32, a: vec2<f32>, b: vec2<f32>, k: f32, colour: vec3<f32>, width: f32) -> LineOut {
    var out: LineOut;
    var dir = b - a;
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
    out.pos = to_clip(select(a, b, at_end) + dir * along + normal * side);
    out.p0 = a - g.offset;
    out.p1 = b - g.offset;
    out.k = k;
    out.colour = colour;
    out.width = width;
    return out;
}

fn clipped_line() -> LineOut {
    var out: LineOut;
    out.pos = CLIPPED;
    return out;
}

// How much of a pixel at distance `d` from a line's centre lies within
// `extent` of it: 1 inside, 0 outside, a 1 px smoothstep across the edge.
fn coverage(d: f32, extent: f32) -> f32 {
    return 1.0 - smoothstep(extent - 0.5, extent + 0.5, d);
}

@fragment
fn fs_line(in: LineOut) -> @location(0) vec4<f32> {
    let seg = in.p1 - in.p0;
    let len2 = dot(seg, seg);
    var t = 0.0;
    if len2 > 0.0 {
        t = clamp(dot(in.pos.xy - in.p0, seg) / len2, 0.0, 1.0);
    }
    let d = distance(in.pos.xy, in.p0 + seg * t);
    // The globe's line model: a core at twice the intensity, saturating
    // toward white, and a 0.3 halo a pixel wider, each scaled by its
    // coverage so the edges fade instead of stair-stepping.
    let core_extent = 0.5 * in.width;
    let core = min(BG + in.colour * 2.0 * in.k, vec3<f32>(1.0)) - BG;
    let halo = in.colour * 0.3 * in.k;
    let lit = max(core * coverage(d, core_extent), halo * coverage(d, core_extent + HALO));
    return vec4<f32>(BG + lit, 1.0);
}

// The trajectory: segments (a.xy, hours at a), (b.xy, hours at b) in frame
// units. The planned path is always there, faint; the flown one is drawn
// up to the spacecraft, its last day brightest, and fades at the loop's end.

const PLANNED_K: f32 = 0.16;
const FLOWN_K: f32 = 0.42;
const FRESH_K: f32 = 0.30;     // extra on the freshest part
const FRESH_HOURS: f32 = 20.0;

@vertex
fn vs_planned(@builtin(vertex_index) vi: u32, @location(0) a: vec4<f32>, @location(1) b: vec4<f32>) -> LineOut {
    return line_quad(vi, to_pixel(a.xy), to_pixel(b.xy), PLANNED_K, TEAL, 0.75 * g.frame.w);
}

@vertex
fn vs_flown(@builtin(vertex_index) vi: u32, @location(0) a: vec4<f32>, @location(1) b: vec4<f32>) -> LineOut {
    if a.z >= g.met || g.craft.w <= 0.0 {
        return clipped_line();
    }
    // The segment the spacecraft is on is drawn up to it.
    let f = clamp((g.met - a.z) / max(b.z - a.z, 1e-6), 0.0, 1.0);
    let end = mix(a.xy, b.xy, f);
    let age = g.met - mix(a.z, b.z, f);
    let fresh = FRESH_K * exp(-age / FRESH_HOURS) * g.craft.z;
    let k = (FLOWN_K + fresh) * g.craft.w;
    return line_quad(vi, to_pixel(a.xy), to_pixel(end), k, GREEN, g.frame.w);
}

// Marks: strokes (x, y frame units, x0, y0 glyph units), (x1, y1, k, 0),
// sized in pixels whatever the frame's scale.
@vertex
fn vs_mark(@builtin(vertex_index) vi: u32, @location(0) a: vec4<f32>, @location(1) b: vec4<f32>) -> LineOut {
    let at = floor(to_pixel(a.xy)) + 0.5;
    let unit = g.bodies.z;
    return line_quad(vi, at + a.zw * unit, at + b.xy * unit, b.z, LAVENDER, max(0.6 * g.frame.w, 1.0));
}

// ---------------------------------------------------------------------------
// Dots: (x, y frame units, intensity, style): single pixels, or 3x3 glow
// dots like the globe's (full centre, 0.3 on the 4-neighbours) for style
// >= 4. Colour by style % 4: teal, sapphire, lavender, text.
// ---------------------------------------------------------------------------

struct DotOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) colour: vec3<f32>,
    @location(1) local: vec2<f32>,
    @location(2) @interpolate(flat) big: f32,
};

fn palette(i: u32) -> vec3<f32> {
    switch i {
        case 0u: { return TEAL; }
        case 1u: { return SAPPHIRE; }
        case 2u: { return LAVENDER; }
        default: { return TEXT; }
    }
}

@vertex
fn vs_dot(@builtin(vertex_index) vi: u32, @location(0) d: vec4<f32>) -> DotOut {
    var out: DotOut;
    let style = u32(d.w);
    let size = select(1.0, 3.0, style >= 4u);
    let corner = vec2<f32>(f32(vi & 1u), f32(vi >> 1u)) * size;
    out.pos = to_clip(floor(to_pixel(d.xy)) - floor(size / 2.0) + corner);
    out.colour = palette(style % 4u) * d.z;
    out.local = corner;
    out.big = select(0.0, 1.0, style >= 4u);
    return out;
}

// A glow pixel like the globe's: full centre, 0.3 on its 4-neighbours.
fn glow(local: vec2<f32>, big: f32) -> f32 {
    if big < 0.5 {
        return 1.0;
    }
    let off = abs(floor(local) - vec2<f32>(1.0, 1.0));
    return select(select(0.0, 0.3, off.x + off.y < 1.5), 1.0, off.x + off.y < 0.5);
}

@fragment
fn fs_dot(in: DotOut) -> @location(0) vec4<f32> {
    return vec4<f32>(BG + in.colour * glow(in.local, in.big), 1.0);
}

// ---------------------------------------------------------------------------
// The Earth and the Moon, to scale: a crisp limb saturating like a line
// core, a thin glow outside (sapphire for the Earth's atmosphere, none to
// speak of for the Moon), and a faint fill.
// ---------------------------------------------------------------------------

struct BodyOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) @interpolate(flat) centre: vec2<f32>, // target pixels
    @location(1) @interpolate(flat) radius: f32,
    @location(2) @interpolate(flat) moon: f32,
};

const BODY_REACH: f32 = 14.0;

@vertex
fn vs_body(@builtin(vertex_index) vi: u32, @builtin(instance_index) ii: u32) -> BodyOut {
    var out: BodyOut;
    let moon = ii == 1u;
    let centre = to_pixel(vec2<f32>(select(-MU, 1.0 - MU, moon), 0.0));
    let radius = select(g.bodies.x, g.bodies.y, moon);
    let half = radius + BODY_REACH;
    let corner = vec2<f32>(f32(vi & 1u), f32(vi >> 1u)) * 2.0 - 1.0;
    out.pos = to_clip(centre + corner * half);
    out.centre = centre - g.offset;
    out.radius = radius;
    out.moon = select(0.0, 1.0, moon);
    return out;
}

@fragment
fn fs_body(in: BodyOut) -> @location(0) vec4<f32> {
    let d = distance(in.pos.xy, in.centre) - in.radius;
    let colour = select(TEAL, TEXT, in.moon > 0.5);
    let core = (min(BG + colour * 1.6, vec3<f32>(1.0)) - BG) * coverage(abs(d), 0.6);
    let fill = colour * select(0.10, 0.22, in.moon > 0.5) * coverage(d, 0.0);
    let glow = select(0.30 * exp(-d / 3.0) + 0.05 * exp(-d / 9.0), 0.10 * exp(-d / 2.0), in.moon > 0.5);
    let halo = SAPPHIRE * select(0.0, glow, d > 0.0);
    return vec4<f32>(min(BG + max(max(core, fill), halo), vec3<f32>(1.0)), 1.0);
}

// ---------------------------------------------------------------------------
// The spacecraft: a small warm point with a soft glow.
// ---------------------------------------------------------------------------

struct CraftOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) local: vec2<f32>, // px from the spacecraft
};

const CRAFT_REACH: f32 = 10.0;

@vertex
fn vs_craft(@builtin(vertex_index) vi: u32) -> CraftOut {
    var out: CraftOut;
    if g.craft.z <= 0.0 {
        out.pos = CLIPPED;
        return out;
    }
    let corner = (vec2<f32>(f32(vi & 1u), f32(vi >> 1u)) * 2.0 - 1.0) * CRAFT_REACH;
    out.pos = to_clip(g.craft.xy + corner);
    out.local = corner;
    return out;
}

@fragment
fn fs_craft(in: CraftOut) -> @location(0) vec4<f32> {
    let d = length(in.local);
    let core = (min(BG + ROSEWATER * 2.4, vec3<f32>(1.0)) - BG) * coverage(d, 1.4);
    let halo = PEACH * (0.45 * exp(-d / 1.8) + 0.08 * exp(-d / 5.0));
    return vec4<f32>(min(BG + max(core, halo) * g.craft.z, vec3<f32>(1.0)), 1.0);
}

// ---------------------------------------------------------------------------
// Stars: (x, y as 0..1 of the output, brightness, twinkle cycles per 1000 s),
// (phase, twinkle depth, big, colour). Additive, as the shuttle's.
// ---------------------------------------------------------------------------

@vertex
fn vs_star(@builtin(vertex_index) vi: u32, @location(0) a: vec4<f32>, @location(1) b: vec4<f32>) -> DotOut {
    var out: DotOut;
    let pixel = floor(a.xy * g.output);
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
    out.pos = to_clip(pixel - floor(size / 2.0) + corner);
    out.colour = colour * k;
    out.local = corner;
    out.big = b.z;
    return out;
}

@fragment
fn fs_star(in: DotOut) -> @location(0) vec4<f32> {
    return vec4<f32>(in.colour * glow(in.local, in.big), 1.0);
}
