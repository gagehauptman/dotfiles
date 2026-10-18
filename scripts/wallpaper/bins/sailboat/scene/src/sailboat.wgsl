// The sailboat wallpaper: a painted sloop alone on the Atlantic off Daytona,
// under the real sky and the real weather. Three passes (see lib.rs):
// fs_sky (half resolution, ~10 Hz): gradient, sun, moon, clouds; alpha = clouds' transmittance
// vs_boat/fs_boat: the sloop into a small box texture (MSAA, depth)
// fs_main: sea, wake, reflections, boat, stars, rain, lightning, gulls, grade
//
// World: metres, x east, y up, z south. Directions are unit vectors.

struct G {
    res: vec4f,
    cam_pos: vec4f,
    cam_right: vec4f,
    cam_up: vec4f,
    cam_fwd: vec4f,
    sky_right: vec4f,
    sky_up: vec4f,
    sky_fwd: vec4f,
    sun: vec4f,
    moon: vec4f,
    sun_col: vec4f,
    moon_col: vec4f,
    zenith: vec4f,
    horizon: vec4f,
    glow: vec4f,
    belt: vec4f,
    ambient: vec4f,
    water: vec4f,
    wx: vec4f,
    wx2: vec4f,
    wind: vec4f,
    cloud_off: vec4f,
    waves: array<vec4f, 6>,
    phase: array<vec4f, 2>,
    sharp: array<vec4f, 2>,
    ripple_off: vec4f,
    detail: array<vec4f, 12>,
    dphase: array<vec4f, 3>,
    boat_f: vec4f,
    boat_u: vec4f,
    boat_s: vec4f,
    boat_p: vec4f,
    sail: vec4f,
    sail2: vec4f,
    boat_box: vec4f,
    boat_misc: vec4f,
    cel: array<vec4f, 3>,
    lightning: vec4f,
    bolt: array<vec4f, 4>,
    birds: array<vec4f, 3>,
    nav: vec4f,
    grade: vec4f,
    misc: vec4f,
    cloud_light: vec4f,
    scale: vec4f,
    planets: array<vec4f, 5>,
};

@group(0) @binding(0) var<uniform> g: G;
@group(0) @binding(1) var sky_tex: texture_2d<f32>;
@group(0) @binding(2) var boat_tex: texture_2d<f32>;
@group(0) @binding(3) var samp: sampler;
@group(0) @binding(4) var scene_tex: texture_2d<f32>;
// The star catalogue's cube-map grid and records (stars.rs); bound by the composite pass only.
@group(0) @binding(5) var<storage, read> star_tab: array<vec4f>;
const STAR_GRID: i32 = 64;

const PI: f32 = 3.14159265;
const TAU: f32 = 6.2831853;

// --- Noise (value noise on a lattice that tiles every 64 cells) ----------------------

