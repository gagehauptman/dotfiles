// Sputnik 1 over the turning Earth, as a Soviet space poster (after
// "Strana Oktyabrya - rodina kosmonavtiki"): a navy to burnt-orange airbrushed
// sky, a searchlight beam on the diagonal the satellite flies along, the
// Earth printed in flat cobalt and cream with halftone shadows, a graticule and a
// crisp limb line, hand-drawn orange orbits, Sputnik 1 itself printed the
// same way (a polished ball in flat inks, its bolted seam, hinge brackets
// and four swept arms), blocky lettering and print grain / misregistration.
// See lib.rs for the order of the draws.
struct G {
  res: vec4f,
  cam_pos: vec4f,
  cam_right: vec4f,
  cam_up: vec4f,
  cam_fwd: vec4f,
  earth: vec4f,
  light: vec4f,
  sat_px: vec4f,
  beam: vec4f,
  misc: vec4f,
  orb_p: vec4f,
  orb_q: vec4f,
  orb_h: vec4f,
  body: vec4f,
};
@group(0) @binding(0) var<uniform> g: G;
@group(0) @binding(1) var land_tex: texture_2d<f32>;
@group(0) @binding(2) var samp: sampler;
@group(0) @binding(3) var atlas_tex: texture_2d<f32>;

const PI = 3.14159265;

// The poster's inks.
const NAVY = vec3f(0.035, 0.050, 0.235);
const NAVY2 = vec3f(0.070, 0.075, 0.300);
const MAROON = vec3f(0.330, 0.095, 0.205);
const RED = vec3f(0.880, 0.240, 0.095);
const ORANGE = vec3f(0.975, 0.400, 0.150);
const CREAM = vec3f(0.990, 0.930, 0.820);
const PALE = vec3f(0.780, 0.880, 0.985);
const PINK = vec3f(0.960, 0.600, 0.800);
const INK_ORANGE = vec3f(1.000, 0.420, 0.140);

fn pcg(v: u32) -> u32 {
  let s = v * 747796405u + 2891336453u;
  let w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
  return (w >> 22u) ^ w;
}
fn h21(p: vec2f) -> f32 {
  let q = bitcast<vec2u>(vec2i(floor(p)));
  return f32(pcg(q.x + pcg(q.y))) / 4294967295.0;
}
fn vnoise(p: vec2f) -> f32 {
  let i = floor(p);
  let f = fract(p);
  let u = f * f * (3.0 - 2.0 * f);
  return mix(mix(h21(i), h21(i + vec2f(1.0, 0.0)), u.x), mix(h21(i + vec2f(0.0, 1.0)), h21(i + vec2f(1.0, 1.0)), u.x), u.y);
}
// Antialiased step at `e` for a value `x` that changes by fwidth(x) per pixel.
fn aa(e: f32, x: f32) -> f32 {
  let w = max(fwidth(x) * 0.75, 1e-5);
  return smoothstep(e - w, e + w, x);
}

struct FsIn {
  @builtin(position) pos: vec4f,
};

@vertex
fn vs_full(@builtin(vertex_index) vi: u32) -> FsIn {
  let c = vec2f(f32(vi & 1u), f32(vi >> 1u)) * 2.0 - 1.0;
  var o: FsIn;
  o.pos = vec4f(c, 0.0, 1.0);
  return o;
}

fn ray_dir(uvh: vec2f) -> vec3f {
  let th = g.cam_pos.w;
  return normalize(g.cam_fwd.xyz + (uvh.x - g.cam_right.w) * th * g.cam_right.xyz + (uvh.y - g.cam_up.w) * th * g.cam_up.xyz);
}

// Pixel -> half-heights from the screen centre, y up.
fn to_uvh(px: vec2f) -> vec2f {
  return vec2f((px.x - 0.5 * g.res.x) / (0.5 * g.res.y), (0.5 * g.res.y - px.y) / (0.5 * g.res.y));
}

