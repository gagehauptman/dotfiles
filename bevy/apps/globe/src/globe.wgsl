// Globe surface: flat ocean and land inks from the theme (a land mask), light pollution
// and weather sampled by latitude and longitude of the fragment (no UVs, so
// no seam), a soft terminator and a rim glow. Both layers are index textures
// looked up through palettes; a Mercator inset window at higher resolution
// replaces the global texture where it applies, with a soft edge.
#import bevy_pbr::forward_io::VertexOutput
#import bevy_pbr::mesh_view_bindings::view

struct GlobeParams {
    fill: vec4<f32>,      // linear rgb (the ocean), a unused
    land: vec4<f32>,      // land ink, a = strength over the fill
    rim: vec4<f32>,       // rgb glow colour, a = strength
    sun: vec4<f32>,       // xyz direction to the sun, w = night darkening
    line: vec4<f32>,      // day/night: terminator line rgb, a = opacity
    warm: vec4<f32>,      // twilight tint on the day side of the terminator, a = strength
    cool: vec4<f32>,      // and on the night side
    extra: vec4<f32>,     // x = day/night layer on
    layers: vec4<f32>,    // x = weather opacity, y = light pollution opacity, z = weather saturation
    inset_wx: vec4<f32>,  // west edge (rad), lon span (rad), Mercator y of north edge, y span; span 0 = none
    inset_lp: vec4<f32>,
};

@group(2) @binding(0) var<uniform> params: GlobeParams;
@group(2) @binding(1) var weather_tex: texture_2d<f32>;
@group(2) @binding(2) var weather_samp: sampler;
@group(2) @binding(3) var lp_tex: texture_2d<f32>;
@group(2) @binding(4) var lp_samp: sampler;
@group(2) @binding(5) var wxi_tex: texture_2d<f32>;
@group(2) @binding(6) var wxi_samp: sampler;
@group(2) @binding(7) var lpi_tex: texture_2d<f32>;
@group(2) @binding(8) var lpi_samp: sampler;
@group(2) @binding(9) var wx_lut: texture_2d<f32>;
@group(2) @binding(10) var wx_lut_samp: sampler;
@group(2) @binding(11) var lp_lut: texture_2d<f32>;
@group(2) @binding(12) var lp_lut_samp: sampler;
@group(2) @binding(13) var land_tex: texture_2d<f32>;
@group(2) @binding(14) var land_samp: sampler;

const PI: f32 = 3.14159265358979;

// Inset texture coordinates for a fragment, and how much the inset applies
// (fades out over its outermost 3%).
fn inset_uv(lat: f32, lon: f32, win: vec4<f32>) -> vec3<f32> {
    if (win.y <= 0.0) {
        return vec3<f32>(0.0);
    }
    var du = lon - win.x;
    du = du - 2.0 * PI * round(du / (2.0 * PI));
    let u = du / win.y;
    let y = (1.0 - log(tan(PI * 0.25 + lat * 0.5)) / PI) * 0.5;
    let v = (y - win.z) / win.w;
    let m = min(min(u, 1.0 - u), min(v, 1.0 - v));
    return vec3<f32>(u, v, smoothstep(0.0, 0.03, m));
}

// Palette entry for a normalised 8-bit index (texel centres, no bleeding)
fn lut(tex: texture_2d<f32>, samp: sampler, index: f32) -> vec4<f32> {
    return textureSampleLevel(tex, samp, vec2<f32>((index * 255.0 + 0.5) / 256.0, 0.5), 0.0);
}

@fragment
fn fragment(in: VertexOutput) -> @location(0) vec4<f32> {
    let n = normalize(in.world_position.xyz);
    let lat = asin(clamp(n.y, -1.0, 1.0));
    let lon = atan2(-n.z, n.x);
    let uv = vec2<f32>(lon / (2.0 * PI) + 0.5, 0.5 - lat / PI);

    // Flat inks: ocean, and land through the mask's 0.5 contour, a soft
    // edge at least a few km wide so it sits under the vector coast close in
    let m = textureSampleLevel(land_tex, land_samp, uv, 0.0).r;
    let w = max(fwidth(m) * 0.75, 0.06);
    var col = mix(params.fill.rgb, params.land.rgb, smoothstep(0.5 - w, 0.5 + w, m) * params.land.a);
    let day = smoothstep(-0.12, 0.12, dot(n, params.sun.xyz));
    col = col * (1.0 - params.sun.w * (1.0 - day));

    // Day/night layer: a twilight band either side of the terminator
    let sd = dot(n, params.sun.xyz);
    let dn = params.extra.x;
    let warm_band = exp(-pow((sd - 0.015) / 0.03, 2.0));
    let cool_band = exp(-pow((sd + 0.04) / 0.05, 2.0));
    col = mix(col, params.warm.rgb, params.warm.a * warm_band * dn);
    col = mix(col, params.cool.rgb, params.cool.a * cool_band * dn);

    // Light pollution reads as city lights: full on the night side, a hint by day
    var lp = lut(lp_lut, lp_lut_samp, textureSampleLevel(lp_tex, lp_samp, uv, 0.0).r);
    let li = inset_uv(lat, lon, params.inset_lp);
    if (li.z > 0.0) {
        lp = mix(lp, lut(lp_lut, lp_lut_samp, textureSampleLevel(lpi_tex, lpi_samp, li.xy, 0.0).r), li.z);
    }
    let boost = 1.0 + 0.3 * dn * (1.0 - day); // city lights read stronger in the dark
    col = mix(col, lp.rgb * boost, min(lp.a * boost, 1.0) * params.layers.y * mix(1.0, 0.25, day));

    // Weather: coldness index through the palette, alpha scaled by coverage
    let ws = textureSampleLevel(weather_tex, weather_samp, uv, 0.0);
    var wx = lut(wx_lut, wx_lut_samp, ws.r);
    wx.a = wx.a * ws.g;
    let wi = inset_uv(lat, lon, params.inset_wx);
    if (wi.z > 0.0) {
        let s = textureSampleLevel(wxi_tex, wxi_samp, wi.xy, 0.0);
        var w2 = lut(wx_lut, wx_lut_samp, s.r);
        w2.a = w2.a * s.g;
        wx = mix(wx, w2, wi.z);
    }
    let luma = dot(wx.rgb, vec3<f32>(0.2126, 0.7152, 0.0722));
    let wx_rgb = mix(vec3<f32>(luma), wx.rgb, params.layers.z);
    col = mix(col, wx_rgb, wx.a * params.layers.x);

    // Terminator: a line one pixel wide at any zoom along dot(n, sun) = 0
    let edge = 1.0 - smoothstep(0.0, 1.5 * max(fwidth(sd), 1e-5), abs(sd));
    col = mix(col, params.line.rgb, edge * params.line.a * dn);

    let v = normalize(view.world_position - in.world_position.xyz);
    let rim = pow(1.0 - clamp(dot(n, v), 0.0, 1.0), 3.0);
    col = col + params.rim.rgb * rim * params.rim.a;
    return vec4<f32>(col, 1.0);
}
