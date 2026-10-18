//! The sailboat wallpaper, live, for its entry in the wallpaper selector and
//! behind the lock screen. It draws the wallpaper's own scene
//! (`sailboat_scene`: the same shader, boat, sky and weather as the renderer in
//! scripts/wallpaper/bins/spinning_globe, see its sailboat.rs).
//!
//! The scene's marks are sized in screen pixels (star dots, paint strokes,
//! grain, foam flecks), so it only looks like the wallpaper when it is drawn
//! at the monitor's resolution. When the card is smaller than `output` (the
//! selector), the scene is therefore rendered into a private target of the
//! monitor's height (width from the card's aspect) and box-filtered down into
//! the card, which is what a screenshot of the wallpaper scaled to the card
//! would show. With no `output`, or a card at least that tall (the lock
//! screen), it is drawn straight into the card.
//!
//! Options: `fps` (default 30, like the wallpaper); `time`, unix seconds to
//! freeze the clock at (for comparing renders); `output` `[w, h]`, the
//! monitor's size in pixels. Weather and forced states come from the same
//! cache and SAILBOAT_* variables as the wallpaper.
//!
//! Bevy only hosts it here: the only camera is inactive, and a render-world
//! system encodes the scene's three passes straight on wgpu into the card's
//! image.
use std::time::{Duration, Instant, SystemTime};

use bevy::prelude::*;
use bevy::render::render_asset::RenderAssets;
use bevy::render::renderer::{RenderDevice, RenderQueue};
use bevy::render::texture::GpuImage;
use bevy::render::{Extract, ExtractSchedule, Render, RenderApp, RenderSet};
use quickshell_bevy::prelude::*;
use sailboat_scene::{box_size, bytemuck, scene_size, sky_size, BoatVertex, Globals, World};
use wgpu::util::DeviceExt;

// Qt reads the card as plain RGBA8; the scene wants 8-bit non-sRGB.
const FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba8Unorm;
// As in the wallpaper's sailboat.rs.
const SKY_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba16Float;
const SCENE_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba16Float;
const BOAT_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba8Unorm;
const DEPTH_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Depth32Float;
const MSAA: u32 = 4;

pub struct Sailboat;

impl Plugin for Sailboat {
    fn build(&self, app: &mut App) {
        app.add_systems(Startup, setup);
        if let Some(render_app) = app.get_sub_app_mut(RenderApp) {
            render_app.add_systems(ExtractSchedule, extract).add_systems(Render, draw.in_set(RenderSet::Render));
        }
    }
}
quickshell_bevy::widget!(Sailboat);

#[derive(Resource, Clone, Copy)]
struct Settings {
    interval: Duration,
    time: Option<f64>,
    /// The monitor's height in pixels, if the card is a preview of it.
    output_h: Option<u32>,
}

/// Size the scene is rendered at for a card of `card`: the monitor's height
/// (and the card's aspect) when the card is a smaller preview, else the card.
fn render_size(card: (u32, u32), output_h: Option<u32>) -> (u32, u32) {
    match output_h {
        Some(oh) if oh > card.1 => (((oh as f64 * card.0 as f64 / card.1 as f64).round() as u32).max(1), oh),
        _ => card,
    }
}

fn setup(mut commands: Commands, options: Res<WidgetOptions>) {
    let json: serde_json::Value = serde_json::from_str(&options.0).unwrap_or_default();
    let fps = json["fps"].as_f64().filter(|&f| f > 0.0).unwrap_or(30.0);
    let output_h = json["output"][1].as_u64().filter(|&h| h > 0).map(|h| h.min(4320) as u32);
    commands.insert_resource(Settings { interval: Duration::from_secs_f64(1.0 / fps), time: json["time"].as_f64(), output_h });
    // Claims the card so the harness doesn't add its default 3D camera; being
    // inactive, Bevy renders nothing itself.
    commands.spawn((Camera2d, WidgetCamera, Camera { is_active: false, ..default() }));
}

/// What the render world needs for this frame.
#[derive(Resource)]
struct FrameInfo {
    target: Handle<Image>,
    size: (u32, u32),
    settings: Settings,
}