fn pcg(v: u32) -> u32 {
    let s = v * 747796405u + 2891336453u;
    let w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (w >> 22u) ^ w;
}
fn hash2(p: vec2i) -> f32 {
    return f32(pcg(u32(p.x) + pcg(u32(p.y) + 1013904223u))) * (1.0 / 4294967295.0);
}
fn hashp(p: vec2i) -> f32 {
    return hash2(p & vec2i(63));
}
fn hash1(n: f32) -> f32 {
    return f32(pcg(u32(i32(n)) + 77u)) * (1.0 / 4294967295.0);
}
fn vnoise(p: vec2f) -> f32 {
    let i = vec2i(floor(p));
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = hashp(i);
    let b = hashp(i + vec2i(1, 0));
    let c = hashp(i + vec2i(0, 1));
    let d = hashp(i + vec2i(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
// Value and gradient.
fn vnoised(p: vec2f) -> vec3f {
    let i = vec2i(floor(p));
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let du = 6.0 * f * (1.0 - f);
    let a = hashp(i);
    let b = hashp(i + vec2i(1, 0));
    let c = hashp(i + vec2i(0, 1));
    let d = hashp(i + vec2i(1, 1));
    let k = a - b - c + d;
    return vec3f(a + (b - a) * u.x + (c - a) * u.y + k * u.x * u.y,
                 du.x * ((b - a) + k * u.y),
                 du.y * ((c - a) + k * u.x));
}
fn fbm(p: vec2f, oct: i32) -> f32 {
    var s = 0.0;
    var a = 0.5;
    var q = p;
    for (var i = 0; i < oct; i++) {
        s += a * vnoise(q);
        q = q * 2.0 + vec2f(5.3, 1.7);
        a *= 0.5;
    }
    return s;
}

// --- Cameras ------------------------------------------------------------------------

fn cam_ray(px: vec2f) -> vec3f {
    let ndc = vec2f(px.x / g.res.x * 2.0 - 1.0, 1.0 - px.y / g.res.y * 2.0);
    let t = g.cam_pos.w;
    return normalize(g.cam_fwd.xyz + ndc.x * t * g.cam_right.w * g.cam_right.xyz + ndc.y * t * g.cam_up.xyz);
}
fn sky_ray(uv: vec2f) -> vec3f {
    let ndc = vec2f(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    let t = g.sky_right.w;
    return normalize(g.sky_fwd.xyz + ndc.x * t * g.sky_up.w * g.sky_right.xyz + ndc.y * t * g.sky_up.xyz);
}
fn sky_uv_raw(d: vec3f) -> vec2f {
    let z = max(dot(d, g.sky_fwd.xyz), 0.05);
    let t = g.sky_right.w;
    let x = dot(d, g.sky_right.xyz) / (z * t * g.sky_up.w);
    let y = dot(d, g.sky_up.xyz) / (z * t);
    return vec2f(x * 0.5 + 0.5, 0.5 - y * 0.5);
}
fn sky_uv(d: vec3f) -> vec2f {
    return clamp(sky_uv_raw(d), vec2f(0.0), vec2f(1.0));
}
fn sample_sky(d: vec3f) -> vec4f {
    return textureSampleLevel(sky_tex, samp, sky_uv(d), 0.0);
}
// For reflections, which also look above the texture's top edge: past it the
// sky fades to the zenith, mottled by the cloud cover.
fn sample_sky_refl(d: vec3f, p: vec2f) -> vec3f {
    let uv = sky_uv_raw(d);
    let t = textureSampleLevel(sky_tex, samp, clamp(uv, vec2f(0.0), vec2f(1.0)), 0.0).rgb;
    if uv.y >= 0.0 {
        return t;
    }
    let cover = clamp(g.wx.w * 1.1 + g.wx.y, 0.0, 1.0);
    let cp = d.xz / max(d.y, 0.05) * 0.9 + g.cloud_off.xy * 2.0;
    let blot = smoothstep(0.4, 0.6, vnoise(cp) + cover - 0.5);
    let cloud = g.ambient.rgb * 1.15 + g.cloud_light.rgb * g.cloud_light.w * 0.35;
    let up = mix(g.zenith.rgb, cloud, blot * cover);
    return mix(t, up, smoothstep(0.0, 0.25, -uv.y));
}

// --- Waves (lib.rs `wave_height` is the same) ---------------------------------------------

fn wave_phase(i: i32) -> f32 {
    return g.phase[i / 4][i % 4];
}
fn wave_sharp(i: i32) -> f32 {
    return g.sharp[i / 4][i % 4];
}
fn wave_h(p: vec2f) -> f32 {
    var h = 0.0;
    for (var i = 0; i < 6; i++) {
        let w = g.waves[i];
        let th = w.z * dot(w.xy, p) - wave_phase(i);
        let b = 0.5 * (sin(th) + 1.0);
        let k = wave_sharp(i) - 1.0;
        h += w.w * (2.0 * (b + k * (b * b - b)) - 1.0);
    }
    return h;
}

// --- The sea surface the boat floats on --------------------------------------------------
// One height field serves everyone: the CPU samples it (lib.rs `wave_height`) to heave, pitch
// and roll the boat, fs_boat cuts the hull at it (and hides what a nearer crest covers), and
// sea() ray-marches it near the boat so the water you see is the water the hull stands in.
// The boat's own wave system (bow wave, Kelvin arms, hollow alongside, transverse train astern)
// is part of the height, not a painted overlay. Far from the boat only the plain waves remain.

fn hull_sheer(t: f32) -> f32 {
    let s = t - 0.42;
    return 0.86 + 1.1 * s * s + 0.18 * t * t * t * t;
}
fn hull_draft(t: f32) -> f32 {
    let body = 0.62 * pow(max(sin(PI * t), 0.0), 0.7);
    let stern = select(0.0, 0.12 * (1.0 - t / 0.12), t < 0.12);
    return max(body + stern * 0.3, 0.05) - select(0.0, (t - 0.9) * 3.0, t > 0.9);
}
// Half-width of the hull at station t (0 transom .. 1 stem) and height y above the waterline
// (inverts the loft in boat.rs: z = b cos(a)^0.55, y = top - (top - bottom) sin(a)^1.6).
fn hull_hw(t: f32, y: f32) -> f32 {
    let top = hull_sheer(t);
    let bottom = -hull_draft(t);
    let q = clamp((top - y) / (top - bottom), 0.0, 1.0);
    let a = asin(pow(q, 0.625));
    return half_beam(t) * pow(max(cos(a), 0.0), 0.55);
}
fn to_local(w: vec3f) -> vec3f {
    let r = w - g.boat_p.xyz;
    return vec3f(dot(r, g.boat_f.xyz), dot(r, g.boat_u.xyz), dot(r, g.boat_s.xyz));
}

// Height the boat's passage adds to the sea at world (x, z), metres. Steady in the boat's frame.
fn hull_disp(p: vec2f) -> f32 {
    let rel = p - g.boat_p.xz;
    let hf = normalize(g.boat_f.xz + vec2f(1e-4, 0.0));
    let al = dot(rel, hf);
    let lat = dot(rel, vec2f(-hf.y, hf.x));
    if al < -26.0 || al > 9.0 || abs(lat) > 22.0 {
        return 0.0;
    }
    let spd = g.boat_p.w;
    let v = max(g.boat_s.w, 0.5);
    let windy = smoothstep(4.0, 28.0, g.wind.z);
    var t = (al + 4.8) / 10.0;
    var tc = clamp(t, 0.0, 1.0);
    var sd = abs(lat) - half_beam(tc) * 0.85;
    var ax = max(max(-4.8 - al, al - 5.2), 0.0);
    // Close in, measure from the hull's real section where it meets the water (it heels, pitches
    // and heaves), so the water climbing the topsides hugs the actual waterline.
    if abs(al) < 8.0 && abs(lat) < 5.0 {
        let hl = to_local(vec3f(p.x, near_w(p) * wave_h(p), p.y));
        let lt = clamp((hl.x + 4.8) / 10.0, 0.0, 1.0);
        sd = abs(hl.z) - hull_hw(lt, clamp(hl.y, -hull_draft(lt), hull_sheer(lt)));
        ax = max(max(-4.8 - hl.x, hl.x - 5.2), 0.0);
    }
    let dh = max(sd, 0.0);
    var h = 0.0;
    // Bow: a hump of water at the stem, shouldering aft along the forward topsides.
    let bq = al - 5.15;
    h += 0.4 * spd * exp(-(bq * bq) / 1.3 - lat * lat / 1.2);
    // Water climbing the hull along the whole waterline (a meniscus, more with way on and chop).
    h += (0.035 + 0.09 * spd + 0.05 * windy) * smoothstep(0.0, 0.1, t) * (1.0 - smoothstep(0.93, 1.03, t)) * exp(-dh * dh / 0.025) * smoothstep(-0.15, 0.0, sd) * (1.0 - smoothstep(0.0, 0.5, ax));
    h += 0.17 * spd * smoothstep(0.5, 0.97, t) * (1.0 - smoothstep(1.0, 1.1, t)) * exp(-dh * dh / 0.3);
    // Alongside amidships the water is drawn down, then climbs again at the quarter.
    h -= 0.07 * spd * smoothstep(0.08, 0.35, t) * (1.0 - smoothstep(0.5, 0.85, t)) * exp(-dh * dh / 1.4);
    h += 0.05 * spd * smoothstep(0.0, 0.2, t) * (1.0 - smoothstep(0.2, 0.5, t)) * exp(-dh * dh / 0.5);
    // Kelvin arms leaving the stem: ridges at about 19 degrees, fading and widening aft.
    let s = 5.2 - al;
    if s > 0.0 {
        let ac = abs(lat) - (0.25 + 0.36 * s);
        let aw = 0.3 + 0.07 * s;
        h += 0.13 * spd * exp(-ac * ac / (aw * aw)) * smoothstep(0.0, 1.2, s) * exp(-s / (7.0 + 22.0 * spd));
    }
    // Astern: a hollow behind the transom, then a transverse train (wavelength 2 pi v^2 / g).
    let behind = -(al + 4.8);
    if behind > -0.4 {
        let kt = 9.81 / (v * v);
        h -= 0.1 * spd * exp(-lat * lat / 2.2) * smoothstep(-0.4, 0.3, behind) * exp(-behind / 1.6);
        h += 0.085 * spd * cos(kt * (behind - 1.2)) * smoothstep(0.6, 2.5, behind) * exp(-behind / (9.0 + 20.0 * spd)) * exp(-lat * lat / (3.0 + 0.5 * behind));
    }
    // A slap that comes and goes at the waterline.
    let sn = vnoise(vec2f(al * 2.3 - g.res.z * 1.3, lat * 1.9 + g.res.z * 0.7)) - 0.5;
    h += sn * (0.03 + 0.12 * windy + 0.08 * spd) * exp(-(dh * dh + ax * ax) / 0.9);
    return h;
}

fn near_w(p: vec2f) -> f32 {
    return 1.0 - smoothstep(10.0, 28.0, length(p - g.boat_p.xz));
}
fn surf_h(p: vec2f) -> f32 {
    return near_w(p) * wave_h(p) + hull_disp(p);
}
// Upper bound of |surface| near the boat.
fn surf_hmax() -> f32 {
    var m = 0.55;
    for (var i = 0; i < 6; i++) {
        m += g.waves[i].w;
    }
    return m;
}

// First crossing of a camera ray with the surface near the boat: (x, z, height).
// Beyond the boat's neighbourhood this is the flat plane, and the two meet seamlessly
// because near_w fades the displacement to zero.
fn sea_hit(d: vec3f) -> vec3f {
    let cy = g.cam_pos.y;
    let nd = max(-d.y, 1e-4);
    let t_flat = cy / nd;
    let p0 = g.cam_pos.xz + d.xz * t_flat;
    let hm = surf_hmax();
    if t_flat > 200.0 || length(p0 - g.boat_p.xz) > 28.0 + hm * length(d.xz) / nd {
        return vec3f(p0, 0.0);
    }
    let t0 = max((cy - hm) / nd, 0.0);
    let t1 = (cy + hm) / nd;
    var ta = t0;
    var tb = t1;
    var prev = t0;
    for (var i = 1; i <= 10; i++) {
        let t = mix(t0, t1, f32(i) / 10.0);
        let q = g.cam_pos.xz + d.xz * t;
        if cy + d.y * t < surf_h(q) {
            ta = prev;
            tb = t;
            break;
        }
        prev = t;
    }
    for (var k = 0; k < 4; k++) {
        let tm = 0.5 * (ta + tb);
        let q = g.cam_pos.xz + d.xz * tm;
        if cy + d.y * tm < surf_h(q) {
            tb = tm;
        } else {
            ta = tm;
        }
    }
    let th = 0.5 * (ta + tb);
    let ph = g.cam_pos.xz + d.xz * th;
    return vec3f(ph, cy + d.y * th);
}

// --- Sky pass --------------------------------------------------------------------------

fn sky_base(d: vec3f) -> vec3f {
    let up = max(d.y, 0.0);
    var c = mix(g.horizon.rgb, g.zenith.rgb, smoothstep(0.0, 1.0, pow(up, 0.42)));
    let sh = normalize(vec3f(g.sun.x, 0.0, g.sun.z) + vec3f(1e-5, 0.0, 0.0));
    let dh = normalize(vec3f(d.x, 0.0, d.z) + vec3f(1e-5, 0.0, 0.0));
    let ca = dot(dh, sh);
    // Twilight glow along the horizon towards the sun.
    let glow_az = pow(max(ca * 0.5 + 0.5, 0.0), 3.0);
    c += g.glow.rgb * g.glow.w * glow_az * exp(-up * 6.0) * 0.85;
    c += g.glow.rgb * g.glow.w * glow_az * exp(-up * 22.0) * 0.4;
    c += g.glow.rgb * g.glow.w * pow(glow_az, 3.0) * exp(-up * 45.0) * 0.35;
    // Mie around the sun
    let cs = dot(d, g.sun.xyz);
    c += g.sun_col.rgb * (pow(max(cs, 0.0), 16.0) * 0.16 + pow(max(cs, 0.0), 600.0) * 0.6) * g.sun.w;
    // Belt of Venus over the earth's shadow, opposite the sun at twilight.
    let anti = pow(max(-ca * 0.5 + 0.5, 0.0), 2.0);
    let e = d.y * 57.3;
    let band = smoothstep(1.0, 5.0, e) * (1.0 - smoothstep(7.0, 18.0, e));
    let shadow = 1.0 - smoothstep(0.0, 4.0, e);
    c = mix(c, g.belt.rgb * 0.75, g.belt.w * anti * band * 0.5);
    c = mix(c, vec3f(0.16, 0.19, 0.32), g.belt.w * anti * shadow * 0.42);
    return c;
}

fn sun_disc(d: vec3f) -> vec4f {
    let r = 0.0105; // ~2.3x the real disc
    let q = 1.0 - dot(d, g.sun.xyz);
    let k = r * r * 0.5;
    let a = smoothstep(k * 1.15, k * 0.85, q) * g.sun.w;
    let low = 1.0 - smoothstep(0.0, 0.25, g.sun.y);
    let col = mix(vec3f(1.0, 0.97, 0.9) * 1.6, vec3f(1.0, 0.55, 0.28) * 1.4, low);
    return vec4f(col, a);
}

fn moon_disc(d: vec3f) -> vec4f {
    let m = g.moon.xyz;
    let r = 0.0145; // ~3x the real disc
    let facing = dot(d, m);
    if facing < 0.99 {
        return vec4f(0.0);
    }
    let mr = normalize(cross(m, vec3f(0.0, 1.0, 0.0)) + vec3f(0.0, 0.0, 1e-5));
    let mu = cross(mr, m);
    let q = vec2f(dot(d, mr), dot(d, mu)) / r;
    let r2 = dot(q, q);
    if r2 > 1.2 {
        return vec4f(0.0);
    }
    let n = q.x * mr + q.y * mu - sqrt(max(1.0 - r2, 0.0)) * m;
    let lit = dot(n, g.sun.xyz);
    let shade = smoothstep(-0.04, 0.16, lit);
    let maria = fbm(q * 2.3 + vec2f(3.1, 7.7), 4);
    let albedo = 0.86 - 0.42 * smoothstep(0.45, 0.62, maria) - 0.08 * vnoise(q * 9.0);
    let col = vec3f(1.0, 0.97, 0.9) * albedo * shade * 1.15 + vec3f(0.05, 0.06, 0.09) * albedo * (1.0 - shade);
    let a = smoothstep(1.0, 0.92, r2);
    return vec4f(col, a);
}

// Cloud colour from a lit amount (0 shadow .. 1 lit) and the light.
fn cloud_col(lit: f32, height: f32) -> vec3f {
    let night = g.water.w;
    let amb = g.ambient.rgb;
    let key = g.cloud_light.rgb * g.cloud_light.w + g.moon_col.rgb * g.moon_col.w * 0.9;
    let shadow = amb * vec3f(0.62, 0.58, 0.72) * (0.75 + 0.25 * height);
    let storm = g.wx.y;
    let lit_c = amb * 0.85 + key * 1.05;
    var c = mix(shadow, lit_c, lit);
    c = mix(c, c * vec3f(0.55, 0.58, 0.64), storm * (1.0 - lit * 0.5));
    return c * (1.0 + 0.1 * night);
}

// The towers' outline along the horizon at azimuth-plus-drift `ax`: rounded
// domes in cells (48 per 16 rad, so the drift wraps seamlessly).
fn tower_top(ax: f32, cov: f32, storm: f32) -> f32 {
    let cell = 16.0 / 48.0;
    let ci = floor(ax / cell);
    var top = 0.0;
    for (var k = -1; k <= 1; k++) {
        let c = ci + f32(k);
        let id = i32(c - floor(c / 48.0) * 48.0);
        let h1 = hash2(vec2i(id, 11));
        let h2 = hash2(vec2i(id, 23));
        let h3 = hash2(vec2i(id, 37));
        let h4 = hash2(vec2i(id, 51));
        if h4 > cov * 0.5 + 0.08 {
            continue;
        }
        let ac = (c + 0.5 + (h1 - 0.5) * 0.5) * cell;
        let w = cell * (0.45 + 0.55 * h2) * (1.0 + storm * 0.5);
        let hh = (0.04 + 0.2 * h3 * h3 + 0.07 * cov) * mix(1.0, 1.6, storm);
        let x = (ax - ac) / w;
        top = max(top, hh * pow(max(1.0 - x * x, 0.0), 0.6));
    }
    return top;
}

@vertex
fn vs_full(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4f {
    let uv = vec2f(f32((vi << 1u) & 2u), f32(vi & 2u));
    return vec4f(uv * 2.0 - 1.0, 0.0, 1.0);
}

// --- The Milky Way ---------------------------------------------------------------------
// Cheap lattice noise for the band (one integer round per corner; the sky pass only reruns a few times a second).
fn mwh(p: vec2i) -> f32 {
    var h = u32(p.x & 63) * 374761393u + u32(p.y & 63) * 668265263u + 1442695041u;
    h = (h ^ (h >> 15u)) * 2246822519u;
    h = (h ^ (h >> 13u)) * 3266489917u;
    h = h ^ (h >> 16u);
    return f32(h >> 8u) * (1.0 / 16777216.0);
}
fn mwn(p: vec2f) -> f32 {
    let i = vec2i(floor(p));
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    return mix(mix(mwh(i), mwh(i + vec2i(1, 0)), u.x), mix(mwh(i + vec2i(0, 1)), mwh(i + vec2i(1, 1)), u.x), u.y);
}
// Everything is a function of the CELESTIAL direction (so it turns with the stars and
// cannot shimmer): galactic longitude gl and latitude b, noise in polar coords
// q = dir(gl) * (K + Kb*b) (seamless around the circle, K cells/rad along the band,
// Kb across it). Octaves finer than the pixel footprint `pa` (rad per sky-texture px) fade out,
// so the look is the same at any resolution.
fn mw_fbm(q: vec2f, oct: i32, cells: f32, pa: f32) -> f32 {
    var s = 0.0;
    var a = 0.5;
    var p = q;
    var f = cells * pa; // noise cells per pixel
    for (var i = 0; i < oct; i++) {
        let w = 1.0 - smoothstep(0.22, 0.5, f);
        if w > 0.0 {
            s += a * mix(0.5, mwn(p), w);
        } else {
            s += a * 0.5;
        }
        p = p * 2.0 + vec2f(5.3, 1.7);
        a *= 0.5;
        f *= 2.0;
    }
    return s;
}

// Returns the band's emitted colour (additive, before the night/horizon factors).
fn milky_way(cc: vec3f, pa: f32) -> vec3f {
    let gp = vec3f(-0.8677, -0.1981, 0.4560);
    let gc = vec3f(-0.0549, -0.8734, -0.4838);
    let gy = cross(gp, gc);
    let b = dot(cc, gp);
    if abs(b) > 0.66 {
        return vec3f(0.0);
    }
    let cl = vec2f(dot(cc, gc), dot(cc, gy));
    let dir = cl / max(length(cl), 1e-4);
    let gl = atan2(cl.y, cl.x); // 0 = toward Sagittarius, +-pi = anticentre
    let al = abs(gl);

    // Centre line wanders (a few degrees) so the band is not a ruled stripe.
    let cen = (mwn(dir * 2.2 + vec2f(3.1, 7.7)) - 0.5) * 0.2 + 0.035 * sin(gl + 0.8);
    // Brightness along the plane: a broad core bulge, a dimmer disk that thins toward the
    // anticentre, a couple of star-cloud lumps (Cygnus, Carina).
    let bulge = exp(-gl * gl * 5.0);
    let lump = mwn(dir * 3.2 + vec2f(9.0, 2.0));
    let disk = mix(0.8, 0.26, smoothstep(0.3, 2.7, al)) * (0.75 + 0.5 * lump);
    let cyg = 0.2 * exp(-(gl - 1.35) * (gl - 1.35) * 9.0) + 0.14 * exp(-(gl + 1.15) * (gl + 1.15) * 7.0);
    let prof_l = disk + cyg + 0.7 * bulge;
    // Thickness: fat at the core, slimmer along the arms.
    let sig = 0.05 + 0.07 * bulge + 0.02 * lump;

    if abs(b - cen) > 6.5 * sig + 0.05 {
        return vec3f(0.0);
    }

    // Ragged, fractal edges: the latitude is pushed about by mid-scale noise.
    let qe = dir * (5.0 + 12.0 * b) + vec2f(2.0, 6.0);
    let edge = mw_fbm(qe, 3, 12.0, pa);
    let db = b - cen + (edge - 0.5) * 0.9 * sig;
    let x = db / sig;
    let prof = exp(-0.5 * x * x) * 0.8 + 0.18 * exp(-abs(x) * 0.5);
    let reach = 1.0 - smoothstep(0.3, 0.62, abs(b - cen));
    let dens = prof_l * prof * reach;
    if dens < 0.004 {
        return vec3f(0.0);
    }

    // Mottled star clouds: elongated along the band, domain-warped.
    let qm = dir * (10.0 + 34.0 * b);
    let wv = vec2f(mwn(qm * 0.5 + vec2f(1.0, 9.0)), mwn(qm * 0.5 + vec2f(6.0, 2.0)));
    let m = mw_fbm(qm + (wv - 0.5) * 2.2, 4, 34.0, pa);
    let fine = mw_fbm(dir * (22.0 + 60.0 * b) + vec2f(4.0, 8.0), 2, 60.0, pa);
    let core_w = smoothstep(0.08, 0.6, prof);
    var lum = dens * (1.0 + 0.2 * bulge) * mix(1.0, mix(0.55, 1.45, smoothstep(0.24, 0.76, m)), 0.35 + 0.65 * core_w) * (0.85 + 0.3 * fine);

    // Dust. The Great Rift splits the band lengthwise from the core out toward Cygnus,
    // in patches; dark nebula blotches and thin lanes cross everything.
    var dust = 0.0;
    if prof > 0.1 {
        let rw = smoothstep(-0.55, 0.1, gl) * (1.0 - smoothstep(1.4, 2.1, gl));
        let rd = db - (0.03 + 0.05 * bulge + 0.07 * (mwn(dir * 4.0 + vec2f(1.5, 8.2)) - 0.5));
        let rs = 0.026 + 0.03 * mwn(dir * 5.0 + vec2f(7.0, 3.0)) + 0.02 * bulge;
        let rpatch = 0.7 + 0.3 * smoothstep(0.3, 0.6, mw_fbm(dir * (9.0 + 30.0 * b) + vec2f(3.0, 1.0), 3, 30.0, pa));
        let rift = exp(-0.5 * rd * rd / (rs * rs)) * rw * rpatch * smoothstep(0.1, 0.4, prof);
        let qd = dir * (11.0 + 32.0 * b) + (wv - 0.5) * 3.0;
        let blot = smoothstep(0.46, 0.78, mw_fbm(qd + vec2f(8.0, 4.0), 4, 32.0, pa)) * core_w * mix(0.5, 1.0, smoothstep(-0.06, 0.05, db));
        let rl = 1.0 - abs(2.0 * mw_fbm(dir * (18.0 + 9.0 * b) + vec2f(2.0, 5.0), 3, 9.0, pa) - 1.0);
        let lanes = smoothstep(0.78, 0.95, rl) * core_w;
        dust = clamp(max(rift * 0.95, max(blot * 0.85, lanes * 0.4)), 0.0, 1.0);
    }
    lum *= 1.0 - 0.9 * dust;

    // Colour: warm cream in the core, cool blue-white along the arms, dust edges reddened,
    // faint pink emission hints.
    let wc = smoothstep(0.0, 0.8, bulge * (0.65 + 0.55 * m) * exp(-0.5 * x * x * 0.35));
    let cool = vec3f(0.55, 0.66, 1.0);
    let neutral = vec3f(0.95, 0.92, 0.92);
    let warm = vec3f(1.0, 0.82, 0.6);
    var col = mix(mix(cool, neutral, smoothstep(0.0, 0.45, wc)), warm, smoothstep(0.35, 0.95, wc));
    col *= mix(vec3f(1.0), vec3f(1.0, 0.72, 0.52), dust * 0.6);
    if prof > 0.2 {
        let pn = smoothstep(0.62, 0.82, mw_fbm(dir * (9.0 + 28.0 * b) + vec2f(5.0, 9.0), 3, 28.0, pa)) * smoothstep(0.1, 0.5, prof_l);
        col = mix(col, vec3f(1.0, 0.5, 0.62), pn * 0.4);
    }

    // A touch of paint: soft posterising of the glow, like the clouds.
    var v = lum * 3.2;
    v = mix(v, (floor(v * 5.0) + smoothstep(0.3, 0.7, fract(v * 5.0))) / 5.0, 0.2);
    return col * v * 0.1;
}

@fragment
fn fs_sky(@builtin(position) pos: vec4f) -> @location(0) vec4f {
    // The sky texture is half the output (lib.rs `sky_size`).
    let dims = ceil(g.res.xy * 0.5);
    let uv = pos.xy / dims;
    let d = sky_ray(uv);
    var dd = d;
    dd.y = max(dd.y, 0.0005);
    dd = normalize(dd);
    var col = sky_base(dd);
    var trans = 1.0;

    let night = g.water.w;
    // Sun and moon (behind every cloud).
    let sd = sun_disc(dd);
    col = mix(col, sd.rgb, sd.a);
    if g.moon.y > -0.05 {
        let md = moon_disc(dd);
        let day_moon = col + md.rgb * 0.35 * (1.0 - night);
        let night_moon = mix(col, md.rgb * (0.55 + 0.45 * night), md.a);
        col = mix(mix(col, day_moon, md.a), night_moon, night);
        // Halo
        let cm = max(dot(dd, g.moon.xyz), 0.0);
        // Halo: a bright painted bloom, a wide soft glow, a faint corona ring.
        let ang = acos(min(cm, 1.0));
        let ra = (ang - 0.065) / 0.012;
        let ring = exp(-ra * ra) * 0.025;
        let glow = pow(cm, 900.0) * 0.3 + pow(cm, 120.0) * 0.1 + pow(cm, 14.0) * 0.05 + ring;
        col += mix(vec3f(0.55, 0.62, 0.8), vec3f(0.8, 0.75, 0.62), pow(cm, 400.0)) * g.moon.w * night * glow * smoothstep(-0.02, 0.05, g.moon.y);
    }

    // The Milky Way (behind every cloud): see milky_way().
    if g.ambient.w > 0.005 {
        let cc = vec3f(dot(g.cel[0].xyz, dd), dot(g.cel[1].xyz, dd), dot(g.cel[2].xyz, dd));
        let pa = 2.0 * g.sky_right.w / dims.y;
        col += milky_way(cc, pa) * g.ambient.w * smoothstep(0.0, 0.16, dd.y);
    }
    // Airglow: a faint green-to-violet veil low over the horizon on dark nights.
    if g.water.w > 0.3 {
        let e = dd.y;
        let ag = exp(-e * 9.0) * smoothstep(0.0, 0.03, e) * (0.75 + 0.25 * sin(atan2(dd.x, dd.z) * 7.0 + vnoise(dd.xz * 4.0) * 3.0));
        let agc = mix(vec3f(0.03, 0.075, 0.055), vec3f(0.045, 0.03, 0.07), smoothstep(0.03, 0.18, e));
        col += agc * ag * smoothstep(0.3, 0.8, g.water.w) * (0.4 + 0.6 * g.ambient.w);
    }

    // Thin painted wisps drifting across the moon on clear nights, silver where they pass it.
    if night > 0.2 && g.moon.y > -0.02 && g.moon.w > 0.05 && dd.y > 0.02 {
        let cm = dot(dd, g.moon.xyz);
        if cm > 0.85 {
            let t = 4.0 / dd.y;
            let wq = dd.xz * t * 0.08 + g.cloud_off.zw * 0.6;
            let wdir = normalize(g.wind.xy + vec2f(1e-4, 0.0));
            let q = vec2f(dot(wq, wdir) * 0.5, dot(wq, vec2f(-wdir.y, wdir.x)) * 3.0);
            let n = fbm(q + vec2f(vnoise(q * 0.7) * 1.3, 0.0), 3);
            let near = smoothstep(0.85, 0.99, cm);
            let a = smoothstep(0.55, 0.75, n) * near * 0.55 * (1.0 - g.wx.y);
            let lit = pow(max(cm, 0.0), 120.0);
            let wc = mix(g.zenith.rgb * 1.6 + vec3f(0.03, 0.035, 0.05), vec3f(0.75, 0.78, 0.85), lit * 0.8) * (0.6 + 0.6 * g.moon.w);
            col = mix(col, wc, a);
            trans *= 1.0 - a * 0.8;
        }
    }

    let storm = g.wx.y;
    let low = g.wx.w;
    let wind_dir = normalize(g.wind.xy + vec2f(1e-4, 0.0));
    let sun_xz = normalize(g.sun.xz + vec2f(1e-4, 0.0));

    // --- Cirrus: streaks along the wind, high and thin, lit long after sunset.
    let high = g.wx2.x;
    if high > 0.02 && dd.y > 0.01 && storm < 0.6 {
        let t = 9.0 / dd.y;
        let p = dd.xz * t * 0.045;
        let u = dot(p, wind_dir);
        let v = dot(p, vec2f(-wind_dir.y, wind_dir.x));
        let q = vec2f(u * 0.35, v * 2.6) + g.cloud_off.zw;
        let n = fbm(q + vec2f(fbm(q * 0.5, 2) * 1.5, 0.0), 4);
        let a = smoothstep(1.0 - high * 0.55, 1.15 - high * 0.4, n) * smoothstep(0.01, 0.12, dd.y) * 0.6;
        let tw = g.cloud_light.rgb * (g.cloud_light.w + g.glow.w * 0.6) + g.glow.rgb * g.glow.w * 0.5;
        let cc = mix(g.ambient.rgb * 1.15, tw * 1.1 + g.ambient.rgb * 0.5, 0.75) + g.moon_col.rgb * g.moon_col.w * 0.5;
        col = mix(col, cc, a);
        trans *= 1.0 - a * 0.7;
    }

    // --- Fair-weather cumulus overhead: warped fbm on a plane at ~1.5 km,
    // lit from the sun's side, thick middles darker underneath.
    let deck = clamp(low * 1.05 + storm * 0.6, 0.0, 1.0);
    if deck > 0.02 && dd.y > 0.02 && storm < 0.85 {
        let base_h = mix(1.5, 1.0, storm);
        let t = base_h / dd.y;
        let p = dd.xz * t * 0.5 + g.cloud_off.xy;
        let w = vec2f(fbm(p * 0.5 + vec2f(3.3, 1.1), 3), fbm(p * 0.5 + vec2f(7.9, 4.4), 3));
        let pp = p + (w - 0.5) * 1.6;
        let n = fbm(pp, 5);
        let thr = mix(0.74, 0.3, deck);
        var a = smoothstep(thr, thr + 0.07, n) * smoothstep(0.05, 0.2, dd.y) * exp(-t / 50.0);
        if a > 0.001 {
            let n2 = fbm(pp + sun_xz * 0.22 * select(1.0, -1.0, g.sun.y < -0.3), 5);
            var lit = clamp(0.62 + (n - n2) * 5.0 - (n - thr) * 1.2, 0.0, 1.0);
            lit = mix(lit, (floor(lit * 4.0) + smoothstep(0.25, 0.75, fract(lit * 4.0))) / 4.0, 0.4);
            var cc = cloud_col(lit * mix(1.0, 0.55, storm), 0.5);
            cc = mix(cc, g.zenith.rgb * 0.55, storm * 0.4);
            let cs = max(dot(dd, g.sun.xyz), 0.0);
            cc += g.cloud_light.rgb * g.cloud_light.w * (1.0 - smoothstep(thr, thr + 0.1, n)) * pow(cs, 4.0) * 1.5;
            col = mix(col, cc, a);
            trans *= 1.0 - a;
        }
    }

    // --- Cumulus towers on the horizon: domes along the horizon filled with
    // sphere-shaded puffs (the front-most puff wins, like painted billows).
    let towers = g.wind.w;
    let f0 = normalize(vec3f(g.sky_fwd.x, 0.0, g.sky_fwd.z));
    let r0 = g.sky_right.xyz;
    let az = atan2(dot(dd, r0), dot(dd, f0));
    let el = asin(clamp(dd.y, -1.0, 1.0));
    // The sun in the puffs' frame: x right, y up, z towards the viewer.
    let l3 = normalize(vec3f(dot(g.sun.xyz, r0), g.sun.y + 0.15, -dot(g.sun.xyz, f0)));
    let cov = mix(low, 1.0, storm);
    let px_rad = 2.0 * g.sky_right.w / ceil(g.res.y * 0.5);
    let ax = az + g.sail2.w * 0.25;
    var reach = 0.0;
    if towers > 0.01 && el > -0.01 && el < 0.6 {
        // Skip the puffs where no tower comes near.
        reach = max(max(tower_top(ax - 0.05, cov, storm), tower_top(ax, cov, storm)), tower_top(ax + 0.05, cov, storm)) * towers;
    }
    if reach > 0.0 && el < reach + 0.04 {
        var best = -1e3;
        var bn = vec3f(0.0, 0.0, 1.0);
        var bh = 0.0;
        var alpha = 0.0;
        for (var o = 0; o < 2; o++) {
            let sc = select(22.0, 64.0, o == 1);
            let q0 = vec2f(ax, el) * sc;
            let wv = vec2f(fbm(q0 * 0.25 + vec2f(0.0, 17.0), 2), fbm(q0 * 0.25 + vec2f(31.0, 5.0), 2)) - 0.5;
            let q = q0 + wv * 1.8;
            let qi = floor(q);
            let period = 16.0 * sc;
            let aa = sc * px_rad * 2.2;
            for (var i = -1; i <= 1; i++) {
                // The envelope once per column of puffs (their centres are close in x).
                let colx = qi.x + f32(i) + 0.5;
                let top_col = tower_top(colx / sc, cov, storm) * towers;
                if top_col <= 0.0 {
                    continue;
                }
                for (var j = -1; j <= 1; j++) {
                    let c = qi + vec2f(f32(i), f32(j));
                    let cx = c.x - floor(c.x / period) * period;
                    let hid = vec2i(i32(cx), i32(c.y) + o * 7919);
                    let h1 = hash2(hid);
                    let h2 = hash2(hid + vec2i(101, 3));
                    let h3 = hash2(hid + vec2i(7, 211));
                    let ctr = c + 0.5 + (vec2f(h1, h2) - 0.5) * 0.8;
                    let r = select(0.55 + 0.4 * h3, 0.5 + 0.35 * h3, o == 1);
                    let cy = ctr.y / sc;
                    let topc = top_col;
                    // A puff belongs to a tower if its centre is inside it
                    // (it may bulge out of the top); small puffs only near the edge.
                    let inside = topc - cy;
                    if inside < r * 0.25 / sc || cy < 0.0 {
                        continue;
                    }
                    if o == 1 && inside > 2.5 * r / sc {
                        continue;
                    }
                    let dv = q - ctr;
                    let d = length(dv) + ((vnoise(q * 4.0 + vec2f(f32(o) * 9.0)) - 0.5) * 0.2 + (vnoise(q * 13.0) - 0.5) * 0.12) * r;
                    if d < r + aa {
                        let zz = sqrt(max(r * r - d * d, 0.0));
                        let z = zz / sc - cy * 0.6 + h3 * 0.004;
                        alpha = max(alpha, smoothstep(r + aa, r - aa, d));
                        if z > best && d < r {
                            best = z;
                            bn = vec3f(dv / r, zz / r);
                            bh = clamp(cy / max(topc, 1e-3), 0.0, 1.0);
                        }
                    }
                }
            }
        }
        if alpha > 0.001 {
            // One mass, not a heap of balls: the tower's height and its side
            // toward the sun carry the light; the puffs only model it a little.
            let sph = dot(bn, l3) * 0.5 + 0.5;
            let env = clamp(0.15 + 0.85 * bh + l3.x * bn.x * 0.25, 0.0, 1.0);
            var lit = mix(env, sph, 0.38);
            // Dry-brush: ragged boundaries between three flat values.
            lit += (fbm(vec2f(ax * 45.0 + el * 20.0, el * 60.0), 2) - 0.5) * 0.3;
            lit *= mix(0.72, 1.0, smoothstep(0.0, 0.3, bh));
            let lv = clamp(lit, 0.0, 1.0) * 3.0;
            lit = clamp(mix(lit, (floor(lv) + smoothstep(0.35, 0.65, fract(lv))) / 3.0, 0.7), 0.0, 1.0);
            var cc = cloud_col(lit, bh);
            // Silver lining when the sun is behind the clouds.
            let cs = max(dot(dd, g.sun.xyz), 0.0);
            let rim = pow(1.0 - bn.z, 2.0);
            cc += g.cloud_light.rgb * g.cloud_light.w * rim * (pow(cs, 5.0) * 1.8 + max(-l3.z, 0.0) * 0.25);
            // Twilight: the side toward the low sun takes the glow's colour, the rims burn.
            let tw_az = pow(max(dot(normalize(vec3f(dd.x, 0.0, dd.z)), normalize(vec3f(g.sun.x, 0.0, g.sun.z) + vec3f(1e-5, 0.0, 0.0))) * 0.5 + 0.5, 0.0), 4.0);
            cc += g.glow.rgb * g.glow.w * tw_az * (0.25 * lit + rim * 1.2) * (1.0 - storm);
            let base = smoothstep(0.0, 0.05, el);
            cc = mix(g.horizon.rgb, cc, 0.5 + 0.5 * base);
            col = mix(col, cc, alpha);
            trans *= 1.0 - alpha;
        }
    }

    // Storm: a low, ragged, uniform overcast under everything.
    if storm > 0.01 && dd.y > -0.01 {
        let p = dd.xz / max(dd.y, 0.02) * 0.9 + g.cloud_off.xy * 3.0;
        let n = fbm(p * 0.5, 4);
        let a = storm * smoothstep(0.25, 0.6, n + 0.25 * storm) * 0.95;
        var cc = mix(g.zenith.rgb * 0.55, g.horizon.rgb * 0.85, smoothstep(0.3, 0.8, n));
        cc = mix(cc, g.horizon.rgb, 1.0 - smoothstep(0.0, 0.08, dd.y));
        col = mix(col, cc, a);
        trans *= 1.0 - a;
    }

    // Rain veils hang under the clouds.
    col = mix(col, g.horizon.rgb * 0.8, g.wx.z * 0.35 * (1.0 - smoothstep(0.0, 0.4, dd.y)));
    return vec4f(col, trans);
}

// --- Boat pass --------------------------------------------------------------------------

struct BoatIn {
    @location(0) a: vec4f,
    @location(1) b: vec4f,
    @location(2) c: vec4f,
};
struct BoatOut {
    @builtin(position) pos: vec4f,
    @location(0) world: vec3f,
    @location(1) n: vec3f,
    @location(2) local: vec3f,
    @location(3) puv: vec3f,
};

const MAST_X: f32 = 0.9;

fn sgn(x: f32) -> f32 {
    return select(-1.0, 1.0, x >= 0.0);
}

fn main_sail(u: f32, v: f32) -> vec3f {
    let reef = g.sail.z;
    let slack = g.sail.w;
    let top = mix(14.0, 9.2, reef);
    let foot_y = 2.08;
    let y = mix(foot_y, top, v);
    let luff = vec3f(MAST_X - 0.08, y, 0.0);
    let chord = mix(4.5, 0.32, pow(v, 0.95)) + 0.38 * sin(PI * v) * (1.0 - 0.5 * reef);
    let side = sgn(g.sail.x);
    let alpha = g.sail.x + side * 0.24 * v * (1.0 - slack);
    let dir = vec3f(-cos(alpha), 0.0, sin(alpha));
    let nrm = side * vec3f(sin(alpha), 0.0, cos(alpha));
    let camber = g.sail.y * (1.0 - 0.35 * v) * (1.0 - 0.6 * slack);
    var p = luff + dir * u * chord + nrm * camber * chord * 4.0 * u * (1.0 - u) * (1.0 - 0.25 * u);
    let ph = g.sail2.z;
    let fl = 0.012 + 0.07 * slack;
    p += nrm * chord * fl * u * (sin(ph - u * 6.0 + v * 2.5) + 0.4 * sin(2.0 * ph - u * 11.0 + 1.3));
    return p;
}

fn jib(u: f32, v: f32) -> vec3f {
    let furl = g.sail2.y;
    let slack = g.sail.w;
    let tack = vec3f(4.95, 1.28, 0.0);
    let head = vec3f(1.62, 11.6, 0.0);
    let luff = mix(tack, head, v);
    let chord = mix(3.85, 0.14, v) * (1.0 - furl);
    let side = sgn(g.sail.x);
    let beta = g.sail2.x + side * 0.18 * v * (1.0 - slack);
    let dir = vec3f(-cos(beta), 0.0, sin(beta));
    let nrm = side * vec3f(sin(beta), 0.0, cos(beta));
    let camber = g.sail.y * 1.15 * (1.0 - 0.6 * slack);
    var p = luff + dir * u * chord + nrm * camber * chord * 4.0 * u * (1.0 - u);
    p.y += u * 0.55 * (1.0 - v) * (1.0 - furl);
    let ph = g.sail2.z;
    let fl = 0.015 + 0.1 * slack;
    p += nrm * chord * fl * u * sin(ph * 2.0 - u * 8.0 + v * 4.0);
    return p;
}

// Flags streaming downwind: id 0 the burgee (a pennant at the masthead), 1 the ensign astern.
fn flag(u: f32, v: f32, id: f32) -> vec3f {
    let wind = g.wind.z;
    let beta = g.sail.x * 1.35;
    let dir = normalize(vec3f(-cos(beta), -0.7 * (1.0 - smoothstep(2.0, 10.0, wind)), sin(beta)));
    let nrm = vec3f(sin(beta), 0.0, cos(beta));
    let t = g.res.z * (5.0 + wind * 0.35);
    var p: vec3f;
    if id < 0.5 {
        let anchor = vec3f(MAST_X, 14.82, 0.0);
        p = anchor + dir * u * 0.8 + vec3f(0.0, (0.5 - v) * 0.34 * (1.0 - u * 0.92), 0.0);
    } else {
        let anchor = vec3f(-4.74, 2.18, -0.45);
        p = anchor + dir * u * 0.62 - vec3f(0.0, v * 0.38, 0.0);
    }
    p += nrm * (0.03 + wind * 0.0025) * u * sin(t - u * 9.0 + v * 1.5);
    p += dir * 0.02 * u * sin(t * 1.3 - u * 7.0);
    return p;
}

fn boom(p: vec3f) -> vec3f {
    let a = g.sail.x;
    let c = cos(a);
    let s = sin(a);
    let r = p - vec3f(MAST_X, 0.0, 0.0);
    return vec3f(MAST_X + r.x * c + r.z * s, p.y, -r.x * s + r.z * c);
}

fn to_world(l: vec3f) -> vec3f {
    return g.boat_p.xyz + l.x * g.boat_f.xyz + l.y * g.boat_u.xyz + l.z * g.boat_s.xyz;
}

fn box_clip(w: vec3f) -> vec4f {
    let rel = w - g.cam_pos.xyz;
    let z = dot(rel, g.cam_fwd.xyz);
    let x = dot(rel, g.cam_right.xyz) / (g.cam_pos.w * g.cam_right.w);
    let y = dot(rel, g.cam_up.xyz) / g.cam_pos.w;
    let b = g.boat_box;
    let pxz = (x * 0.5 + 0.5 * z) * g.res.x;
    let pyz = (0.5 * z - y * 0.5) * g.res.y;
    let bxz = (pxz - b.x * z) / (b.z - b.x) * 2.0 - z;
    let byz = z - (pyz - b.y * z) / (b.w - b.y) * 2.0;
    let near = 1.0;
    let far = 400.0;
    return vec4f(bxz, byz, (z - near) * far / (far - near), z);
}

@vertex
fn vs_boat(v: BoatIn) -> BoatOut {
    let part = v.a.w;
    let u = v.b.w;
    let vv = v.c.x;
    var l = v.a.xyz;
    var n = v.b.xyz;
    if part > 4.5 && part < 6.5 {
        let e = 0.02;
        if part < 5.5 {
            l = main_sail(u, vv);
            n = normalize(cross(main_sail(u, vv + e) - l, main_sail(u + e, vv) - l));
        } else {
            l = jib(u, vv);
            n = normalize(cross(jib(u, vv + e) - l, jib(u + e, vv) - l));
        }
    } else if part > 3.5 && part < 4.5 {
        l = boom(l);
        n = boom(n + vec3f(MAST_X, 0.0, 0.0)) - vec3f(MAST_X, 0.0, 0.0);
    } else if part > 9.5 && part < 10.5 {
        // The helmsman sits to windward (the boom's other side).
        let ws = -sgn(g.sail.x);
        l.z *= ws;
        n.z *= ws;
    } else if part > 11.5 {
        let e = 0.03;
        l = flag(u, vv, v.c.y);
        n = normalize(cross(flag(u, vv + e, v.c.y) - l, flag(u + e, vv, v.c.y) - l));
    }
    var o: BoatOut;
    let w = to_world(l);
    o.pos = box_clip(w);
    o.world = w;
    o.n = n.x * g.boat_f.xyz + n.y * g.boat_u.xyz + n.z * g.boat_s.xyz;
    o.local = l;
    o.puv = vec3f(part + select(0.0, v.c.y, part > 11.5), u, vv);
    return o;
}

fn half_beam(t: f32) -> f32 {
    if t < 0.45 {
        let s = clamp(t / 0.45, 0.0, 1.0);
        return 1.65 * (0.78 + 0.22 * s * s * (3.0 - 2.0 * s));
    }
    let s = clamp((t - 0.45) / 0.55, 0.0, 1.0);
    return 1.65 * sqrt(max(1.0 - pow(s, 1.9), 0.0));
}

@fragment
fn fs_boat(i: BoatOut, @builtin(front_facing) ff: bool) -> @location(0) vec4f {
    let part = i.puv.x;
    // Everything under the local sea surface is hidden by the water: the waves
    // running along the hull, the bow wave piling up at the stem, wash at the
    // transom and a slap that comes and goes.
    let lvl = g.boat_p.y + 0.05;
    let tt = (i.local.x + 4.8) / 10.0;
    let spd = g.boat_p.w;
    let windy = smoothstep(4.0, 28.0, g.wind.z);
    // The very surface sea() ray-marches (waves + the boat's own bow wave and wake).
    let water = surf_h(i.world.xz);
    if i.world.y < water {
        discard;
    }
    // A nearer crest (or the bow wave heaped up in front) hides the hull behind it: walk the
    // sight line from the camera, densest close to this fragment.
    if i.world.y - water < 1.1 {
        let to_f = i.world - g.cam_pos.xyz;
        let len = length(to_f);
        let dir = to_f / len;
        var hid = false;
        for (var k = 0; k < 10; k++) {
            let back = 0.35 * pow(1.75, f32(k));
            if back > len - 1.0 {
                break;
            }
            let q = i.world - dir * back;
            if q.y < surf_h(q.xz) {
                hid = true;
                break;
            }
        }
        if hid {
            discard;
        }
    }
    let above = i.world.y - water;
    var n = normalize(i.n);
    let view = normalize(g.cam_pos.xyz - i.world);
    if dot(n, view) < 0.0 {
        n = -n;
    }
    let l = i.local;
    let u = i.puv.y;
    let v = i.puv.z;
    let night = g.water.w;
    var albedo = vec3f(0.9);
    var emit = vec3f(0.0);
    var sail = 0.0;
    if part < 0.5 {
        // Hull: antifouling, boot stripe, white topsides, a cove stripe.
        let t = (l.x + 4.8) / 10.0;
        let sheer_y = 0.86 + 1.1 * (t - 0.42) * (t - 0.42) + 0.18 * pow(t, 4.0);
        albedo = vec3f(0.9, 0.88, 0.83);
        if l.y < 0.16 {
            albedo = vec3f(0.11, 0.16, 0.28);
        }
        if l.y < 0.07 {
            albedo = vec3f(0.36, 0.12, 0.1);
        }
        // Wet where the waves wash, a broken foam line where they meet the hull.
        let wob = vnoise(vec2f(l.x * 3.0 + g.res.z * 0.8, l.z * 2.0)) * 0.08;
        albedo *= mix(0.6, 1.0, smoothstep(0.0, 0.6 + 0.4 * windy, above - wob));
        let fl_ = smoothstep(0.16 + wob, 0.05, above) * (0.55 + 0.45 * smoothstep(0.3, 0.6, vnoise(vec2f(l.x * 6.0 - g.res.z * 2.0, l.z * 5.0))));
        albedo = mix(albedo, vec3f(1.0), fl_ * (0.5 + 0.5 * spd));
        // Three portholes each side under the sheer, warm at night.
        let ph_ = vec2f((fract((l.x + 1.25) / 0.78) - 0.5) * 0.78, l.y - (sheer_y - 0.3));
        if l.x > -1.25 && l.x < 1.1 && length(ph_ * vec2f(1.0, 1.7)) < 0.09 && night > 0.2 {
            albedo = vec3f(0.08, 0.1, 0.13);
            emit = vec3f(1.0, 0.66, 0.32) * 0.9 * night;
        }
    } else if part < 1.5 {
        albedo = vec3f(0.74, 0.66, 0.53);
        albedo *= 0.9 + 0.1 * step(0.5, fract(i.puv.z * 18.0));
        // The cockpit well, shadowed.
        if l.x < -1.3 && l.x > -4.15 && abs(l.z) < 1.0 {
            albedo *= 0.55;
        }
    } else if part < 2.5 {
        albedo = vec3f(0.88, 0.86, 0.8);
        // Windows: a dark band along the trunk sides, lit warm at night.
        let dt_ = (l.x + 4.8) / 10.0 - 0.42;
        let deck_y = 0.86 + 1.1 * dt_ * dt_ + 0.05;
        let wy = l.y - deck_y;
        if abs(n.y) < 0.6 && wy > 0.3 && wy < 0.46 && l.x > -1.1 && l.x < 1.5 && fract(l.x * 0.9) < 0.75 {
            albedo = vec3f(0.07, 0.09, 0.12);
            emit = vec3f(1.0, 0.62, 0.3) * 0.75 * night;
        }
        if l.x < -1.2 {
            albedo = vec3f(0.3, 0.34, 0.42); // sprayhood
        }
    } else if part < 3.5 {
        albedo = vec3f(0.72, 0.74, 0.78);
    } else if part < 4.5 {
        albedo = vec3f(0.62, 0.64, 0.68);
    } else if part < 6.5 {
        sail = 1.0;
        albedo = vec3f(0.95, 0.93, 0.87);
        // Panels and the reef band
        let seam = smoothstep(0.035, 0.0, abs(fract(v * 7.0 + u * 0.4) - 0.5) - 0.465);
        albedo *= 1.0 - 0.1 * seam;
        if part < 5.5 {
            albedo *= 1.0 - 0.18 * smoothstep(0.02, 0.0, abs(u - 0.98)); // leech line
        } else {
            // UV strip along the jib's leech and foot
            if u > 0.93 || (v < 0.05 && u > 0.1) {
                albedo = vec3f(0.12, 0.2, 0.36);
            }
            // Telltales streaming aft just behind the luff.
            for (var k = 0; k < 3; k++) {
                let tv = 0.3 + 0.2 * f32(k);
                let tw = sin(g.res.z * 9.0 + f32(k) * 2.1 - u * 60.0) * 0.004;
                if u > 0.07 && u < 0.15 && abs(v - tv + tw) < 0.006 {
                    albedo = select(vec3f(0.75, 0.12, 0.1), vec3f(0.1, 0.45, 0.2), k == 1);
                }
            }
        }
        if part < 5.5 {
            // Battens: pockets from the leech in.
            let bv = fract(v * 5.0);
            if u > 0.7 && abs(bv - 0.5) < 0.012 * 5.0 && v < 0.92 {
                albedo *= 0.86;
            }
            // Draft shadow behind the belly, lighter toward the leech (painted, not shaded).
            albedo *= 1.0 - 0.08 * smoothstep(0.15, 0.4, u) * smoothstep(0.75, 0.45, u);
        }
    } else if part < 7.5 {
        albedo = vec3f(0.62, 0.64, 0.68);
    } else if part < 8.5 {
        albedo = vec3f(0.2, 0.22, 0.25); // rigging wire
    } else if part < 9.5 {
        albedo = vec3f(0.5, 0.33, 0.2); // teak
    } else if part < 10.5 {
        // Yellow oilskins, a navy hat.
        let dt_ = (l.x + 4.8) / 10.0 - 0.42;
        let deck_y = 0.86 + 1.1 * dt_ * dt_ + 0.05;
        albedo = select(vec3f(0.82, 0.62, 0.24), vec3f(0.2, 0.22, 0.3), l.y > deck_y + 0.84);
    } else if part < 11.5 {
        albedo = vec3f(0.3);
        let lc = select(select(vec3f(1.0, 0.95, 0.85), vec3f(0.3, 1.0, 0.45), l.z > 0.1), vec3f(1.0, 0.2, 0.15), l.z < -0.1);
        emit = lc * 3.0 * night;
    } else if part < 12.5 {
        // Burgee: blue with a white star stripe.
        albedo = select(vec3f(0.1, 0.2, 0.55), vec3f(0.95), abs(v - 0.5) < 0.12 * (1.0 - u));
    } else {
        // Ensign: thirteen stripes, a blue canton.
        let stripe = fract(v * 6.5) < 0.5;
        albedo = select(vec3f(0.95, 0.93, 0.9), vec3f(0.75, 0.1, 0.12), stripe);
        if u < 0.42 && v < 0.54 {
            albedo = vec3f(0.12, 0.16, 0.42);
        }
    }
    // Paint: a little stroke texture along each part, and broad patches of
    // warmer and cooler colour so no part is one flat fill.
    albedo *= 1.0 + (vnoise(vec2f(l.x * 7.0 + l.z * 3.0, l.y * 22.0)) - 0.5) * 0.08;
    let patch_ = vnoise(vec2f(l.x * 0.9 + l.z * 0.7 + 3.0, l.y * 0.8)) - 0.5;
    albedo *= vec3f(1.0 + patch_ * 0.16, 1.0 + patch_ * 0.03, 1.0 - patch_ * 0.14);

    // Light: sun, moon, sky, the sea's bounce; sails glow through when backlit.
    let ls = g.sun.xyz;
    let lm = g.moon.xyz;
    let sun_on = smoothstep(-0.03, 0.04, ls.y);
    let moon_on = smoothstep(-0.03, 0.04, lm.y);
    // Brush strokes follow each part's form: along the hull and deck, across the
    // sails' chord, along spars and wire. They break up the light's flat planes.
    var sc2 = vec2f(l.x * 1.1, l.y * 14.0 + l.z * 9.0);
    if part > 4.5 && part < 6.5 {
        sc2 = vec2f(u * 2.2, v * 26.0);
    } else if (part > 2.5 && part < 4.5) || (part > 7.5 && part < 8.5) {
        sc2 = vec2f(l.y * 0.8 + l.x * 0.8, (l.x + l.z) * 30.0);
    }
    let stroke = vnoise(sc2) * 0.65 + vnoise(sc2 * vec2f(1.7, 3.1) + 13.0) * 0.35;
    var dl = (dot(n, ls) + 0.25) / 1.25;
    dl = clamp(dl + (stroke - 0.5) * 0.22, 0.0, 1.0);
    dl = (floor(dl * 3.0) + smoothstep(0.42, 0.58, fract(dl * 3.0))) / 3.0;
    var light = g.sun_col.rgb * g.sun_col.w * dl * sun_on;
    light += g.moon_col.rgb * g.moon_col.w * max((dot(n, lm) + 0.25) / 1.25, 0.0) * moon_on;
    // White topsides stay white in shade (a painter keeps the hull a light shape).
    light += g.ambient.rgb * (0.62 + 0.38 * n.y) * select(1.05, 1.4, part < 0.5);
    light += g.water.rgb * 0.35 * max(-n.y, 0.0);
    light += vec3f(0.8, 0.85, 1.0) * g.lightning.x * 0.8;
    let through = max(-dot(n, ls), 0.0) * sun_on * sail;
    light += g.sun_col.rgb * g.sun_col.w * through * 0.55 * vec3f(1.0, 0.92, 0.8);
    // Shadows take the sky's cool colour, not grey.
    light += g.zenith.rgb * 0.3 * (1.0 - dl) * (1.0 - night * 0.5);
    // Sea-green bounce up under the hull and the sails' feet.
    let bounce = vec3f(0.3, 0.55, 0.5) * mix(1.0, 0.0, night) + g.water.rgb * 0.5;
    light += bounce * 0.18 * smoothstep(1.6, 0.0, l.y) * (1.0 - max(n.y, 0.0)) * (1.0 - dl * 0.5);
    var c = albedo * light * (1.0 + (stroke - 0.5) * 0.1);
    // Painted edge highlights: a hard rim on the edges turned toward the light.
    let rimf = 1.0 - abs(dot(n, view));
    let rim = smoothstep(0.55, 0.7, rimf + (stroke - 0.5) * 0.15);
    let toward = smoothstep(-0.2, 0.3, dot(n, ls)) * sun_on;
    c += (g.sun_col.rgb * g.sun_col.w * toward * 0.5 + g.moon_col.rgb * g.moon_col.w * moon_on * 0.4 + g.ambient.rgb * 0.12) * rim * albedo * 1.4;
    // One palette with the sky and sea: a little less saturated.
    c = mix(vec3f(dot(c, vec3f(0.3, 0.55, 0.15))), c, 0.85);
    // Air between us and the boat: a veil of the horizon's colour.
    c = mix(c, g.horizon.rgb, 0.05);
    c += emit;
    return vec4f(c, 1.0);
}

// --- Composite pass ----------------------------------------------------------------------

// --- Stars: the Yale Bright Star Catalogue (stars.rs) -----------------------------------------
// star_tab = 6 x 64 x 64 cube-face cells (first, count), then the star records (J2000 unit vector,
// packed magnitude + B-V). Every star is listed in all cells its glow reaches, so a pixel reads its
// own cell only. Sizes below are in pixels of a 1440-line output (scaled by res.y / 1440).

// How far a star's glow reaches (1440p px); stars.rs reach_px() must match.
fn star_reach(m: f32) -> f32 {
    return clamp(5.0 + 8.2 * (4.5 - m), 3.2, 60.0);
}

// B-V colour index -> a painted star tint (blue-white ... white ... straw ... orange ... red).
fn star_tint(bv: f32) -> vec3f {
    var t = vec3f(0.64, 0.76, 1.0);
    t = mix(t, vec3f(0.82, 0.89, 1.0), smoothstep(-0.2, 0.15, bv));
    t = mix(t, vec3f(1.0, 0.97, 0.92), smoothstep(0.15, 0.55, bv));
    t = mix(t, vec3f(1.0, 0.87, 0.64), smoothstep(0.55, 1.0, bv));
    t = mix(t, vec3f(1.0, 0.7, 0.46), smoothstep(1.0, 1.5, bv));
    t = mix(t, vec3f(1.0, 0.56, 0.4), smoothstep(1.5, 2.1, bv));
    return t;
}

// Faint procedural stars below the catalogue's limit, mostly along the galactic plane, so the
// Milky Way is not empty. One grid cell per pixel: they are dim and a few px across.
fn star_haze(uv: vec2f, face: i32, band: f32, cell_px: f32) -> vec3f {
    let cells = 260.0;
    let q = (uv * 0.5 + 0.5) * cells;
    let ci = vec2i(floor(q));
    let f = fract(q);
    let lo = 50021;
    let dens = 0.025 + 0.42 * band;
    let h0 = hash2(ci + vec2i(face * 4099 + lo, face * 7919));
    if h0 >= dens {
        return vec3f(0.0);
    }
    let h1 = hash2(ci + vec2i(17 + lo, 3 + face * 101));
    let h2 = hash2(ci + vec2i(5, 91 + face * 31 + lo));
    let h3 = hash2(ci + vec2i(43 + lo, 11 + face * 7));
    let dist = length((f - (vec2f(h1, h2) * 0.7 + 0.15)) * cell_px);
    let mag = pow(h3, 3.0) * 0.1 + 0.035;
    let t = fract(h2 * 7.31);
    var tint = vec3f(1.0, 0.97, 0.92);
    tint = mix(tint, vec3f(0.7, 0.8, 1.0), smoothstep(0.62, 0.72, t));
    tint = mix(tint, vec3f(1.0, 0.86, 0.62), smoothstep(0.2, 0.12, t));
    return tint * exp(-dist * dist / (0.5 + mag * 2.0)) * mag;
}

// One star or planet: a soft painted dot, a glow and a faint four-point glint for the bright ones.
// dv = pixel - star in 1440p px, m = magnitude, ph0 < 0 = steady (planets); else twinkle phases in 0..1.
fn star_dot(dv: vec2f, m: f32, tint: vec3f, horizon: f32, ph0: f32, ph1: f32) -> vec3f {
    let r2 = dot(dv, dv);
    let reach = star_reach(m);
    // Peak brightness: x1.46 per magnitude from 0.85 at V 6.5 (compressed vs the real 2.5x, so faint
    // stars stay visible), softly capped at 4.
    let pk = 4.0 * tanh(0.85 * pow(10.0, 0.165 * (6.5 - m)) / 4.0);
    // A soft painted dot; width grows a little for the bright ones.
    let sig = 0.8 + 0.16 * clamp(4.5 - m, 0.0, 9.0);
    var lum = pk * exp(-r2 / (2.0 * sig * sig));
    // Glow for the bright ones (halo fades to nothing at the reach, so no cell can cut it).
    let hb = clamp((4.2 - m) / 5.5, 0.0, 1.0);
    if hb > 0.0 {
        let r = sqrt(r2);
        // Venus-bright objects (m < -0.5) get a bigger glow and glint than the pk cap alone would give.
        let ex = clamp((-0.5 - m) / 3.5, 0.0, 1.0);
        lum += exp(-r / ((1.5 + 8.0 * hb) * (1.0 + 0.5 * ex))) * 0.13 * pk * sqrt(hb) * (1.0 + 0.6 * ex) * smoothstep(reach, reach * 0.45, r);
        // A faint four-point glint on the brightest.
        let gb2 = clamp((2.2 - m) / 3.7, 0.0, 1.0);
        if gb2 > 0.0 {
            let la = (2.5 + 4.0 * gb2) * (1.0 + 0.8 * ex);
            let gl = exp(-abs(dv.x) / la - dv.y * dv.y * 1.1) + exp(-abs(dv.y) / la - dv.x * dv.x * 1.1);
            lum += gl * 0.3 * pk * gb2 * smoothstep(reach, reach * 0.5, r);
        }
    }
    // Twinkle: slow, mostly the bright ones, more near the horizon.
    let tw = select(1.0, 1.0 + (0.1 + 0.18 * horizon) * sin(g.res.z * (1.3 + ph0 * 3.0) + ph1 * TAU) * min(pk, 1.0), ph0 >= 0.0);
    return tint * lum * tw;
}

fn stars(d: vec3f, px: vec2f) -> vec3f {
    let c = vec3f(dot(g.cel[0].xyz, d), dot(g.cel[1].xyz, d), dot(g.cel[2].xyz, d));
    let a = abs(c);
    var uv: vec2f;
    var face = 0;
    if a.x >= a.y && a.x >= a.z {
        uv = c.yz / a.x;
        face = select(0, 1, c.x < 0.0);
    } else if a.y >= a.z {
        uv = c.xz / a.y;
        face = select(2, 3, c.y < 0.0);
    } else {
        uv = c.xy / a.z;
        face = select(4, 5, c.z < 0.0);
    }
    let sc = g.res.y / 1440.0;
    let vis = g.ambient.w;
    var col = vec3f(0.0);

    // Haze (galactic-plane faint stars).
    let gb = dot(c, vec3f(-0.8677, -0.1981, 0.4560));
    let band = exp(-gb * gb / 0.04);
    let cell_px = (2.0 / 260.0) / (2.0 * g.cam_pos.w / g.res.y);
    col += star_haze(uv, face, band, cell_px);

    // The catalogue. A brighter sky (twilight, moonlight, haze) hides the faint ones first.
    let lim = 2.2 + 5.0 * pow(clamp(vis, 0.0, 1.0), 0.6);
    let n = f32(STAR_GRID);
    let ci = clamp(vec2i(floor((uv * 0.5 + 0.5) * n)), vec2i(0), vec2i(STAR_GRID - 1));
    let ent = star_tab[u32(face * STAR_GRID * STAR_GRID + ci.y * STAR_GRID + ci.x)];
    let first = u32(ent.x);
    let cnt = u32(ent.y);
    let t = g.cam_pos.w;
    let horizon = 1.0 - smoothstep(0.05, 0.4, d.y);
    for (var i = 0u; i < cnt; i++) {
        let sr = star_tab[first + i];
        let wi = u32(sr.w);
        let m = f32(wi >> 10u) * 0.02 - 2.0;
        let fade = smoothstep(lim + 0.4, lim - 0.9, m);
        if fade <= 0.0 {
            continue;
        }
        // The star on the screen: exact rectilinear projection, so it sits where the real one does.
        let sw = sr.x * g.cel[0].xyz + sr.y * g.cel[1].xyz + sr.z * g.cel[2].xyz;
        let zc = dot(sw, g.cam_fwd.xyz);
        if zc <= 0.01 {
            continue;
        }
        let spx = vec2f(
            (dot(sw, g.cam_right.xyz) / (zc * t * g.cam_right.w) * 0.5 + 0.5) * g.res.x,
            (0.5 - dot(sw, g.cam_up.xyz) / (zc * t) * 0.5) * g.res.y
        );
        let dv = (px - spx) / sc;
        let r2 = dot(dv, dv);
        let reach = star_reach(m);
        if r2 >= reach * reach {
            continue;
        }
        let bv = f32(wi & 1023u) * 0.005 - 0.5;
        col += star_dot(dv, m, star_tint(bv), horizon, fract(sr.x * 91.7), fract(sr.y * 57.3)) * fade;
    }
    // The planets: steady points, tinted, placed exactly like the stars.
    for (var k = 0; k < 5; k++) {
        let pl = g.planets[k];
        let fade = smoothstep(lim + 0.4, lim - 0.9, pl.w);
        let zc = dot(pl.xyz, g.cam_fwd.xyz);
        if pl.y <= 0.0 || fade <= 0.0 || zc <= 0.01 {
            continue;
        }
        let spx = vec2f(
            (dot(pl.xyz, g.cam_right.xyz) / (zc * t * g.cam_right.w) * 0.5 + 0.5) * g.res.x,
            (0.5 - dot(pl.xyz, g.cam_up.xyz) / (zc * t) * 0.5) * g.res.y
        );
        let dv = (px - spx) / sc;
        let reach = star_reach(pl.w);
        if dot(dv, dv) >= reach * reach {
            continue;
        }
        var tint = vec3f(0.95, 0.9, 0.82); // Mercury
        tint = select(tint, vec3f(1.0, 0.97, 0.9), k == 1); // Venus
        tint = select(tint, vec3f(1.0, 0.6, 0.4), k == 2); // Mars
        tint = select(tint, vec3f(1.0, 0.94, 0.82), k == 3); // Jupiter
        tint = select(tint, vec3f(1.0, 0.89, 0.68), k == 4); // Saturn
        col += star_dot(dv, pl.w, tint, 0.0, -1.0, 0.0) * fade * (1.0 - 0.5 * (1.0 - smoothstep(0.0, 0.12, pl.y)));
    }
    return col * smoothstep(0.0, 0.12, d.y);
}

// A shooting star now and then: one slot in ~6 of 9 s holds a short streak.
fn meteor(px: vec2f, hy: f32) -> vec3f {
    let t = g.res.z / 9.0;
    let slot = floor(t);
    let h = hash1(slot * 3.7 + 1.0);
    if h > 0.16 {
        return vec3f(0.0);
    }
    let life = fract(t) * 9.0 / 0.9; // 0..1 over 0.9 s
    if life > 1.0 {
        return vec3f(0.0);
    }
    let a0 = vec2f(hash1(slot + 11.0), hash1(slot + 23.0) * 0.6) * vec2f(g.res.x, hy);
    let ang = 0.35 + hash1(slot + 31.0) * 0.6;
    let dir = vec2f(select(-1.0, 1.0, hash1(slot + 41.0) > 0.5) * cos(ang), sin(ang));
    let len = g.res.y * (0.12 + 0.15 * hash1(slot + 53.0));
    let head = a0 + dir * len * life;
    let tail = head - dir * len * 0.45 * min(life * 3.0, 1.0);
    let pa = px - tail;
    let ab = head - tail;
    let s = clamp(dot(pa, ab) / max(dot(ab, ab), 1e-3), 0.0, 1.0);
    let dl = length(pa - ab * s);
    let w = 0.6 + 1.2 * s;
    let fade = sin(life * PI);
    let streak = exp(-dl * dl / (w * w)) * s * s;
    return vec3f(0.85, 0.92, 1.0) * (streak * 1.3 + exp(-length(px - head) / 4.0) * 0.5) * fade;
}

fn seg_dist(p: vec2f, a: vec2f, b: vec2f) -> f32 {
    let pa = p - a;
    let ba = b - a;
    let h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-4), 0.0, 1.0);
    return length(pa - ba * h);
}

fn bolt_pt(i: i32) -> vec2f {
    let v = g.bolt[i / 2];
    return select(v.xy, v.zw, (i % 2) == 1);
}

fn sample_boat(px: vec2f) -> vec4f {
    let b = g.boat_box;
    let uv = (px - b.xy) / (b.zw - b.xy);
    if any(uv < vec2f(0.0)) || any(uv > vec2f(1.0)) {
        return vec4f(0.0);
    }
    return textureSampleLevel(boat_tex, samp, uv, 0.0);
}

struct Sea {
    col: vec3f,
    fres: f32,
};

fn sea(d: vec3f, px: vec2f, rpx: vec2f) -> Sea {
    let dist = g.cam_pos.y / max(-d.y, 1e-4);
    // Where the ray meets the real surface (displaced near the boat), not a flat plane.
    let hit = sea_hit(d);
    let p = hit.xy;
    // Along-view footprint of one pixel (m), for filtering detail away.
    let fp = dist * 2.0 * g.cam_pos.w / g.res.y / max(-d.y, 0.02);

    var h = 0.0;
    var grad = vec2f(0.0);
    var crest = 0.0;
    var crest_w = 0.0;
    var lod_sum = 0.0;
    for (var i = 0; i < 6; i++) {
        let w = g.waves[i];
        let lam = TAU / w.z;
        let lod = clamp(lam / (fp * 5.0) - 0.4, 0.0, 1.0);
        let th = w.z * dot(w.xy, p) - wave_phase(i);
        let s = sin(th);
        let b = 0.5 * (s + 1.0);
        let kq = wave_sharp(i) - 1.0;
        let bp = b + kq * (b * b - b);
        h += w.w * (2.0 * bp - 1.0);
        let ds = (1.0 + kq * (2.0 * b - 1.0)) * cos(th);
        grad += w.w * lod * ds * w.z * w.xy;
        if i >= 2 {
            crest += bp * w.w * lod;
            crest_w += w.w;
        }
        lod_sum += lod;
    }
    crest /= max(crest_w, 1e-4);

    // Short chop (normals only), stronger in the gust patches crossing the water.
    let gp = vnoise(p * 0.018 + g.sharp[1].zw);
    let gust_k = (0.45 + 1.2 * gp * gp) * (1.0 + 0.5 * g.wx2.w);
    var lost = 0.0;
    var hd = 0.0;
    var hd_w = 0.0;
    // The finest chop is left to the brush (its energy goes into roughness).
    for (var i = 0; i < 12; i++) {
        let w = g.detail[i];
        if i >= 9 {
            lost += w.w * w.z;
            continue;
        }
        let lam = TAU / w.z;
        let lod = clamp(lam / (fp * 4.0) - 0.35, 0.0, 1.0);
        if lod <= 0.0 {
            lost += w.w * w.z;
            continue;
        }
        let th = w.z * dot(w.xy, p) - g.dphase[i / 4][i % 4];
        grad += w.w * w.z * cos(th) * w.xy * lod * gust_k;
        if i >= 2 && i < 7 {
            hd += w.w * sin(th) * lod;
            hd_w += w.w;
        }
        lost += (1.0 - lod) * w.w * w.z;
    }
    // Finest sparkle, and rain dimpling the surface.
    let rf = g.phase[1].w;
    // Rain dimples the surface.
    if g.wx.z > 0.01 {
        let lod3 = clamp(1.0 / (rf * 3.1 * fp * 3.0) - 0.3, 0.0, 1.0);
        let n3 = vnoised((p + g.ripple_off.zw) * 2.75);
        grad += n3.yz * 2.75 * 0.0012 * lod3 * g.wx.z;
    }
    // What the filtering removed comes back as roughness.
    // Around the hull: rings spreading from it, and a flattened, darker skin of water close in.
    // Distance to the hull measured where it actually meets this water: the surface point goes
    // into the boat's own (heaved, pitched, heeled) frame and meets the real section there.
    let hb_f = normalize(g.boat_f.xz + vec2f(1e-4, 0.0));
    let hb_s = vec2f(-hb_f.y, hb_f.x);
    let h_rel = p - g.boat_p.xz;
    let h_al = dot(h_rel, hb_f);
    let h_lat = dot(h_rel, hb_s);
    var h_d = 99.0;
    var h_dz = 99.0;
    var h_dxo = 0.0;
    var h_dd = 0.0;
    var h_near = 0.0;
    if abs(h_al) < 16.0 && abs(h_lat) < 16.0 {
        let sh = surf_h(p);
        let hl = to_local(vec3f(p.x, sh, p.y));
        let ht = clamp((hl.x + 4.8) / 10.0, 0.0, 1.0);
        let hw = hull_hw(ht, clamp(hl.y, -hull_draft(ht), hull_sheer(ht)));
        h_dz = abs(hl.z) - hw;
        h_dxo = max(max(-4.8 - hl.x, hl.x - 5.2), 0.0);
        h_dd = max(h_dz, 0.0);
        h_d = sqrt(h_dd * h_dd + h_dxo * h_dxo);
        h_near = exp(-h_d / 2.5);
        let outw = normalize(hb_s * sign(h_lat) * h_dd + hb_f * sign(h_al) * h_dxo + vec2f(1e-4, 0.0));
        grad += outw * cos(h_d * 5.0 - g.res.z * 4.0) * 0.06 * h_near * (0.4 + g.boat_p.w);
        // The boat's own waves tilt the water: slope of its displacement.
        let e = 0.12;
        grad += vec2f(hull_disp(p + vec2f(e, 0.0)) - hull_disp(p - vec2f(e, 0.0)),
                      hull_disp(p + vec2f(0.0, e)) - hull_disp(p - vec2f(0.0, e))) / (2.0 * e);
    }
    let rough = clamp(lost * 2.5 * gust_k, 0.0, 0.7);
    let n = normalize(vec3f(-grad.x, 1.0, -grad.y));

    let cosv = clamp(dot(-d, n), 0.0, 1.0);
    let fres = 0.02 + 0.98 * pow(1.0 - cosv, 5.0);
    var r = reflect(d, n);
    r.y = max(r.y, 0.004);
    r = normalize(r);
    var refl = sample_sky_refl(r, p);
    // A rough sea smears the reflection towards the average sky.
    refl = mix(refl, mix(g.horizon.rgb, g.zenith.rgb, 0.35), rough * 0.6);

    // The boat's reflection: the box mirrored about the waterline, wobbling with the sea.
    let wl = g.boat_misc.x;
    if rpx.y > wl && g.boat_misc.z > 0.0 {
        let k = (rpx.y - wl);
        // Laid in like the sea itself: thin horizontal dashes, each row slid sideways
        // by its own ripple and broken into lengths, gaps of sea between.
        let kk = g.res.y / 1440.0;
        let rh = 2.6 * kk * (1.0 + k / (90.0 * kk));
        let row = floor(k / rh);
        let hr = hash2(vec2i(i32(row), 41));
        let dl_ = 26.0 * kk * (0.6 + hr);
        let sx = rpx.x / dl_ + hr * 7.0;
        let hs = hash2(vec2i(i32(floor(sx)), i32(row)));
        let fx = fract(sx);
        let taper = smoothstep(0.0, 0.15, fx) * smoothstep(1.0, 0.8, fx);
        let mp = vec2f(rpx.x + n.x * k * 1.6 + (hr - 0.5) * 9.0 * kk + (hs - 0.5) * 5.0 * kk,
                       wl - (row + 0.5) * rh - n.z * k * 0.8 + 2.0);
        let b = sample_boat(mp);
        if b.a > 0.002 {
            let fade = smoothstep(0.05, 0.25, hs) * taper * (1.0 - smoothstep(0.0, 0.5, rough)) * (1.0 - smoothstep(3.0, 16.0, g.wind.z)) * 0.85 * (0.55 + 0.45 * smoothstep(0.3, 0.6, vnoise(vec2f(rpx.x * 0.02, rpx.y * 0.25)))) * (1.0 - smoothstep(0.0, g.boat_misc.z * 12.0, k));
            refl = mix(refl, b.rgb / b.a, b.a * fade);
        }
    }

    // Body colour: light scattered in the water, a turquoise glow through backlit crests.
    let night = g.water.w;
    let sunl = g.sun_col.rgb * g.sun_col.w * max(g.sun.y, 0.0);
    var body = g.water.rgb * (g.ambient.rgb * 0.75 + sunl * 0.5 + g.moon_col.rgb * g.moon_col.w * 0.2);
    let sh = normalize(vec3f(g.sun.x, 0.0, g.sun.z) + vec3f(1e-5, 0.0, 0.0));
    let back = pow(max(dot(normalize(vec3f(d.x, 0.0, d.z)), sh), 0.0), 3.0);
    let hn = clamp(h / max(g.waves[2].w * 2.0 + g.waves[0].w, 0.05) * 0.5 + 0.5, 0.0, 1.0);
    body += vec3f(0.06, 0.42, 0.4) * sunl * smoothstep(0.55, 1.0, hn) * (0.25 + 0.75 * back) * 0.5;
    // Heavy seas: dark wave faces, lighter crests.
    let heavy = smoothstep(0.6, 2.5, g.waves[2].w * 4.0);
    body *= 1.0 + (hn - 0.5) * 0.9 * heavy;
    var col = mix(body, refl, fres);
    col *= 1.0 + (hn - 0.5) * 0.35 * heavy;
    // Contact shadow along the hull; the hull and keel faintly seen down through the water.
    col *= 1.0 - 0.3 * exp(-h_d / 0.7);
    let under = smoothstep(0.2, -0.2, h_dz + 0.15) * step(h_dxo, 0.01);
    col = mix(col, body * 0.55 + vec3f(0.0, 0.015, 0.02), under * 0.5 * (1.0 - fres));
    // Flat painted values: soft steps of about a third of a stop.
    let lum0 = max(dot(col, vec3f(0.3, 0.55, 0.15)), 1e-4);
    let ll = log2(lum0) * 3.0;
    let lq = floor(ll) + smoothstep(0.25, 0.75, fract(ll));
    col *= mix(1.0, exp2((lq - ll) / 3.0), 0.75);

    // Sun and moon glitter, only where the light gets through the clouds.
    let shin = mix(1800.0, 160.0, clamp(g.wx.x + rough, 0.0, 1.0));
    if g.sun.w > 0.001 {
        let cs = max(dot(r, g.sun.xyz), 0.0);
        if cs > 0.97 {
            let spec_s = pow(cs, shin) * shin * 0.012;
            // Painted glitter: crisp flecks over a soft path.
            let fl = smoothstep(0.25, 0.5, spec_s) * 1.6 + spec_s * 0.45;
            col += g.sun_col.rgb * vec3f(1.0, 0.95, 0.85) * fl * g.sun.w * sample_sky(g.sun.xyz).a * 2.0;
        }
    }
    if night > 0.01 && g.moon.y > -0.02 {
        let cm = max(dot(r, g.moon.xyz), 0.0);
        if cm > 0.97 {
            let shin_m = shin * 0.4;
            let spec_m0 = pow(cm, shin_m) * shin_m * 0.012;
            let spec_m = smoothstep(0.1, 0.28, spec_m0) * 1.2 + spec_m0 * 0.5;
            col += vec3f(0.8, 0.86, 1.0) * spec_m * g.moon.w * smoothstep(-0.02, 0.05, g.moon.y) * sample_sky(g.moon.xyz).a * night * 1.4;
        }
    }

    // Whitecaps on the wind-sea crests, foam streaks along the wind in a gale.
    let wc = g.wx2.z;
    let bp0 = g.boat_p.xz;
    let near_boat = length(p - bp0) < 140.0;
    var fnoise = 0.5;
    var fnoise2 = 0.5;
    if wc > 0.0 || near_boat {
        let qa = p + g.ripple_off.xy;
        fnoise = vnoise(qa * 1.1875);
        fnoise2 = vnoise(qa * 3.4375);
    }
    // Whitecaps: crisp patches where the swell's and the chop's crests meet,
    // lacy foam trailing them.
    let chop = hd / max(hd_w, 1e-4) * 0.5 + 0.5;
    let cap = crest * 0.45 + chop * 0.45 + fnoise * 0.3 + (fnoise2 - 0.5) * 0.2;
    var foam = wc * smoothstep(0.88 - 0.1 * wc, 0.92 - 0.1 * wc, cap);
    foam += wc * 0.45 * smoothstep(0.76 - 0.1 * wc, 0.9 - 0.1 * wc, cap) * smoothstep(0.35, 0.8, fnoise2);
    if g.wind.z > 18.0 {
        let wd = normalize(g.wind.xy + vec2f(1e-4, 0.0));
        let along = dot(p, wd);
        let across = dot(p, vec2f(-wd.y, wd.x));
        let streak = vnoise(vec2f(along * 0.05, across * 0.9));
        foam += smoothstep(16.0, 30.0, g.wind.z) * smoothstep(0.58, 0.8, streak) * 0.6 * (0.4 + 0.6 * fnoise);
    }

    // Where the hull meets the water: foam at the contact line itself (its distance came from
    // the real section in the boat's frame, so it rides up and down with heave, pitch and heel),
    // heavier at the bow and when the boat is moving, plus a thin lap even at rest.
    let spd = g.boat_p.w;
    let bf = normalize(g.boat_f.xz + vec2f(1e-4, 0.0));
    let al = dot(p - g.boat_p.xz, bf);
    let lat = dot(p - g.boat_p.xz, vec2f(-bf.y, bf.x));
    if h_d < 3.0 {
        let hl_t = clamp((al + 4.8) / 10.0, 0.0, 1.0);
        let bowk = smoothstep(0.55, 0.97, hl_t);
        let lap = vnoise(vec2f(al * 3.1 - g.res.z * 1.7, lat * 2.3 + g.res.z * 0.9));
        let sig = 0.15 + 0.08 * spd + 0.08 * bowk;
        let contact = exp(-h_d * h_d / (sig * sig)) * (0.12 + 0.75 * spd + 0.35 * bowk * spd + 0.25 * smoothstep(6.0, 25.0, g.wind.z));
        foam += contact * (0.45 + 0.75 * lap) * (0.6 + 0.4 * fnoise2);
        // The tongue of white climbing the topsides' edge, thickest where the water piles up.
        foam += exp(-h_dd * h_dd / (0.4 + 0.6 * bowk)) * spd * (0.15 + 0.5 * bowk) * smoothstep(0.35, 0.8, lap) * step(h_dxo, 0.01);
    }
    // The boat's wave system breaks where it is steep: foam follows the crest heights of the
    // very surface that was ray-marched (bow wave, Kelvin arms, the first stern crest).
    if spd > 0.01 && near_boat {
        let dsp = hull_disp(p);
        foam += smoothstep(0.035, 0.13, dsp) * spd * (0.55 + 0.7 * fnoise) * 1.3;
        // A churned trail in the lee of the transom, then the arms' lace.
        let behind = -(al + 4.6);
        if behind > -0.5 {
            let w = 0.9 + behind * 0.045;
            let trail = exp(-lat * lat / (w * w)) * exp(-behind / (18.0 + 50.0 * spd));
            let arm_c = abs(lat) - (0.25 + 0.36 * (behind + 10.0));
            let aw = 0.5 + 0.05 * behind;
            let arm = exp(-arm_c * arm_c / (aw * aw)) * exp(-behind / (25.0 + 45.0 * spd)) * smoothstep(0.0, 3.0, behind);
            foam += (trail * (0.5 + 1.1 * fnoise) + arm * 0.35 * (0.5 + fnoise2)) * spd * 1.3;
        }
    }
    // Rain: crowns and rings popping up all over the surface.
    if g.wx.z > 0.01 && fp < 0.25 {
        let rq = p * 1.6;
        let rc = floor(rq);
        let rh = hash2(vec2i(rc) + vec2i(3, 7));
        let rt = fract(g.res.z * 1.7 + rh);
        let rr = length(fract(rq) - 0.3 - 0.4 * vec2f(rh, fract(rh * 7.3)));
        let ring = smoothstep(0.05, 0.0, abs(rr - rt * 0.35)) * (1.0 - rt);
        foam += (ring * 0.7 + smoothstep(0.08, 0.0, rr) * smoothstep(0.25, 0.0, rt)) * min(g.wx.z * 0.4, 1.0) * step(rh, 0.25 + 0.5 * min(g.wx.z / 6.0, 1.0));
    }
    foam = clamp(foam, 0.0, 1.0);
    // Far foam blurs into a lighter sea instead of shimmering.
    let foam_far = smoothstep(0.0, 1.0, fp * 0.6);
    foam = mix(foam, foam * 0.35, foam_far);
    if g.res.w > 0.5 {
        return Sea(vec3f(foam, crest, wc), fres);
    }
    let amb_l = dot(g.ambient.rgb, vec3f(0.3, 0.55, 0.15));
    let foam_col = mix(vec3f(amb_l), g.ambient.rgb, 0.35) * 1.35 + g.sun_col.rgb * g.sun_col.w * max(g.sun.y, 0.0) * 0.9 + g.moon_col.rgb * g.moon_col.w * 0.6;
    col = mix(col, foam_col, smoothstep(0.08, 0.45, foam) * 0.9);

    // Lightning lights the sea.
    col += vec3f(0.75, 0.8, 1.0) * g.lightning.x * (0.06 + 0.3 * fres);

    // Distance haze into the horizon.
    let hzn = sample_sky(normalize(vec3f(d.x, 0.002, d.z)));
    let fog = 1.0 - exp(-dist * (0.00004 + g.wx2.y * 0.0007 + g.wx.z * 0.0004));
    col = mix(col, hzn.rgb, clamp(fog, 0.0, 1.0));
    return Sea(col, fres);
}

fn gull(px: vec2f, b: vec4f) -> f32 {
    if b.z <= 0.0 {
        return 0.0;
    }
    let l = (px - b.xy) / b.z;
    if abs(l.x) > 1.3 || abs(l.y) > 1.3 {
        return 0.0;
    }
    let x = clamp(abs(l.x), 0.0, 1.0);
    let lift = b.w;
    let y = -lift * 0.75 * x * (1.15 - x) * 2.0 + x * x * (0.25 + 0.25 * lift);
    let th = 0.1 * (1.0 - 0.75 * x) + 0.02;
    let dd = abs(l.y - y) - th;
    let aa = 1.2 / b.z;
    var a = smoothstep(aa, -aa, dd) * step(abs(l.x), 1.0);
    a = max(a, smoothstep(aa, -aa, length((l - vec2f(0.0, 0.03)) * vec2f(1.0, 1.6)) - 0.12));
    return a;
}

// The heavy part (sky and sea) at scale.x of the output's resolution; alpha
// is where stars may show (the clouds' transmittance, 0 on the water).
@fragment
fn fs_scene(@builtin(position) pos: vec4f) -> @location(0) vec4f {
    let px = pos.xy * g.scale.y;
    let d = cam_ray(px);
    // Painted: the scene is evaluated at the brush dab's centre (mostly).
    let dab = paint(px, horizon_y());
    let pe = clamp(mix(px, dab.c, 0.72), vec2f(0.0), g.res.xy);
    let de = cam_ray(pe);
    var col: vec3f;
    var mask = 0.0;
    let flash = g.lightning.x;
    if d.y >= 0.0 {
        let s = sample_sky(d);
        let sd = sample_sky(de);
        // Keep silhouettes and hard accents (cloud edges, sun, moon) where a dab would smear them.
        let dl = abs(dot(s.rgb - sd.rgb, vec3f(0.3, 0.55, 0.15)));
        col = mix(sd.rgb, s.rgb, max(smoothstep(0.04, 0.2, dl) * 0.85, 0.2));
        mask = s.a;
        col += vec3f(0.72, 0.76, 0.95) * flash * (0.12 + 0.9 * (1.0 - s.a)) * 0.9;
        col *= 1.0 + dab.tex;
    } else {
        let s = sea(select(de, d, de.y >= 0.0), pe, px);
        col = s.col * (1.0 + dab.tex);
        // The masthead light's streak on the water.
        if g.nav.z > 0.0 {
            let wl = g.boat_misc.x;
            let my = 2.0 * wl - g.nav.y;
            let dx = px.x - g.nav.x;
            let lc = select(select(vec3f(1.0, 0.95, 0.85), vec3f(1.0, 0.25, 0.2), g.nav.w > 0.5), vec3f(0.3, 1.0, 0.45), g.nav.w > 1.5);
            let path = smoothstep(wl + 2.0, wl + 10.0, px.y) * exp(-max(px.y - my, 0.0) / (g.nav.z * 20.0));
            let broken = smoothstep(0.45, 0.9, vnoise(vec2f(px.x * 0.05, px.y * 0.35 + g.res.z * 2.0)));
            col += lc * 0.5 * exp(-dx * dx / (g.nav.z * g.nav.z * 3.0)) * path * broken * g.boat_misc.w;
        }
    }
    return vec4f(col, mask);
}

// --- Paint: the scene re-laid as overlapping brush dabs ----------------------------
// Dabs live in a warped screen space whose cells shrink toward the horizon like the
// sea's own perspective (s = smin + k·e px tall, e = px from the horizon, 3:1 wide),
// so the foreground gets big flat strokes and the distance small dense ones. Each
// dab takes the scene's colour at its centre; the geometry is fixed, the colour flows.
fn horizon_y() -> f32 {
    let t = g.cam_pos.w;
    let ndc_y = -g.cam_fwd.y / (t * max(g.cam_up.y, 1e-3));
    return (1.0 - ndc_y) * 0.5 * g.res.y;
}
struct Dab {
    c: vec2f,  // the top dab's centre (output px), where the scene is evaluated
    tex: f32,  // bristle and rim shading
};
// The dabs cost no texture reads: the scene pass evaluates the sky and sea at
// the dab's centre instead of the pixel, so each dab is one flat-ish stroke.
fn paint(px: vec2f, hy: f32) -> Dab {
    let sky = px.y < hy;
    let side = select(1.0, -1.0, sky); // sea +, sky -
    let e = abs(px.y - hy);
    let smin = g.res.y * select(0.0026, 0.008, sky);
    let k = select(0.05, 0.035, sky);
    let s = smin + k * e;
    let aspect = select(5.6, 2.1, sky);
    let off = select(0.0, 517.0, sky);
    let uv = vec2f(px.x / (s * aspect), side * log(s) / k + off);
    // Stroke shape: sea strokes long thin dashes, sky strokes broader and freer.
    let stretch = select(vec2f(1.4, 1.45), vec2f(1.4, 1.35), sky);
    let tilt = select(0.25, 0.6, sky);
    // The 2x2 cells around the nearest corner (a dab rarely reaches further).
    let ci = floor(uv - 0.5);
    var z1 = -1.0;
    var c1 = vec2f(0.0);
    var r1 = 2.0;
    var l1 = vec2f(0.0);
    var near = 1e9;
    var nc = vec2f(0.0);
    for (var j = 0; j <= 1; j++) {
        for (var i = 0; i <= 1; i++) {
            let c = ci + vec2f(f32(i), f32(j));
            let ic = vec2i(c);
            let hv = pcg(u32(ic.x) * 1597u + u32(ic.y) * 51749u + 7u);
            let h1 = f32(hv & 1023u) / 1023.0;
            let h2 = f32((hv >> 10u) & 1023u) / 1023.0;
            let h3 = f32((hv >> 20u) & 1023u) / 1023.0;
            let ctr = c + 0.5 + (vec2f(h1, h2) - 0.5) * 0.4;
            let ang = (h1 - 0.5) * tilt;
            let cs = vec2f(1.0 - 0.5 * ang * ang, ang); // small angles
            let q = uv - ctr;
            let l = vec2f(q.x * cs.x + q.y * cs.y, -q.x * cs.y + q.y * cs.x) * stretch / (0.7 + 0.45 * h2);
            // Tapered: full at the loaded start, thin at the lifted end.
            let r = length(vec2f(l.x, l.y / max(1.0 - 0.3 * l.x, 0.1)));
            if r < near {
                near = r;
                nc = ctr;
            }
            if r < 1.0 && h3 > z1 {
                z1 = h3;
                c1 = ctr;
                r1 = r;
                l1 = l;
            }
        }
    }
    if z1 < 0.0 {
        c1 = nc;
        r1 = 0.0;
    }
    let sc_ = exp((c1.y - off) * side * k);
    let yc = hy + side * (max(sc_ - smin, 0.0) / k + 1.5);
    let xc = c1.x * sc_ * aspect;
    // Bristle streaks along the dab, a faint ridge at its rim.
    let seed = fract(c1.x * 0.618 + c1.y * 0.382);
    let br = 0.5 + 0.5 * sin(l1.y * 19.0 + seed * 40.0 + sin(l1.x * 2.0 + seed * 9.0) * 1.5);
    let rim = smoothstep(0.6, 0.97, r1);
    return Dab(vec2f(xc, yc), ((br - 0.5) * 0.07 + rim * 0.02) * select(1.0, 0.6, sky));
}

fn foam_tint() -> vec3f {
    let amb_l = dot(g.ambient.rgb, vec3f(0.3, 0.55, 0.15));
    return mix(vec3f(amb_l), g.ambient.rgb, 0.35) * 1.3 + g.sun_col.rgb * g.sun_col.w * max(g.sun.y, 0.0) * 0.85 + g.moon_col.rgb * g.moon_col.w * 0.5;
}

// The bow wave curling off the stem and the white wash astern, painted at the waterline.
fn boat_wash(px: vec2f, ppm: f32) -> f32 {
    let spd = g.boat_p.w;
    let bow = to_px(to_world(vec3f(5.0, 0.15, 0.0)));
    let stern = to_px(to_world(vec3f(-4.9, 0.1, 0.0)));
    let aft = normalize(stern.xy - bow.xy + vec2f(1e-3, 0.0));
    var a = 0.0;
    // Bow: a heap of white water around the stem, peeling aft along both sides.
    let qb = px - bow.xy;
    let along_b = dot(qb, aft) / ppm;
    let up_b = -qb.y / ppm;
    let hb_ = (0.25 + 0.45 * spd) * exp(-max(along_b, 0.0) / 2.5) * smoothstep(-0.8, 0.0, along_b);
    let n1 = vnoise(vec2f(px.x / ppm * 4.0 - g.res.z * 3.0, px.y / ppm * 7.0));
    a = max(a, smoothstep(0.05, -0.05, up_b - hb_ * (0.6 + 0.6 * n1)) * smoothstep(-0.25, 0.0, up_b + 0.15) * smoothstep(0.3, 0.55, n1 + 0.25) * smoothstep(-0.8, -0.3, along_b) * smoothstep(5.0, 2.0, along_b));
    // Stern: a churned, broken trail astern along the waterline.
    let qs = px - stern.xy;
    let along_s = dot(qs, aft) / ppm;
    let up_s = -qs.y / ppm;
    let ws = (0.12 + 0.2 * spd) * exp(-max(along_s, 0.0) / (3.0 + 6.0 * spd));
    let n2 = vnoise(vec2f(px.x / ppm * 3.0 + g.res.z * 1.5, px.y / ppm * 9.0));
    a = max(a, smoothstep(ws, ws * 0.3, abs(up_s + 0.03)) * smoothstep(-0.5, 0.3, along_s) * smoothstep(12.0, 3.0, along_s) * smoothstep(0.4, 0.6, n2 + 0.15));
    return a * spd * 0.9;
}

// World point to output px (x, y) and view depth z.
fn to_px(w: vec3f) -> vec3f {
    let rel = w - g.cam_pos.xyz;
    let z = dot(rel, g.cam_fwd.xyz);
    let x = dot(rel, g.cam_right.xyz) / (g.cam_pos.w * g.cam_right.w * z);
    let y = dot(rel, g.cam_up.xyz) / (g.cam_pos.w * z);
    return vec3f((x * 0.5 + 0.5) * g.res.x, (0.5 - y * 0.5) * g.res.y, z);
}

// Sidelight and stern light glows at night; spray bursting over the bow in a blow.
fn boat_fx(px: vec2f) -> vec3f {
    var c = vec3f(0.0);
    let bow = to_px(to_world(vec3f(4.9, 1.5, 0.0)));
    let near = length(px - bow.xy) < g.res.y * 0.2;
    let night = g.water.w;
    if night > 0.05 && near && g.boat_misc.w > 0.0 {
        let r = max(g.res.y / bow.z * 0.06, 1.2);
        let to_cam = g.cam_pos.xyz - to_world(vec3f(0.0, 1.5, 0.0));
        let ss = dot(to_cam, g.boat_s.xyz);
        let sf = dot(to_cam, g.boat_f.xyz);
        for (var k = 0; k < 3; k++) {
            var lp = vec3f(-4.72, 1.71, 0.04);
            var lc = vec3f(1.0, 0.95, 0.85);
            var vis = smoothstep(0.0, -2.0, sf);
            if k == 0 {
                lp = vec3f(4.79, 1.97, 0.36);
                lc = vec3f(0.3, 1.0, 0.45);
                vis = smoothstep(-0.5, 1.5, ss) * smoothstep(-3.0, 0.0, sf);
            } else if k == 1 {
                lp = vec3f(4.79, 1.97, -0.36);
                lc = vec3f(1.0, 0.22, 0.15);
                vis = smoothstep(0.5, -1.5, ss) * smoothstep(-3.0, 0.0, sf);
            }
            let q = to_px(to_world(lp));
            let dl = length(px - q.xy);
            c += lc * (exp(-dl * dl / (r * r)) * 1.2 + exp(-dl / (r * 4.0)) * 0.12) * vis * night;
        }
    }
    let windk = smoothstep(18.0, 32.0, g.wind.z);
    if windk > 0.0 && near && g.boat_p.w > 0.05 {
        let lee = sgn(g.sail.x);
        let period = 2.4;
        let t = g.res.z / period;
        let slot = floor(t);
        let tau = fract(t) * period;
        if hash1(slot * 1.7) < 0.35 + 0.6 * windk && tau < 1.3 {
            for (var i = 0; i < 14; i++) {
                let fi = f32(i) + slot * 17.0;
                let r1 = hash1(fi * 3.1);
                let r2 = hash1(fi * 5.7 + 1.0);
                let r3 = hash1(fi * 7.3 + 2.0);
                let p0 = vec3f(4.4 + 0.8 * r1, 1.3, -lee * (0.6 + 0.8 * r2));
                let v0 = vec3f(-1.0 - 2.5 * r3, 2.2 + 2.5 * r2, lee * (1.5 + 3.0 * r1)) * (0.6 + 0.6 * windk);
                let lp = p0 + v0 * tau + vec3f(0.0, -4.9 * tau * tau, 0.0);
                let q = to_px(to_world(lp));
                let rr = max(g.res.y / q.z * (0.05 + 0.08 * r3) * (1.0 + tau), 0.8);
                let dl = length(px - q.xy);
                let a = smoothstep(rr, rr * 0.3, dl) * (1.0 - tau / 1.3) * 0.75 * windk;
                c += (g.ambient.rgb * 1.1 + g.sun_col.rgb * g.sun_col.w * max(g.sun.y, 0.0) * 0.8) * a;
            }
        }
    }
    return c;
}

// --- The boat, repainted: its rendered layer re-laid as oriented brush strokes -----------
// Each stroke sits in a jittered cell, takes the layer's colour at its centre (broken a
// little warm or cool, lighter or darker), lies along the local edge (or along the hull
// where there is none) and has a ragged, sometimes soft, sometimes crisp edge. The
// silhouette is whatever the strokes cover, so no outline is ruler-straight. Thin
// things (mast, stays) are kept as drawn lines, broken and uneven like ink.
struct Stroke {
    col: vec3f,
    a: f32,
    z: f32,
};
// The boat's own 2D frame on screen: origin at the boat, rotated with the mast's lean.
// Stroke grid and wobble noise live here so they travel with the boat as it bobs and
// heels instead of sliding over it (screen-anchored they shimmered and spiked).
struct BFrame {
    o: vec2f,
    c: vec2f,
}
fn boat_frame() -> BFrame {
    let o = to_px(g.boat_p.xyz).xy;
    let ax = to_px(to_world(vec3f(0.0, 8.0, 0.0))).xy - o;
    let a = ax / max(length(ax), 1e-3);
    return BFrame(o, vec2f(-a.y, -a.x));
}
fn to_bf(f: BFrame, p: vec2f) -> vec2f {
    let d = p - f.o;
    return vec2f(f.c.x * d.x - f.c.y * d.y, f.c.x * d.y + f.c.y * d.x);
}
fn from_bf(f: BFrame, q: vec2f) -> vec2f {
    return f.o + vec2f(f.c.x * q.x + f.c.y * q.y, f.c.x * q.y - f.c.y * q.x);
}
fn blum(c: vec3f) -> f32 {
    return dot(c, vec3f(0.3, 0.55, 0.15));
}
fn boat_strokes(px: vec2f, bq: vec2f, bf: BFrame, cs: f32, fwd: vec2f, seed: u32, rf: vec4f, off: vec2f) -> Stroke {
    var top = Stroke(vec3f(0.0), 0.0, -1.0);
    var under = Stroke(vec3f(0.0), 0.0, -1.0);
    let ci = floor((bq + off) / cs);
    let r = cs * 0.45;
    for (var j = -1; j <= 1; j++) {
        for (var i = -1; i <= 1; i++) {
            let cell = ci + vec2f(f32(i), f32(j));
            let hv = pcg(u32(i32(cell.x) + 4096) * 1597u + u32(i32(cell.y) + 4096) * 51749u + seed);
            let h1 = f32(hv & 1023u) / 1023.0;
            let h2 = f32((hv >> 10u) & 1023u) / 1023.0;
            let h3 = f32((hv >> 20u) & 1023u) / 1023.0;
            let ctr = from_bf(bf, (cell + 0.5 + (vec2f(h1, h2) - 0.5) * 0.8) * cs - off);
            let s0 = sample_boat(ctr);
            if s0.a < 0.4 {
                continue;
            }
            // Strokes fade in and out with how solidly they sit in the mass rather than
            // popping at a threshold as a narrow sail swings past the cells.
            // Lie along the edge the centre is near: the gradient of coverage and value.
            // Which way does the mass run? Coverage both ways along four axes; the
            // stroke lies along the long axis (doubled angles), along the hull if none.
            // Only masses carry strokes (wire and spars stay drawn lines): the centre
            // must be covered a little way out both ways along both axes.
            let m0 = min(min(sample_boat(ctr + vec2f(r, 0.0)).a, sample_boat(ctr - vec2f(r, 0.0)).a), min(sample_boat(ctr + vec2f(0.0, r)).a, sample_boat(ctr - vec2f(0.0, r)).a));
            if m0 < 0.4 {
                continue;
            }
            let held = smoothstep(0.4, 0.65, s0.a) * smoothstep(0.4, 0.65, m0);
            // Which way does the mass run? Coverage both ways along four axes further
            // out; the stroke lies along the long axis (doubled angles), else the hull.
            let R = 18.0 * g.res.y / 1440.0;
            let f1 = vec2f(0.7071, 0.7071) * R;
            let f3 = vec2f(-0.7071, 0.7071) * R;
            let s0_ = min(sample_boat(ctr + vec2f(R, 0.0)).a, sample_boat(ctr - vec2f(R, 0.0)).a);
            let s2_ = min(sample_boat(ctr + vec2f(0.0, R)).a, sample_boat(ctr - vec2f(0.0, R)).a);
            let s1_ = min(sample_boat(ctr + f1).a, sample_boat(ctr - f1).a);
            let s3_ = min(sample_boat(ctr + f3).a, sample_boat(ctr - f3).a);
            let dv = vec2f(s0_ - s2_, s1_ - s3_);
            let mean = (s0_ + s1_ + s2_ + s3_) * 0.25;
            let edgy = smoothstep(0.1, 0.5, length(dv));
            let fd = vec2f(fwd.x * fwd.x - fwd.y * fwd.y, 2.0 * fwd.x * fwd.y) * 0.25;
            let ang2 = atan2(dv.y + fd.y, dv.x + fd.x);
            let ang = 0.5 * ang2 + (h3 - 0.5) * 0.5 * (1.0 - edgy * 0.6);
            let t = vec2f(cos(ang), sin(ang));
            let nn = vec2f(-t.y, t.x);
            let thick = clamp(mean - 0.5 * length(dv), 0.0, 1.0);
            // Small shapes (the helmsman, flags) get short dabs, not long strokes.
            let ext = max(max(s0_, s1_), max(s2_, s3_));
            let len = cs * (0.95 + 0.9 * h2) * mix(0.45, 1.0, ext);
            let wid = cs * (0.42 + 0.3 * h1) * mix(0.4, 1.0, thick);
            let q = px - ctr;
            var l = vec2f(dot(q, t) / len, dot(q, nn) / wid);
            // Loaded at the start, lifting and thinning at the end; a ragged rim.
            l.y /= max(1.0 - 0.35 * (l.x * 0.5 + 0.5), 0.2);
            let rag = vnoise(l * vec2f(2.5, 6.0) + vec2f(h1, h2) * 37.0) - 0.5;
            let rr = length(l) + rag * 0.35;
            let soft = mix(0.04, 0.45, h1 * h1);
            var cov = smoothstep(1.0, 1.0 - soft, rr);
            if cov <= 0.0 {
                continue;
            }
            // Broken colour: value and temperature shift per stroke, bristle streaks,
            // a thick-paint ridge catching light on the loaded side.
            var c = s0.rgb / s0.a;
            let lu = blum(c);
            // Strokes keep to their own value: one crossing into a much lighter or
            // darker shape thins out there, so the big shapes keep their design.
            if rf.a > 0.2 {
                cov *= mix(1.0, smoothstep(0.22, 0.07, abs(blum(rf.rgb / rf.a) - lu)), smoothstep(0.2, 0.6, rf.a));
            }
            let warm = (h3 - 0.5) * 0.12 + (lu - 0.45) * 0.1;
            c *= vec3f(1.0 + warm, 1.0 + warm * 0.2, 1.0 - warm * 0.9) * (0.93 + 0.14 * h2);
            let br = 0.5 + 0.5 * sin(l.y * 9.0 + h1 * 30.0 + sin(l.x * 2.3 + h2 * 9.0) * 1.2);
            c *= 1.0 + (br - 0.5) * 0.12;
            c *= 1.0 + 0.1 * smoothstep(0.5, 0.95, rr) * smoothstep(0.2, -0.6, l.y) * smoothstep(0.6, -0.4, l.x);
            let st = Stroke(c, cov * held * (0.82 + 0.18 * h2), h3);
            if h3 > top.z {
                under = top;
                top = st;
            } else if st.a > under.a {
                under = st;
            }
        }
    }
    // Underlayer first, the topmost stroke over it.
    let a = top.a + under.a * (1.0 - top.a);
    let c = (top.col * top.a + under.col * under.a * (1.0 - top.a)) / max(a, 1e-4);
    return Stroke(c, a, top.z);
}

fn boat_paint(px: vec2f) -> vec4f {
    let k = g.res.y / 1440.0;
    let bow = to_px(to_world(vec3f(5.0, 1.0, 0.0)));
    let stern = to_px(to_world(vec3f(-4.8, 1.0, 0.0)));
    var fwd = bow.xy - stern.xy;
    fwd = fwd / max(length(fwd), 1e-3);
    // Thin parts: the layer itself, nudged along a slow wobble, at an uneven weight.
    // Bowed a little like a hand-pulled line, with an uneven weight.
    // Noise is read in the boat's frame (bq) so the wobble rides with the boat.
    let bf = boat_frame();
    let bq = to_bf(bf, px);
    let wq = (vec2f(vnoise(bq * 0.006 + 3.0), vnoise(bq.yx * 0.006 + 11.0)) - 0.5) * 7.0
        + (vec2f(vnoise(bq * 0.05 + 7.0), vnoise(bq.yx * 0.05 + 2.0)) - 0.5) * 1.6;
    let wob = from_bf(bf, wq) - bf.o;
    let wt = smoothstep(0.35, 0.75, vnoise(bq * 0.02 + 19.0)) * 1.3 * k;
    let d0 = sample_boat(px + wob * k);
    let d1 = sample_boat(px + wob * k + (from_bf(bf, vec2f(wt, wt * 0.6)) - bf.o));
    let d = select(d0, d1, d1.a > d0.a);
    // Nothing to paint here? (Most of the box is open sky between the wires.)
    var reach = d.a + sample_boat(px).a;
    let rq = 20.0 * k;
    for (var i = 0; i < 8; i++) {
        let an = f32(i) * 0.7854;
        reach += sample_boat(px + vec2f(cos(an), sin(an)) * rq).a;
    }
    if reach <= 0.0 {
        return vec4f(0.0);
    }
    // Two coats: broad strokes blocking in the masses, smaller ones over them.
    let big = boat_strokes(px, bq, bf, 15.0 * k, fwd, 7u, d, vec2f(0.0));
    let small = boat_strokes(px, bq, bf, 8.0 * k, fwd, 191u, d, vec2f(3.0, 5.0));
    // Strokes stay inside the (wobbled) silhouette: dabs from cells along a narrow
    // edge-on sail otherwise poked out past it as horns that came and went.
    let sil = smoothstep(0.05, 0.5, max(d.a, sample_boat(px).a));
    let sa = small.a * 0.85 * sil;
    var a = sa + big.a * sil * (1.0 - sa);
    var c = (small.col * sa + big.col * big.a * (1.0 - sa)) / max(a, 1e-4);
    let o = 4.0 * k;
    let ox = from_bf(bf, vec2f(o, 0.0)) - bf.o;
    let oy = vec2f(-ox.y, ox.x);
    let ar = sample_boat(px + ox).a;
    let al = sample_boat(px - ox).a;
    let ad = sample_boat(px + oy).a;
    let au = sample_boat(px - oy).a;
    // Weights, not branches: a narrow fluttering sail sits right at these thresholds,
    // and switching between drawn line, edge band and scumble made it flicker.
    let tw = max(smoothstep(0.42, 0.18, max(ar, al)), smoothstep(0.42, 0.18, max(ad, au)));
    let iw = smoothstep(0.35, 0.65, min(min(ar, al), min(ad, au)));
    if d.a > 0.0 {
        let lc = d.rgb / d.a;
        // Thin parts: light slivers (a sail seen edge-on) stay solid; dark wire breaks up.
        let ink = mix(0.5, 1.0, smoothstep(0.2, 0.75, vnoise(bq * vec2f(0.03, 0.045) + 5.0)));
        let la_t = d.a * mix(ink, 1.0, smoothstep(0.45, 0.75, blum(lc)));
        // Edge band of a narrow light shape the strokes miss: lay the light in under
        // them, with the wobbled edge; dark edges stay lost.
        let la_e = d.a * 0.9 * smoothstep(0.5, 0.8, blum(lc)) * mix(0.6, 1.0, vnoise(bq * 0.04 + 23.0));
        // A hole between strokes inside a mass: scumble the layer's colour in.
        let s = sample_boat(px + vec2f(-wob.y, wob.x) * 1.5 * k);
        let fc = select(lc, (lc + s.rgb / max(s.a, 1e-4)) * 0.5, s.a > 0.5);
        let la_i = smoothstep(0.75, 0.95, d.a);
        let la = mix(mix(la_e, la_i, iw), la_t, tw);
        let fcol = mix(mix(lc, fc, iw), lc, tw);
        c = (c * a + fcol * la * (1.0 - a)) / max(a + la * (1.0 - a), 1e-4);
        a = a + la * (1.0 - a);
    }
    // Value design over polish: push the boat's darks and lights apart a little.
    c = max((c - 0.42) * 1.18 + 0.42, vec3f(0.0));
    return vec4f(c * a, a);
}

// Full resolution: the scaled scene, then everything that must stay crisp.
@fragment
fn fs_main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
    let px = pos.xy;
    let sc = textureSampleLevel(scene_tex, samp, px / g.res.xy, 0.0);
    var col = sc.rgb;
    let hy = horizon_y();
    let d = cam_ray(px);
    if d.y >= 0.0 {
        if g.ambient.w > 0.005 && sc.a > 0.01 {
            col += stars(d, px) * sc.a * g.ambient.w * (1.0 - g.wx2.y * 0.7);
            col += meteor(px, hy) * sc.a * smoothstep(0.3, 0.8, g.ambient.w);
        }
        // The bolt
        if g.lightning.y > 0.01 {
            var dm = 1e6;
            for (var i = 0; i < 7; i++) {
                dm = min(dm, seg_dist(px, bolt_pt(i), bolt_pt(i + 1)));
            }
            let w = g.lightning.z;
            col += vec3f(0.9, 0.93, 1.0) * g.lightning.y * (smoothstep(w * 1.5, w * 0.3, dm) * 1.6 + exp(-dm / (w * 10.0)) * 0.35);
        }
    }
    let flash = g.lightning.x;

    // The boat, with a thin dark painted outline where it meets the background.
    // Hand-drawn edges: the boat is sampled a pixel off here and there, in small
    // stroke-shaped cells, so its outlines wobble like brush edges.
    let bx = g.boat_box;
    let bw_ = bx.z - bx.x;
    var b = vec4f(0.0);
    if px.x > bx.x && px.x < bx.z && px.y > bx.y && px.y < bx.w {
        b = boat_paint(px);
    }
    col = col * (1.0 - b.a) + b.rgb;
    // Water lapping over the hull's lower edge: an irregular band of the sea in
    // front of it, with foam flecks, so the hull sits in the water rather than on it.
    let wl_y = g.boat_misc.x;
    let ppm = g.boat_misc.z;
    if b.a > 0.01 && px.y > wl_y - ppm * 1.5 && px.y < wl_y + ppm * 1.5 {
        var dist = 99.0;
        for (var k = 4; k >= 1; k--) {
            let o = f32(k) * ppm * 0.1;
            if sample_boat(px + vec2f(0.0, o)).a < 0.5 {
                dist = o;
            }
        }
        // Only the brush overshoot below the cut is laid back over with the real sea (whose
        // contact foam, bow wave and wake are already in scene_tex): the waterline itself is
        // the hull's true intersection with the surface, drawn in fs_boat.
        let xm = px.x / ppm;
        let band = ppm * (0.1 + 0.08 * vnoise(vec2f(xm * 1.3 - g.res.z * 0.9, g.res.z * 0.4)));
        col = mix(col, sc.rgb, smoothstep(band, band * 0.55, dist));
    }
    if px.x > g.boat_box.x - bw_ * 0.5 && px.x < g.boat_box.z + bw_ * 0.5 {
        col += boat_fx(px);
    }

    // Navigation light (masthead tricolour)
    if g.nav.z > 0.0 {
        let dl = length(px - g.nav.xy);
        let lc = select(select(vec3f(1.0, 0.95, 0.85), vec3f(1.0, 0.25, 0.2), g.nav.w > 0.5), vec3f(0.3, 1.0, 0.45), g.nav.w > 1.5);
        col += lc * (exp(-dl * dl / (g.nav.z * g.nav.z)) * 1.4 + exp(-dl / (g.nav.z * 4.0)) * 0.12) * g.boat_misc.w;
    }

    // Gulls
    for (var i = 0; i < 3; i++) {
        let a = gull(px, g.birds[i]);
        col = mix(col, mix(vec3f(0.1, 0.1, 0.12), g.ambient.rgb * 0.5, 0.25), a * 0.92);
    }

    // Rain: two layers of slanted streaks.
    let rain = g.wx.z;
    if rain > 0.01 {
        var rs = 0.0;
        for (var k = 0; k < 2; k++) {
            let fk = f32(k);
            let scale = (55.0 + fk * 35.0) / g.res.y;
            let x = (px.x + g.misc.y * px.y) * scale;
            let ci = floor(x);
            let h = hash1(ci * 7.0 + fk * 131.0);
            let speed = 3.0 + floor(h * 4.0) + fk * 2.0;
            let y = px.y / g.res.y * (3.0 + fk) - g.misc.x * speed + h * 13.0;
            let seg = fract(y);
            let lx = abs(fract(x) - 0.5);
            let thick = 0.05 + 0.04 * fk;
            let s = smoothstep(thick, 0.0, lx) * smoothstep(0.0, 0.15, seg) * smoothstep(0.55, 0.15, seg) * step(h, rain * 0.8 + 0.1);
            rs += s * (0.5 - fk * 0.2);
        }
        col = mix(col, g.horizon.rgb * 0.6 + vec3f(0.12) + vec3f(0.5) * flash, rs * rain * 0.35);
        col *= 1.0 - 0.12 * rain;
    }

    // --- Grade: painterly strokes, gentle S-curve, split tone, vignette, dither.
    let uv = px / g.res.xy;
    let rp = px / g.res.y;
    let brush = sin(rp.x * 31.0 + rp.y * 11.0 + sin(rp.y * 23.0 - rp.x * 5.0) * 2.5) * sin(rp.y * 97.0 + sin(rp.x * 13.0) * 3.0);
    col *= 1.0 + brush * 0.004;
    // Canvas: a fine weave and tooth shared by sky, sea and boat.
    let grain = hashp(vec2i(px * 0.5)) * 0.55 + (0.5 + 0.5 * sin(px.x * 1.25 + sin(px.y * 0.21) * 2.0)) * 0.45;
    col *= 1.0 + (grain - 0.5) * 0.06;
    col *= g.grade.x;
    let lum = dot(col, vec3f(0.3, 0.55, 0.15));
    col = mix(vec3f(lum), col, g.grade.y * 1.18);
    col = col / (1.0 + max(col - 0.85, vec3f(0.0)) * 0.9); // soft shoulder
    let shadows = 1.0 - smoothstep(0.0, 0.35, lum);
    col += vec3f(-0.005, 0.01, 0.025) * shadows;
    col = mix(col, col * vec3f(1.04, 1.0, 0.95), smoothstep(0.4, 0.9, lum));
    let vv = (uv - vec2f(0.5, 0.45)) * vec2f(0.9, 1.15);
    col *= 1.0 - g.grade.w * dot(vv, vv) * 1.2;
    // Interleaved gradient noise, shifted every frame.
    let ign = fract(52.9829189 * fract(dot(px + vec2f(g.grade.z * 5.588, g.grade.z * 2.123), vec2f(0.06711056, 0.00583715))));
    col = clamp(col + (ign - 0.5) / 255.0, vec3f(0.0), vec3f(1.0));
    return vec4f(col, 1.0);
}