fn backdrop(px: vec2f, uvh: vec2f, t: f32) -> vec3f {
  let H = g.res.y;
  let k = g.misc.z;
  // Airbrushed: the bands' edges wander a little across the width.
  let y = px.y / H + 0.025 * (vnoise(vec2f(px.x / H * 1.3 + 0.02 * t, 3.0)) - 0.5) - 0.04 * uvh.x / max(g.res.x / H, 1.0);
  var c = mix(NAVY, NAVY2, smoothstep(0.05, 0.55, y));
  c = mix(c, MAROON, smoothstep(0.50, 0.70, y));
  c = mix(c, RED, smoothstep(0.66, 0.86, y));
  c = mix(c, ORANGE, smoothstep(0.84, 1.02, y));
  // Uneven spray: low-frequency mottling.
  c *= 0.95 + 0.07 * vnoise(px / (0.22 * H) + vec2f(7.0, 1.0));

  // Stars: small cream marks, a few with a cross, in the navy only.
  let cell = 0.045 * H;
  let sc = px / cell;
  let ci = floor(sc);
  let hs = h21(ci + 17.0);
  if (hs > 0.70) {
    let o = vec2f(h21(ci + 3.1), h21(ci + 9.7)) * 0.7 + 0.15;
    let d = (sc - ci - o) * cell;
    let big = h21(ci + 5.3);
    let r = (0.7 + 1.0 * big) * k;
    let tw = 0.75 + 0.25 * sin(t * (0.3 + 0.9 * h21(ci + 1.9)) + 40.0 * h21(ci + 7.7));
    var s = 1.0 - smoothstep(r * 0.5, r + 0.7, length(d));
    if (big > 0.93) {
      let arm = (1.0 - smoothstep(0.35 * k, 0.9 * k, min(abs(d.x), abs(d.y)))) * (1.0 - smoothstep(0.0, 7.0 * k, max(abs(d.x), abs(d.y))));
      s = max(s, arm * 0.8);
    }
    c = mix(c, CREAM, s * tw * (0.5 + 0.5 * h21(ci + 2.2)) * (1.0 - smoothstep(0.30, 0.62, y)));
  }
  return c;
}

// The searchlight: from beyond the bottom left, up the diagonal the
// satellite flies along, passing behind it. Crisp edges like a cut stencil,
// airbrushed inside: white on its lower edge, pale blue across, a pink band
// printed slightly off register on its upper edge.
fn beam(c0: vec3f, uvh: vec2f, px: vec2f, t: f32) -> vec3f {
  let S = g.beam.xy;
  let a = g.beam.z;
  let dirb = vec2f(cos(a), sin(a));
  let nb = vec2f(-dirb.y, dirb.x); // to the beam's upper-left side
  let rel = uvh - S;
  let s = dot(rel, dirb);
  let q = dot(rel, nb);
  let px1 = 2.0 / g.res.y; // one pixel in half-heights
  let half = (0.205 + 0.075 * s) * g.beam.w;
  let ctr = -0.045; // the satellite sits a little above the axis
  let qq = (q - ctr) / half; // -1 lower edge .. 1 upper edge
  let edge = 1.6 * px1 / half;
  let inside = (1.0 - smoothstep(1.0 - edge, 1.0 + edge, qq)) * smoothstep(-1.0 - edge, -1.0 + edge, qq);
  // along: fades in from the bottom left, thins out past the top
  let along = smoothstep(-3.2, -1.6, s) * (1.0 - 0.45 * smoothstep(0.6, 2.4, s));
  var core = mix(vec3f(0.985, 0.990, 1.0), PALE, smoothstep(-0.85, 0.15, qq));
  core = mix(core, vec3f(0.86, 0.90, 0.99), smoothstep(0.15, 0.7, qq));
  // spray inside the stencil
  core *= 0.97 + 0.03 * vnoise(px / 9.0);
  var c = mix(c0, core, inside * along * 0.96);
  // the pink band, its own plate, offset by a couple of pixels
  let mis = 2.5 * px1 * g.misc.z;
  let qp = (q - ctr + mis) / half;
  let pink = smoothstep(0.62, 0.86, qp) * (1.0 - smoothstep(1.0 - edge, 1.0 + edge, qp - 0.04));
  c = mix(c, PINK, pink * along * 0.85);
  // a soft lavender fringe just outside, and a faint airbrushed halo
  let out_q = max(qq - 1.0, -qq - 1.0);
  let halo = exp(-max(out_q, 0.0) * 9.0) * (1.0 - inside);
  c = mix(c, mix(PINK, PALE, step(qq, 0.0)), halo * along * 0.22);
  return c;
}

struct Hit {
  cov: f32,
  col: vec3f,
  glow: vec3f,
};

// A printed halftone: dots on a screen turned 15 degrees, sized by `tone`
// (0 none .. 1 solid), about `cell` px apart; antialiased.
fn halftone(px: vec2f, tone: f32, cell: f32) -> f32 {
  let r = mat2x2f(0.966, 0.259, -0.259, 0.966) * px / cell;
  let f = fract(r) - 0.5;
  let d = length(f);
  let rad = sqrt(clamp(tone, 0.0, 1.0)) * 0.74;
  let w = 1.0 / cell;
  return 1.0 - smoothstep(rad - w, rad + w, d);
}