fn extract(mut commands: Commands, target: Extract<Res<WidgetTarget>>, settings: Extract<Option<Res<Settings>>>) {
    let Some(settings) = settings.as_deref() else { return };
    commands.insert_resource(FrameInfo { target: target.handle.clone(), size: (target.width, target.height), settings: *settings });
}

/// Per-size textures, remade when the card (or the monitor's size) changes.
struct Targets {
    /// The card, and the size the scene is drawn at.
    size: ((u32, u32), (u32, u32)),
    /// Monitor-size colour target and the bind group that shrinks it into the
    /// card, when the scene isn't drawn straight into the card.
    shrink: Option<(wgpu::TextureView, wgpu::BindGroup)>,
    sky: wgpu::TextureView,
    boat_ms: wgpu::TextureView,
    boat: wgpu::TextureView,
    depth: wgpu::TextureView,
    scene: wgpu::TextureView,
    main_bind: wgpu::BindGroup,
    final_bind: wgpu::BindGroup,
}

/// GPU state, made on the first frame.
struct Gpu {
    world: World,
    main_layout: wgpu::BindGroupLayout,
    final_layout: wgpu::BindGroupLayout,
    sampler: wgpu::Sampler,
    /// The star catalogue's cell grid and records (scene crate `stars`), read by the composite pass.
    star_buf: wgpu::Buffer,
    sky: wgpu::RenderPipeline,
    boat: wgpu::RenderPipeline,
    scene: wgpu::RenderPipeline,
    composite: wgpu::RenderPipeline,
    blit_layout: wgpu::BindGroupLayout,
    blit: wgpu::RenderPipeline,
    vertices: wgpu::Buffer,
    indices: wgpu::Buffer,
    index_count: u32,
    uniform: wgpu::Buffer,
    simple_bind: wgpu::BindGroup,
    targets: Option<Targets>,
    last_sky: Option<f64>,
    last: Option<(Instant, Handle<Image>, (u32, u32))>,
}

fn draw(
    info: Option<Res<FrameInfo>>,
    images: Res<RenderAssets<GpuImage>>,
    device: Res<RenderDevice>,
    queue: Res<RenderQueue>,
    mut gpu: Local<Option<Gpu>>,
) {
    let Some(info) = info else { return };
    let Some(target) = images.get(&info.target) else { return };
    let (w, h) = info.size;
    if w == 0 || h == 0 {
        return;
    }
    let device = device.wgpu_device();
    let queue: &wgpu::Queue = &queue;
    let gpu = gpu.get_or_insert_with(|| Gpu::new(device));

    // Frame cap: the card's image keeps the last frame in between. A new
    // target (resize) always gets drawn.
    let clock = Instant::now();
    if let Some((at, handle, size)) = &gpu.last {
        if *handle == info.target && *size == info.size && clock.duration_since(*at) < info.settings.interval {
            return;
        }
    }
    gpu.last = Some((clock, info.target.clone(), info.size));

    let now = info.settings.time.unwrap_or_else(|| sailboat_scene::unix_secs(SystemTime::now()));
    gpu.world.update(now);
    let (rw, rh) = render_size((w, h), info.settings.output_h);
    let globals = gpu.world.globals(rw, rh);
    let mut sky_due = gpu.world.sky_due(gpu.last_sky, now);
    if gpu.targets.as_ref().is_none_or(|t| t.size != ((w, h), (rw, rh))) {
        gpu.targets = Some(gpu.make_targets(device, (w, h), (rw, rh)));
        sky_due = true;
    }
    queue.write_buffer(&gpu.uniform, 0, bytemuck::bytes_of::<Globals>(&globals));
    if sky_due {
        gpu.last_sky = Some(now);
    }

    let t = gpu.targets.as_ref().unwrap();
    let card_view = target.texture.create_view(&wgpu::TextureViewDescriptor { format: Some(FORMAT), ..Default::default() });
    let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("sailboat") });
    if sky_due {
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("sailboat sky"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &t.sky,
                resolve_target: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color::BLACK), store: wgpu::StoreOp::Store },
            })],
            ..Default::default()
        });
        pass.set_pipeline(&gpu.sky);
        pass.set_bind_group(0, &gpu.simple_bind, &[]);
        pass.draw(0..3, 0..1);
    }
    {
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("sailboat boat"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &t.boat_ms,
                resolve_target: Some(&t.boat),
                ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT), store: wgpu::StoreOp::Discard },
            })],
            depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
                view: &t.depth,
                depth_ops: Some(wgpu::Operations { load: wgpu::LoadOp::Clear(1.0), store: wgpu::StoreOp::Discard }),
                stencil_ops: None,
            }),
            ..Default::default()
        });
        pass.set_pipeline(&gpu.boat);
        pass.set_bind_group(0, &gpu.simple_bind, &[]);
        pass.set_vertex_buffer(0, gpu.vertices.slice(..));
        pass.set_index_buffer(gpu.indices.slice(..), wgpu::IndexFormat::Uint16);
        pass.draw_indexed(0..gpu.index_count, 0, 0..1);
    }
    {
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("sailboat scene"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &t.scene,
                resolve_target: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color::BLACK), store: wgpu::StoreOp::Store },
            })],
            ..Default::default()
        });
        pass.set_pipeline(&gpu.scene);
        pass.set_bind_group(0, &t.main_bind, &[]);
        pass.draw(0..3, 0..1);
    }
    {
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("sailboat"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: t.shrink.as_ref().map_or(&card_view, |(full, _)| full),
                resolve_target: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color::BLACK), store: wgpu::StoreOp::Store },
            })],
            ..Default::default()
        });
        pass.set_pipeline(&gpu.composite);
        pass.set_bind_group(0, &t.final_bind, &[]);
        pass.draw(0..3, 0..1);
    }
    if let Some((_, blit_bind)) = &t.shrink {
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("sailboat shrink"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &card_view,
                resolve_target: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color::BLACK), store: wgpu::StoreOp::Store },
            })],
            ..Default::default()
        });
        pass.set_pipeline(&gpu.blit);
        pass.set_bind_group(0, blit_bind, &[]);
        pass.draw(0..3, 0..1);
    }
    queue.submit(Some(encoder.finish()));
}

