// Shrinks the full-resolution globe to the card: each card pixel is the
// area-weighted average of the scene pixels under it (a box filter, like a
// smooth-scaled screenshot), so the 1 px lines and dots dim with the scale
// instead of aliasing.

struct Params {
    src_size: vec2<f32>,
    dst_size: vec2<f32>,
};

@group(0) @binding(0) var src: texture_2d<f32>;
@group(0) @binding(1) var<uniform> params: Params;

@vertex
fn vs(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4<f32> {
    // One triangle covering the target
    let uv = vec2<f32>(f32((vi << 1u) & 2u), f32(vi & 2u));
    return vec4<f32>(uv * 2.0 - 1.0, 0.0, 1.0);
}

@fragment
fn fs(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let k = params.src_size / params.dst_size;
    let lo = (pos.xy - 0.5) * k;
    let hi = lo + k;
    let last = vec2<i32>(params.src_size) - 1;
    let x0 = i32(floor(lo.x));
    let x1 = i32(ceil(hi.x));
    let y0 = i32(floor(lo.y));
    let y1 = i32(ceil(hi.y));

    var sum = vec3<f32>(0.0);
    var weight = 0.0;
    for (var y = y0; y < y1; y++) {
        let wy = min(hi.y, f32(y + 1)) - max(lo.y, f32(y));
        for (var x = x0; x < x1; x++) {
            let w = wy * (min(hi.x, f32(x + 1)) - max(lo.x, f32(x)));
            if w > 0.0 {
                sum += textureLoad(src, clamp(vec2<i32>(x, y), vec2<i32>(0), last), 0).rgb * w;
                weight += w;
            }
        }
    }
    return vec4<f32>(sum / max(weight, 1e-6), 1.0);
}