// The Earth, as a mid-century print: simplified cut-paper continents in
// cream on a cobalt sea, the light in two flat bands (peach and paler sea at
// half light), the night side laid in with coarse navy halftone dots, the
// land's red plate a little off register, a ruled graticule on the sea, a
// navy keyline at the coasts and a thin crisp limb line instead of a glow.
fn earth(uvh: vec2f, px: vec2f) -> Hit {
  var h: Hit;
  h.col = vec3f(0.0);
  let R = g.earth.x;
  let oc = g.cam_pos.xyz;
  let dir = ray_dir(uvh);
  let b = dot(oc, dir);
  let d2 = max(dot(oc, oc) - b * b, 0.0);
  let dmin = sqrt(d2);
  let dlimb = sqrt(max(dot(oc, oc) - R * R, 1.0));
  let pw = dlimb * g.cam_pos.w * 2.0 / g.res.y; // km per px at the limb
  let front = b < 0.0;
  h.cov = select(0.0, clamp((R - dmin) / pw + 0.5, 0.0, 1.0), front);
  let L = g.light.xyz;
  let Lw = normalize(L.x * g.cam_right.xyz + L.y * g.cam_up.xyz - L.z * g.cam_fwd.xyz);
  let k = g.misc.z;
  // Shaded everywhere (derivatives stay uniform), used only on the disc.
  let th = -b - sqrt(max(R * R - d2, 0.0));
  let n = normalize(oc + dir * th);
  let l = dot(n, Lw);
  let gm = g.earth.y;
  let ef = vec2f(cos(gm) * n.x + sin(gm) * n.y, -sin(gm) * n.x + cos(gm) * n.y);
  let lon = atan2(ef.y, ef.x);
  let lat = asin(clamp(n.z, -1.0, 1.0));
  let luv = vec2f(lon / (2.0 * PI) + 0.5, 0.5 - lat / PI);
  let m = textureSampleLevel(land_tex, samp, luv, 0.0).r;
  let land = aa(0.5, m);
  // The red plate: the land printed again a few pixels off register (down
  // and right, like the lettering's ghost), showing as a red edge.
  let mis = vec2f(3.5, -2.45) * k * 2.0 / g.res.y;
  let dir2 = ray_dir(uvh - mis);
  let b2 = dot(oc, dir2);
  let n2 = normalize(oc + dir2 * (-b2 - sqrt(max(R * R - max(dot(oc, oc) - b2 * b2, 0.0), 0.0))));
  let ef2 = vec2f(cos(gm) * n2.x + sin(gm) * n2.y, -sin(gm) * n2.x + cos(gm) * n2.y);
  let luv2 = vec2f(atan2(ef2.y, ef2.x) / (2.0 * PI) + 0.5, 0.5 - asin(clamp(n2.z, -1.0, 1.0)) / PI);
  let ghost = aa(0.5, textureSampleLevel(land_tex, samp, luv2, 0.0).r) * (1.0 - land);
  // The light in flat inks, as a poster prints it: a full-light band, a
  // half-light band, then the night laid over in coarse halftone.
  let full = aa(0.24, l);
  let half_lit = aa(0.02, l);
  let sea = mix(vec3f(0.085, 0.135, 0.400), vec3f(0.165, 0.255, 0.590), full);
  let ground = mix(vec3f(0.930, 0.640, 0.500), vec3f(0.985, 0.905, 0.765), full);
  var day = mix(sea, ground, land);
  day = mix(day, RED, ghost * 0.85);
  let night = mix(vec3f(0.035, 0.050, 0.200), vec3f(0.115, 0.115, 0.320), land);
  // past the terminator the dots grow from sparse to nearly solid
  let tone = (1.0 - half_lit) * mix(0.30, 0.92, smoothstep(0.0, -0.35, l));
  let dots = halftone(px, tone, 9.0 * k) * smoothstep(0.0, 0.02, tone);
  var c = mix(day, night, dots);
  // a ruled graticule every 15 degrees, on the sea only
  let gl = lat / (PI / 12.0);
  let gn = lon / (PI / 12.0);
  let fl = abs(fract(gl + 0.5) - 0.5) / max(fwidth(gl), 1e-5);
  let fmer = abs(fract(gn + 0.5) - 0.5) / max(fwidth(gn), 1e-5);
  let grid = max(1.0 - smoothstep(0.5, 1.3, fl), (1.0 - smoothstep(0.5, 1.3, fmer)) * smoothstep(0.08, 0.25, cos(lat)));
  c = mix(c, mix(vec3f(0.42, 0.50, 0.82), PALE, half_lit), grid * (0.16 + 0.16 * full) * (1.0 - land) * (1.0 - ghost));
  // coast: a navy keyline
  let coast = 1.0 - smoothstep(0.0, max(fwidth(m) * 1.6, 0.02), abs(m - 0.5));
  c = mix(c, NAVY, coast * 0.75 * half_lit);
  h.col = c;
  // The limb: a crisp hairline on the disc's edge, cream on the lit side,
  // a faint navy-blue on the night side; a narrow airbrushed haze outside.
  let gpx = (dmin - R) / pw / k;
  let pc = normalize(oc + dir * (-b));
  let rv = vec2f(dot(pc, g.cam_right.xyz), dot(pc, g.cam_up.xyz));
  let facing = clamp(dot(normalize(rv + vec2f(1e-6)), normalize(L.xy + vec2f(1e-6))) * 0.8 + 0.35, 0.0, 1.0);
  let line = 1.0 - smoothstep(0.6, 1.9, abs(gpx + 0.6));
  let lcol = mix(vec3f(0.36, 0.45, 0.80), vec3f(0.99, 0.95, 0.86), facing);
  h.col = mix(h.col, lcol, line * (0.35 + 0.6 * facing) * h.cov);
  let haze = exp(-max(gpx, 0.0) / 7.0) * facing * 0.16;
  h.glow = select(vec3f(0.0), (lcol * line * (0.35 + 0.6 * facing) + vec3f(0.70, 0.80, 1.0) * haze) * (1.0 - h.cov), front);
  return h;
}