impl Gpu {
    fn new(device: &wgpu::Device) -> Self {
        // The wallpaper's pipelines, as in its sailboat.rs
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("sailboat shader"),
            source: wgpu::ShaderSource::Wgsl(sailboat_scene::SHADER.into()),
        });
        let uniform_entry = wgpu::BindGroupLayoutEntry {
            binding: 0,
            visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
            ty: wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform, has_dynamic_offset: false, min_binding_size: None },
            count: None,
        };
        let tex_entry = |binding| wgpu::BindGroupLayoutEntry {
            binding,
            visibility: wgpu::ShaderStages::FRAGMENT,
            ty: wgpu::BindingType::Texture {
                sample_type: wgpu::TextureSampleType::Float { filterable: true },
                view_dimension: wgpu::TextureViewDimension::D2,
                multisampled: false,
            },
            count: None,
        };
        let simple_layout =
            device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: Some("sailboat globals"), entries: &[uniform_entry] });
        let main_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("sailboat composite"),
            entries: &[
                uniform_entry,
                tex_entry(1),
                tex_entry(2),
                wgpu::BindGroupLayoutEntry {
                    binding: 3,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
            ],
        });
        let final_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("sailboat final"),
            entries: &[
                uniform_entry,
                tex_entry(2),
                wgpu::BindGroupLayoutEntry {
                    binding: 3,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
                tex_entry(4),
                wgpu::BindGroupLayoutEntry {
                    binding: 5,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Storage { read_only: true },
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
            ],
        });
        let final_pl = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("sailboat final"),
            bind_group_layouts: &[&final_layout],
            push_constant_ranges: &[],
        });
        let simple_pl = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("sailboat simple"),
            bind_group_layouts: &[&simple_layout],
            push_constant_ranges: &[],
        });
        let main_pl = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("sailboat composite"),
            bind_group_layouts: &[&main_layout],
            push_constant_ranges: &[],
        });
        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("sailboat"),
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });
        let fullscreen = |label: &str, layout: &wgpu::PipelineLayout, fs: &str, target: wgpu::TextureFormat| {
            device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some(label),
                layout: Some(layout),
                vertex: wgpu::VertexState { module: &shader, entry_point: Some("vs_full"), compilation_options: Default::default(), buffers: &[] },
                primitive: Default::default(),
                depth_stencil: None,
                multisample: Default::default(),
                fragment: Some(wgpu::FragmentState {
                    module: &shader,
                    entry_point: Some(fs),
                    compilation_options: Default::default(),
                    targets: &[Some(wgpu::ColorTargetState { format: target, blend: None, write_mask: wgpu::ColorWrites::ALL })],
                }),
                multiview: None,
                cache: None,
            })
        };
        let sky = fullscreen("sailboat sky", &simple_pl, "fs_sky", SKY_FORMAT);
        let scene = fullscreen("sailboat scene", &main_pl, "fs_scene", SCENE_FORMAT);
        let composite = fullscreen("sailboat composite", &final_pl, "fs_main", FORMAT);
        let attrs = wgpu::vertex_attr_array![0 => Float32x4, 1 => Float32x4, 2 => Float32x4];
        let boat = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("sailboat boat"),
            layout: Some(&simple_pl),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vs_boat"),
                compilation_options: Default::default(),
                buffers: &[wgpu::VertexBufferLayout {
                    array_stride: std::mem::size_of::<BoatVertex>() as u64,
                    step_mode: wgpu::VertexStepMode::Vertex,
                    attributes: &attrs,
                }],
            },
            primitive: wgpu::PrimitiveState { cull_mode: None, ..Default::default() },
            depth_stencil: Some(wgpu::DepthStencilState {
                format: DEPTH_FORMAT,
                depth_write_enabled: true,
                depth_compare: wgpu::CompareFunction::Less,
                stencil: Default::default(),
                bias: Default::default(),
            }),
            multisample: wgpu::MultisampleState { count: MSAA, ..Default::default() },
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fs_boat"),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState { format: BOAT_FORMAT, blend: None, write_mask: wgpu::ColorWrites::ALL })],
            }),
            multiview: None,
            cache: None,
        });
        // Box filter: each card pixel averages the monitor-size pixels it covers.
        let blit_shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("sailboat shrink"),
            source: wgpu::ShaderSource::Wgsl(BLIT_SHADER.into()),
        });
        let blit_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("sailboat shrink"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: false },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform, has_dynamic_offset: false, min_binding_size: None },
                    count: None,
                },
            ],
        });
        let blit_pl = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("sailboat shrink"),
            bind_group_layouts: &[&blit_layout],
            push_constant_ranges: &[],
        });
        let blit = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("sailboat shrink"),
            layout: Some(&blit_pl),
            vertex: wgpu::VertexState { module: &blit_shader, entry_point: Some("vs"), compilation_options: Default::default(), buffers: &[] },
            primitive: Default::default(),
            depth_stencil: None,
            multisample: Default::default(),
            fragment: Some(wgpu::FragmentState {
                module: &blit_shader,
                entry_point: Some("fs"),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState { format: FORMAT, blend: None, write_mask: wgpu::ColorWrites::ALL })],
            }),
            multiview: None,
            cache: None,
        });
        let (verts, idx) = sailboat_scene::boat::build();
        let vertices = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("sailboat mesh"),
            contents: bytemuck::cast_slice(&verts),
            usage: wgpu::BufferUsages::VERTEX,
        });
        let indices = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("sailboat indices"),
            contents: bytemuck::cast_slice(&idx),
            usage: wgpu::BufferUsages::INDEX,
        });
        let uniform = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("sailboat globals"),
            size: std::mem::size_of::<Globals>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let simple_bind = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("sailboat globals"),
            layout: &simple_layout,
            entries: &[wgpu::BindGroupEntry { binding: 0, resource: uniform.as_entire_binding() }],
        });
        let star_buf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("sailboat stars"),
            contents: bytemuck::cast_slice(&sailboat_scene::stars::gpu_table()),
            usage: wgpu::BufferUsages::STORAGE,
        });
        Gpu {
            world: World::new(),
            main_layout,
            final_layout,
            sampler,
            star_buf,
            sky,
            boat,
            scene,
            composite,
            blit_layout,
            blit,
            vertices,
            indices,
            index_count: idx.len() as u32,
            uniform,
            simple_bind,
            targets: None,
            last_sky: None,
            last: None,
        }
    }

    fn make_targets(&self, device: &wgpu::Device, card: (u32, u32), render: (u32, u32)) -> Targets {
        let (w, h) = render;
        let tex = |label, (tw, th): (u32, u32), format, samples, usage| {
            device
                .create_texture(&wgpu::TextureDescriptor {
                    label: Some(label),
                    size: wgpu::Extent3d { width: tw, height: th, depth_or_array_layers: 1 },
                    mip_level_count: 1,
                    sample_count: samples,
                    dimension: wgpu::TextureDimension::D2,
                    format,
                    usage,
                    view_formats: &[],
                })
                .create_view(&Default::default())
        };
        let rt = wgpu::TextureUsages::RENDER_ATTACHMENT;
        let sampled = rt | wgpu::TextureUsages::TEXTURE_BINDING;
        let sky = tex("sailboat sky", sky_size(w, h), SKY_FORMAT, 1, sampled);
        let bs = box_size(w, h);
        let boat_ms = tex("sailboat boat msaa", bs, BOAT_FORMAT, MSAA, rt);
        let boat = tex("sailboat boat", bs, BOAT_FORMAT, 1, sampled);
        let depth = tex("sailboat depth", bs, DEPTH_FORMAT, MSAA, rt);
        let scene = tex("sailboat scene", scene_size(w, h), SCENE_FORMAT, 1, sampled);
        let main_bind = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("sailboat composite"),
            layout: &self.main_layout,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: self.uniform.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&sky) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(&boat) },
                wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::Sampler(&self.sampler) },
            ],
        });
        let final_bind = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("sailboat final"),
            layout: &self.final_layout,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: self.uniform.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(&boat) },
                wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::Sampler(&self.sampler) },
                wgpu::BindGroupEntry { binding: 4, resource: wgpu::BindingResource::TextureView(&scene) },
                wgpu::BindGroupEntry { binding: 5, resource: self.star_buf.as_entire_binding() },
            ],
        });
        let shrink = (render != card).then(|| {
            let full = tex("sailboat full", render, FORMAT, 1, sampled);
            let scale = [render.0 as f32 / card.0 as f32, render.1 as f32 / card.1 as f32, 0.0, 0.0];
            let scale = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("sailboat shrink"),
                contents: bytemuck::bytes_of(&scale),
                usage: wgpu::BufferUsages::UNIFORM,
            });
            let bind = device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("sailboat shrink"),
                layout: &self.blit_layout,
                entries: &[
                    wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(&full) },
                    wgpu::BindGroupEntry { binding: 1, resource: scale.as_entire_binding() },
                ],
            });
            (full, bind)
        });
        Targets { size: (card, render), shrink, sky, boat_ms, boat, depth, scene, main_bind, final_bind }
    }
}