@fragment
fn fs_sky(in: FsIn) -> @location(0) vec4f {
  let t = g.res.z;
  let px = in.pos.xy;
  let uvh = to_uvh(px);
  var col = backdrop(px, uvh, t);
  col = beam(col, uvh, px, t);
  let e = earth(uvh, px);
  // the glow is light: screen it over the sky and beam
  col = 1.0 - (1.0 - col) * (1.0 - clamp(e.glow, vec3f(0.0), vec3f(1.0)));
  col = mix(col, e.col, e.cov);
  // vignette, like a poster's darker printed edge
  let asp = g.res.x / g.res.y;
  let vq = uvh / vec2f(asp, 1.0);
  col *= 1.0 - 0.18 * smoothstep(0.55, 1.45, length(vq * vec2f(1.0, 0.8)));
  // print grain
  let grain = h21(px + vec2f(g.misc.y, g.misc.y * 0.7)) - 0.5;
  let fiber = vnoise(px * vec2f(0.9, 0.12) + g.misc.y) - 0.5;
  col += grain * 0.045 + fiber * 0.018;
  return vec4f(clamp(col, vec3f(0.0), vec3f(1.0)), 1.0);
}

// --- Lines ----------------------------------------------------------------------

struct LIn {
  @location(0) a: vec4f,
  @location(1) b: vec4f,
  @location(2) c: vec4f,
};
struct LOut {
  @builtin(position) pos: vec4f,
  @location(0) v: f32,
  @location(1) wp: vec3f,
  @location(2) prm: vec4f,
  @location(3) zv: f32,
  @location(4) hw: f32,
};

fn proj(p: vec3f) -> vec3f {
  let d = p - g.cam_pos.xyz;
  let zc = dot(d, g.cam_fwd.xyz);
  let th = g.cam_pos.w;
  let u = dot(d, g.cam_right.xyz) / (zc * th) + g.cam_right.w;
  let v = dot(d, g.cam_up.xyz) / (zc * th) + g.cam_up.w;
  return vec3f(0.5 * g.res.x + u * 0.5 * g.res.y, 0.5 * g.res.y - v * 0.5 * g.res.y, zc);
}

// A hand-drawn loop (kind 1) lives on the screen: its points are relative
// to its centre in half-heights; the centre is (a.z * aspect, b.z); it turns
// and breathes slowly.
fn loop_px(p: vec2f, cx: f32, cy: f32, seed: f32) -> vec3f {
  let t = g.res.z;
  let ang = t * (0.010 + 0.016 * (seed - 0.5)) + seed * 6.2831;
  let s = sin(ang);
  let c = cos(ang);
  let sq = 1.0 + 0.06 * sin(t * (0.021 + 0.01 * seed) + seed * 17.0);
  let q = vec2f(c * p.x - s * p.y, s * p.x + c * p.y) * vec2f(sq, 1.0 / sq);
  let asp = g.res.x / g.res.y;
  let cen = vec2f(cx * asp, cy) + 0.04 * vec2f(sin(t * 0.013 + seed * 9.0), cos(t * 0.011 + seed * 5.0));
  let u = cen + q;
  return vec3f(0.5 * g.res.x + u.x * 0.5 * g.res.y, 0.5 * g.res.y - u.y * 0.5 * g.res.y, 1.0);
}

// How far behind the satellite along the ring (0 = at it), as 0..1 trail strength.
fn trail_k(t: f32) -> f32 {
  let behind = fract(g.earth.z - t + 1.0);
  return 1.0 - smoothstep(0.0, g.misc.x, behind);
}

const NEAR = 400.0;

@vertex
fn vs_line(in: LIn, @builtin(vertex_index) vi: u32) -> LOut {
  let kind = in.c.x;
  let seed = in.c.w;
  var wa = in.a.xyz;
  var wb = in.b.xyz;
  var pa: vec3f;
  var pb: vec3f;
  if (kind > 0.5 && kind < 1.5) {
    pa = loop_px(in.a.xy, in.a.z, in.b.z, seed);
    pb = loop_px(in.b.xy, in.a.z, in.b.z, seed);
    wa = vec3f(0.0);
    wb = vec3f(0.0);
  } else {
    if (kind < 0.5) {
      wa = g.orb_p.xyz * in.a.x + g.orb_q.xyz * in.a.y;
      wb = g.orb_p.xyz * in.b.x + g.orb_q.xyz * in.b.y;
    }
    pa = proj(wa);
    pb = proj(wb);
  }
  var d = pb.xy - pa.xy;
  let ln = length(d);
  d = select(vec2f(1.0, 0.0), d / max(ln, 1e-5), ln > 1e-4);
  let n = vec2f(-d.y, d.x);
  let end = f32(vi >> 1u);
  let side = f32(vi & 1u) * 2.0 - 1.0;
  let t = mix(in.a.w, in.b.w, end);
  var wpx = in.c.y * g.misc.z;
  if (kind > 2.5 && kind < 3.5) {
    // antennas: tapered, their widths at either end in a.w and b.w
    wpx = mix(in.a.w, in.b.w, end) * g.misc.z;
  }
  if (kind > 0.5 && kind < 1.5) {
    // a pen stroke: swelling and thinning, tapered at both ends
    let sw = 0.75 + 0.35 * sin(t * 6.2831 * (2.0 + 3.0 * seed) + seed * 40.0);
    wpx *= sw * pow(max(sin(PI * t), 0.0), 0.35);
  }
  if (kind < 0.5) {
    wpx *= (0.85 + 0.25 * sin(t * 6.2831 * 5.0)) * (1.0 + 0.6 * trail_k(t));
  }
  if (kind > 3.5) {
    wpx *= 1.0 - 0.8 * t;
  }
  let hw = 0.5 * wpx + 0.9;
  let base = mix(pa, pb, end);
  var p = base.xy + d * (end * 2.0 - 1.0) * 0.8 + n * side * hw;
  // nothing behind (or right in front of) the camera
  if (kind < 0.5 || kind > 1.5) {
    if (pa.z < NEAR || pb.z < NEAR) {
      p = vec2f(-1e5);
    }
  }
  var o: LOut;
  o.pos = vec4f(p.x / g.res.x * 2.0 - 1.0, 1.0 - p.y / g.res.y * 2.0, 0.5, 1.0);
  o.v = side;
  o.wp = mix(wa, wb, end);
  o.prm = vec4f(kind, t, in.c.z, seed);
  o.zv = base.z;
  o.hw = hw;
  return o;
}

fn occluded(p: vec3f) -> bool {
  let oc = g.cam_pos.xyz;
  let dv = p - oc;
  let L = length(dv);
  let dir = dv / L;
  let b = dot(oc, dir);
  let R = g.earth.x;
  let disc = b * b - (dot(oc, oc) - R * R);
  if (disc < 0.0) { return false; }
  let th = -b - sqrt(disc);
  return th > 0.0 && th < L - 0.01 * R;
}