/// Shrinks the monitor-size render into the card: an exact area average (edge
/// pixels weighted by coverage), in the same 8-bit display values the
/// wallpaper shows. `scale` is source pixels per card pixel.
const BLIT_SHADER: &str = r#"
@group(0) @binding(0) var src: texture_2d<f32>;
@group(0) @binding(1) var<uniform> scale: vec4f;

@vertex
fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
    let p = vec2f(f32((i << 1u) & 2u), f32(i & 2u));
    return vec4f(p * 2.0 - 1.0, 0.0, 1.0);
}

@fragment
fn fs(@builtin(position) frag: vec4f) -> @location(0) vec4f {
    let dims = vec2i(textureDimensions(src));
    let a = floor(frag.xy) * scale.xy;
    let b = a + scale.xy;
    let i0 = vec2i(floor(a));
    let i1 = min(vec2i(ceil(b)), dims);
    var sum = vec4f(0.0);
    var wsum = 0.0;
    for (var y = i0.y; y < min(i1.y, i0.y + 16); y++) {
        let wy = min(f32(y + 1), b.y) - max(f32(y), a.y);
        for (var x = i0.x; x < min(i1.x, i0.x + 16); x++) {
            let w = wy * (min(f32(x + 1), b.x) - max(f32(x), a.x));
            sum += textureLoad(src, vec2i(x, y), 0) * w;
            wsum += w;
        }
    }
    return sum / max(wsum, 1e-6);
}
"#;