@fragment
fn fs_line(in: LOut) -> @location(0) vec4f {
  let kind = in.prm.x;
  let t = in.prm.y;
  let bright = in.prm.z;
  let seed = in.prm.w;
  let hw0 = in.hw - 0.9;
  let across = abs(in.v) * in.hw;
  var a = clamp(hw0 - across + 0.5, 0.0, 1.0);
  var col = INK_ORANGE;
  if (kind < 0.5) {
    // the real orbit: a confident orange-red stroke, cream where it has just been flown
    let k = trail_k(t);
    col = mix(vec3f(1.0, 0.36, 0.10), vec3f(1.0, 0.86, 0.72), k * k);
    a *= bright;
    if (occluded(in.wp)) { a = 0.0; }
  } else if (kind < 1.5) {
    col = mix(vec3f(1.0, 0.44, 0.16), vec3f(0.98, 0.33, 0.12), seed);
    a *= g.misc.w * bright * (0.85 + 0.15 * vnoise(vec2f(t * 25.0 + seed * 100.0, 3.0)));
  } else if (kind < 2.5) {
    // ground track: dashed, cream-orange, ahead; solid behind, fading
    col = vec3f(1.0, 0.62, 0.38);
    if (t > 0.0) {
      a *= 0.6 * step(0.45, fract(t * 70.0)) * (1.0 - smoothstep(0.2, 0.45, t));
    } else {
      a *= 0.75 * pow(clamp(1.0 + t / 0.6, 0.0, 1.0), 1.5);
    }
    if (occluded(in.wp)) { a = 0.0; }
  } else if (kind < 3.5) {
    // the satellite's arms and fittings, printed like its shell: two flat
    // tones split a little off centre (lit from the upper left, side +1),
    // a crisp cream stripe along the lit side and a navy keyline along the
    // other; the whips (seed 0) in pale silver, the hinge knuckles,
    // ferrules and collars (1) in the darker fitting ink, the bracket
    // plates (2) in the shell's own ink
    let v = in.v;
    var lit = vec3f(0.84, 0.87, 0.95);
    var shade = vec3f(0.50, 0.52, 0.70);
    if (seed > 1.5) {
      lit = vec3f(0.82, 0.85, 0.94);
      shade = vec3f(0.50, 0.52, 0.70);
    } else if (seed > 0.5) {
      lit = vec3f(0.60, 0.62, 0.76);
      shade = vec3f(0.28, 0.28, 0.44);
    }
    var body = mix(shade, lit, aa(-0.15, v));
    body = mix(body, CREAM, aa(0.42, v) * (1.0 - aa(0.86, v)));
    col = mix(body, NAVY2, 1.0 - aa(-0.80, v));
    let c = g.sat_px.xy;
    let inball = distance(in.pos.xy, c) < g.earth.w * 0.99;
    if (inball && in.zv > g.sat_px.z) { a = 0.0; }
    // the ball isn't to scale, so the rods go with it behind the Earth
    a *= g.light.w;
  } else {
    // speed streaks: pink to lavender, fading out behind
    col = mix(vec3f(1.0, 0.80, 0.92), vec3f(0.70, 0.60, 0.98), t);
    a *= pow(1.0 - t, 1.2) * 0.8 * bright;
    if (occluded(in.wp)) { a = 0.0; }
  }
  return vec4f(col * a, a);
}

// --- The ball ---------------------------------------------------------------------

struct BOut {
  @builtin(position) pos: vec4f,
  @location(0) q: vec2f,
};

const BALL_QUAD = 1.7;

@vertex
fn vs_ball(@builtin(vertex_index) vi: u32) -> BOut {
  let c = vec2f(f32(vi & 1u), f32(vi >> 1u)) * 2.0 - 1.0;
  // room round the ball for its halo
  let r = g.earth.w * BALL_QUAD;
  let p = g.sat_px.xy + c * r;
  var o: BOut;
  o.pos = vec4f(p.x / g.res.x * 2.0 - 1.0, 1.0 - p.y / g.res.y * 2.0, 0.5, 1.0);
  o.q = c * BALL_QUAD;
  return o;
}

// A small round flange plate on the shell, bolted: `n` the shell normal,
// `fc` the plate's centre, `rad` its angular radius, `bolts` round it at
// `brad`. Returns (plate, its keyline, the bolt heads).
fn flange(n: vec3f, fc: vec3f, tu: vec3f, rad: f32, bolts: f32, brad: f32) -> vec3f {
  let fd = acos(clamp(dot(n, fc), -1.0, 1.0));
  let fw = fwidth(fd) + 1e-4;
  let plate = 1.0 - smoothstep(rad, rad + fw, fd);
  let edge = 1.0 - smoothstep(0.0, fw * 1.4, abs(fd - rad));
  let tuu = normalize(tu - fc * dot(fc, tu) + vec3f(1e-5));
  let tv = cross(fc, tuu);
  let ang = atan2(dot(n, tv), dot(n, tuu));
  let pitch = 2.0 * PI / bolts;
  let bd = length(vec2f(fd - brad, (fract(ang / pitch + 0.5) - 0.5) * pitch * brad));
  let bw = fwidth(bd) + 1e-4;
  let bolt = (1.0 - smoothstep(0.0085, 0.0085 + bw, bd)) * plate;
  return vec3f(plate, edge, bolt);
}

@fragment
fn fs_ball(in: BOut) -> @location(0) vec4f {
  let r2 = dot(in.q, in.q);
  let rpx = g.earth.w;
  let cov = clamp((1.0 - sqrt(r2)) * rpx + 0.5, 0.0, 1.0);
  let q = in.q;
  let nz = sqrt(max(1.0 - r2, 0.0));
  let n = vec3f(q.x, -q.y, nz);
  let k = g.misc.z;
  let px = in.pos.xy;
  // The polished shell as the poster prints it, in flat inks: the key light
  // (upper left, the beam's side) cuts it into a cream-white full light, a
  // pale silver half light and a grey-violet shade laid in with coarse navy
  // halftone dots like the Earth's night side; the beam mirrored across it
  // as a pale band; a hard-edged specular stencil; the Earth mirrored in
  // its lower right as a flat cobalt crescent with a pale rim, the way a
  // chromed ball is drawn; warm bounce off the bottom edge from the orange
  // sky.
  let Lk = normalize(vec3f(-0.55, 0.62, 0.56));
  let ndl = dot(n, Lk);
  let full = aa(0.42, ndl);
  let half_lit = aa(-0.05, ndl);
  var c = mix(vec3f(0.42, 0.42, 0.58), vec3f(0.74, 0.76, 0.86), half_lit);
  c = mix(c, vec3f(0.91, 0.92, 0.96), full);
  let tone = (1.0 - half_lit) * mix(0.18, 0.62, smoothstep(-0.05, -0.75, ndl));
  let dots = halftone(px, tone, 5.5 * k) * smoothstep(0.0, 0.02, tone);
  c = mix(c, vec3f(0.15, 0.15, 0.36), dots);
  let rf = reflect(vec3f(0.0, 0.0, -1.0), n);
  let beam_dir = normalize(vec3f(-cos(g.beam.z), -sin(g.beam.z), 0.35));
  let bd = dot(rf, beam_dir);
  c = mix(c, PALE, aa(0.60, bd) * (1.0 - 0.5 * aa(0.94, bd)) * 0.55);
  let cres_d = 1.0 - length(q - vec2f(1.15, 1.15));
  let cres = aa(0.0, cres_d);
  let cres_in = aa(0.05, cres_d);
  c = mix(c, vec3f(0.17, 0.26, 0.60), cres * 0.85);
  c = mix(c, PALE, (cres - cres_in) * 0.75);
  c = mix(c, vec3f(1.0, 0.99, 0.96), aa(0.955, dot(rf, Lk)));
  c = mix(c, vec3f(0.95, 0.52, 0.30), aa(0.55, -n.y) * (1.0 - full) * (1.0 - cres) * 0.28);
  // The body frame lib.rs turns the ball and its antennas with: the axis
  // (front pole forward) and b1, b2 square to it.
  let vh = normalize(vec3f(g.orb_p.w, g.orb_q.w, g.orb_h.w) + vec3f(1e-5));
  let b1 = normalize(g.body.xyz - vh * dot(g.body.xyz, vh) + vec3f(1e-5));
  let b2 = cross(vh, b1);
  // The joint of the two half-shells: their joining frames' strap, a narrow
  // raised band on the equator (res.w) a touch lighter than the shell with
  // a navy keyline each side, and its 36 studs, dark heads every 10 degrees
  // round it.
  let sd = dot(n, vh) - g.res.w;
  let sw = fwidth(sd) + 1e-4;
  let hwid = 0.026;
  let strap = aa(-hwid, sd) * (1.0 - aa(hwid, sd));
  let edge = 1.0 - smoothstep(0.0, sw * 1.2, abs(abs(sd) - hwid));
  c = mix(c, min(c * 1.10 + vec3f(0.05), vec3f(1.0)), strap * 0.7);
  c = mix(c, NAVY2, edge * 0.38);
  let phi = atan2(dot(n, b2), dot(n, b1));
  let pitch = 2.0 * PI / 36.0;
  let dd = length(vec2f(sd, (fract(phi / pitch + 0.5) - 0.5) * pitch));
  let dw = fwidth(dd) + 1e-4;
  let stud = 1.0 - smoothstep(0.011, 0.011 + dw, dd);
  c = mix(c, NAVY2, stud * 0.45);
  // The filling valve's flange, a small round bolted plate on the front
  // half-shell midway between two brackets, 25 degrees ahead of the seam;
  // the test connector's on the back half-shell, 90 degrees round.
  let f1 = flange(n, normalize(vh * sin(0.44) + b1 * cos(0.44)), vh, 0.12, 6.0, 0.08);
  let f2 = flange(n, normalize(b2 * cos(0.52) - vh * sin(0.52)), vh, 0.10, 6.0, 0.065);
  let fl = max(f1, f2);
  c = mix(c, mix(c * 0.94, PALE, 0.08), fl.x * 0.6);
  c = mix(c, NAVY2, fl.y * 0.42);
  c = mix(c, NAVY2, fl.z * 0.5);
  // hidden by the Earth where it passes behind the limb
  let uvh = to_uvh(in.pos.xy);
  let dir = ray_dir(uvh);
  let oc = g.cam_pos.xyz;
  let bb = dot(oc, dir);
  let d2 = max(dot(oc, oc) - bb * bb, 0.0);
  let R = g.earth.x;
  let pw = sqrt(max(dot(oc, oc) - R * R, 1.0)) * g.cam_pos.w * 2.0 / g.res.y;
  let ecov = clamp((R - sqrt(d2)) / pw + 0.5, 0.0, 1.0);
  let th = -bb - sqrt(max(R * R - d2, 0.0));
  let behind = select(0.0, ecov, bb < 0.0 && th * dot(dir, g.cam_fwd.xyz) < g.sat_px.z);
  // a thin navy keyline round the silhouette, so it reads as a cut shape
  let rr = sqrt(r2);
  c = mix(c, NAVY2, smoothstep(1.0 - 2.4 / rpx, 1.0 - 0.6 / rpx, rr) * 0.75);
  let a = cov * (1.0 - behind);
  // The red plate: the disc printed again a few pixels off register (down
  // and right, like the land's and the lettering's ghosts), showing as a
  // red sliver along the lower right edge.
  let mis = vec2f(3.5, 2.45) * k / rpx;
  let gcov = clamp((1.0 - length(q - mis)) * rpx + 0.5, 0.0, 1.0);
  let ghost = gcov * (1.0 - cov) * (1.0 - behind) * 0.85;
  // a soft warm-white halo round it, added on (no alpha), breathing with the beam
  let halo = exp(-(rr - 1.0) * 6.0) * smoothstep(1.0, 1.04, rr) * (1.0 - smoothstep(BALL_QUAD - 0.25, BALL_QUAD, rr));
  let glow = vec3f(1.0, 0.86, 0.74) * halo * 0.22 * g.beam.w * (1.0 - behind) * (1.0 - cov) * (1.0 - ghost);
  return vec4f(c * a + RED * ghost + glow, a + ghost);
}

// --- Text -------------------------------------------------------------------------

struct TIn {
  @location(0) rect: vec4f,
  @location(1) uv: vec4f,
  @location(2) color: vec4f,
};
struct TOut {
  @builtin(position) pos: vec4f,
  @location(0) uv: vec2f,
  @location(1) color: vec4f,
  @location(2) solid: f32,
};

@vertex
fn vs_text(in: TIn, @builtin(vertex_index) vi: u32) -> TOut {
  let c = vec2f(f32(vi & 1u), f32(vi >> 1u));
  let p = in.rect.xy + c * in.rect.zw;
  var o: TOut;
  o.pos = vec4f(p.x / g.res.x * 2.0 - 1.0, 1.0 - p.y / g.res.y * 2.0, 0.5, 1.0);
  o.uv = mix(in.uv.xy, in.uv.zw, c);
  // A glyph with an empty uv box is a solid bar (rules, blocks).
  o.solid = select(0.0, 1.0, in.uv.x == in.uv.z && in.uv.y == in.uv.w);
  o.color = in.color;
  return o;
}

@fragment
fn fs_text(in: TOut) -> @location(0) vec4f {
  let s = textureSample(atlas_tex, samp, in.uv).r;
  let w = clamp(fwidth(s) * 0.75, 0.05, 0.5);
  var a = mix(smoothstep(0.5 - w, 0.5 + w, s), 1.0, in.solid);
  // worn ink
  a *= 0.88 + 0.12 * h21(in.pos.xy * 0.7 + 31.0);
  a *= in.color.a;
  return vec4f(in.color.rgb * a, a);
}
