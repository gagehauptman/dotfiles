//! The Sputnik 1 wallpaper, live, for its entry in the wallpaper selector and
//! behind the lock screen. It draws the wallpaper's own scene
//! (`sputnik_scene`: the same shader, orbit, camera and lettering as the
//! renderer in scripts/wallpaper/bins/spinning_globe, see its sputnik.rs) at
//! the monitor's resolution, cropped to the card's aspect, then box-filters it
//! down to the card with the globe preview's downsample shader.
//!
//! Options: `output: [w, h]`, the monitor size the wallpaper would fill
//! (default 2560×1440); `fps` (default 30, like the wallpaper); `time`, unix
//! seconds to freeze the clock at (for comparing renders).
//!
//! Bevy only hosts it here: the only camera is inactive, and a render-world
//! system encodes the scene and the downscale straight on wgpu into the
//! card's image.
use std::time::{Duration, Instant, SystemTime};

use bevy::prelude::*;
use bevy::render::render_asset::RenderAssets;
use bevy::render::renderer::{RenderDevice, RenderQueue};
use bevy::render::texture::GpuImage;
use bevy::render::{Extract, ExtractSchedule, Render, RenderApp, RenderSet};
use quickshell_bevy::prelude::*;
use sputnik_scene::{bytemuck, Frame, Glyph, Globals, Line, SceneData, LAND_H, LAND_W};
use wgpu::util::DeviceExt;

// Shared with the globe's preview.
const DOWNSAMPLE: &str = include_str!("../../spinning_globe/src/downsample.wgsl");
// The scene wants an 8-bit non-sRGB target (as in the wallpaper), and Qt
// reads the card as plain RGBA8.
const FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba8Unorm;
// As in the wallpaper's sputnik.rs.
const DYN_LINES: usize = 512;
const DYN_GLYPHS: usize = 1024;

pub struct Sputnik;

impl Plugin for Sputnik {
    fn build(&self, app: &mut App) {
        app.add_systems(Startup, setup);
        if let Some(render_app) = app.get_sub_app_mut(RenderApp) {
            render_app.add_systems(ExtractSchedule, extract).add_systems(Render, draw.in_set(RenderSet::Render));
        }
    }
}
quickshell_bevy::widget!(Sputnik);

#[derive(Resource, Clone, Copy)]
struct Settings {
    output: (u32, u32),
    interval: Duration,
    time: Option<f64>,
}

fn setup(mut commands: Commands, options: Res<WidgetOptions>) {
    let json: serde_json::Value = serde_json::from_str(&options.0).unwrap_or_default();
    let dim = |i: usize, default: u32| json["output"][i].as_u64().filter(|&v| v > 0).map_or(default, |v| v.min(16384) as u32);
    let fps = json["fps"].as_f64().filter(|&f| f > 0.0).unwrap_or(30.0);
    commands.insert_resource(Settings {
        output: (dim(0, 2560), dim(1, 1440)),
        interval: Duration::from_secs_f64(1.0 / fps),
        time: json["time"].as_f64(),
    });
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
    commands.insert_resource(FrameInfo {
        target: target.handle.clone(),
        size: (target.width, target.height),
        settings: *settings,
    });
}

/// The full-resolution crop, rebuilt when the card or output changes.
struct Scene {
    crop: (u32, u32),
    output: (u32, u32),
    colour: wgpu::Texture,
    downsample_bind: wgpu::BindGroup,
}

/// GPU state, made on the first frame.
struct Gpu {
    data: SceneData,
    frame: Frame,
    sky: wgpu::RenderPipeline,
    lines: wgpu::RenderPipeline,
    ball: wgpu::RenderPipeline,
    text: wgpu::RenderPipeline,
    static_lines: wgpu::Buffer,
    static_count: u32,
    uniform_buffer: wgpu::Buffer,
    bind_group: wgpu::BindGroup,
    dyn_lines: wgpu::Buffer,
    glyphs: wgpu::Buffer,
    downsample_pipeline: wgpu::RenderPipeline,
    downsample_layout: wgpu::BindGroupLayout,
    params: wgpu::Buffer,
    scene: Option<Scene>,
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
    let (tw, th) = info.size;
    if tw == 0 || th == 0 {
        return;
    }
    let device = device.wgpu_device();
    let queue: &wgpu::Queue = &queue;
    let gpu = gpu.get_or_insert_with(|| Gpu::new(device, queue));

    // Frame cap: the card's image keeps the last frame in between. A new
    // target (resize) always gets drawn.
    let now = Instant::now();
    if let Some((at, handle, size)) = &gpu.last {
        if *handle == info.target && *size == info.size && now.duration_since(*at) < info.settings.interval {
            return;
        }
    }
    gpu.last = Some((now, info.target.clone(), info.size));

    // Centre crop of the output with the card's aspect, in output pixels. The
    // scene lays itself out for the size it's given, so it's drawn at the crop.
    let (ow, oh) = info.settings.output;
    let k = (ow as f32 / tw as f32).min(oh as f32 / th as f32);
    let crop = (((tw as f32 * k).round() as u32).clamp(1, ow), ((th as f32 * k).round() as u32).clamp(1, oh));
    if gpu.scene.as_ref().map_or(true, |s| s.crop != crop || s.output != info.settings.output) {
        gpu.scene = Some(gpu.make_scene(device, crop, info.settings.output));
    }

    let t = info.settings.time.unwrap_or_else(|| sputnik_scene::unix_secs(SystemTime::now()));
    gpu.data.frame(t, crop.0, crop.1, &mut gpu.frame);
    let Some(globals) = gpu.frame.globals else { return };
    gpu.frame.lines.truncate(DYN_LINES);
    gpu.frame.text.truncate(DYN_GLYPHS);
    let ground = gpu.frame.ground.min(gpu.frame.lines.len()) as u32;
    let line_count = gpu.frame.lines.len() as u32;
    let glyph_count = gpu.frame.text.len() as u32;
    queue.write_buffer(&gpu.uniform_buffer, 0, bytemuck::bytes_of::<Globals>(&globals));
    if line_count > 0 {
        queue.write_buffer(&gpu.dyn_lines, 0, bytemuck::cast_slice(&gpu.frame.lines));
    }
    if glyph_count > 0 {
        queue.write_buffer(&gpu.glyphs, 0, bytemuck::cast_slice(&gpu.frame.text));
    }
    queue.write_buffer(&gpu.params, 0, bytemuck::cast_slice(&[crop.0 as f32, crop.1 as f32, tw as f32, th as f32]));

    let scene = gpu.scene.as_ref().unwrap();
    let scene_view = scene.colour.create_view(&Default::default());
    let card_view = target.texture.create_view(&wgpu::TextureViewDescriptor { format: Some(FORMAT), ..Default::default() });
    let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("sputnik") });
    {
        let [r, g, b] = sputnik_scene::BG;
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("sputnik"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &scene_view,
                resolve_target: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color { r, g, b, a: 1.0 }), store: wgpu::StoreOp::Store },
            })],
            depth_stencil_attachment: None,
            timestamp_writes: None,
            occlusion_query_set: None,
        });
        // As the wallpaper's sputnik.rs: sky, static lines, ground track,
        // ball, antennas and streaks, text.
        pass.set_bind_group(0, &gpu.bind_group, &[]);
        pass.set_pipeline(&gpu.sky);
        pass.draw(0..4, 0..1);

        pass.set_pipeline(&gpu.lines);
        pass.set_vertex_buffer(0, gpu.static_lines.slice(..));
        pass.draw(0..4, 0..gpu.static_count);
        if ground > 0 {
            pass.set_vertex_buffer(0, gpu.dyn_lines.slice(..));
            pass.draw(0..4, 0..ground);
        }

        pass.set_pipeline(&gpu.ball);
        pass.draw(0..4, 0..1);

        if line_count > ground {
            pass.set_pipeline(&gpu.lines);
            pass.set_vertex_buffer(0, gpu.dyn_lines.slice(..));
            pass.draw(0..4, ground..line_count);
        }

        if glyph_count > 0 {
            pass.set_pipeline(&gpu.text);
            pass.set_vertex_buffer(0, gpu.glyphs.slice(..));
            pass.draw(0..4, 0..glyph_count);
        }
    }
    {
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("sputnik downsample"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &card_view,
                resolve_target: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color::BLACK), store: wgpu::StoreOp::Store },
            })],
            depth_stencil_attachment: None,
            timestamp_writes: None,
            occlusion_query_set: None,
        });
        pass.set_pipeline(&gpu.downsample_pipeline);
        pass.set_bind_group(0, &scene.downsample_bind, &[]);
        pass.draw(0..3, 0..1);
    }
    queue.submit(Some(encoder.finish()));
}

fn texture_r8(device: &wgpu::Device, queue: &wgpu::Queue, label: &str, w: u32, h: u32, pixels: &[u8]) -> wgpu::TextureView {
    let texture = device.create_texture_with_data(
        queue,
        &wgpu::TextureDescriptor {
            label: Some(label),
            size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::R8Unorm,
            usage: wgpu::TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        },
        wgpu::util::TextureDataOrder::LayerMajor,
        pixels,
    );
    texture.create_view(&Default::default())
}

impl Gpu {
    fn new(device: &wgpu::Device, queue: &wgpu::Queue) -> Self {
        let uniform_entry = |binding, visibility| wgpu::BindGroupLayoutEntry {
            binding,
            visibility,
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

        // The wallpaper's pipelines, as in its sputnik.rs
        let data = SceneData::build();
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("sputnik shader"),
            source: wgpu::ShaderSource::Wgsl(sputnik_scene::SHADER.into()),
        });
        let bind_group_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("sputnik globals"),
            entries: &[
                uniform_entry(0, wgpu::ShaderStages::VERTEX_FRAGMENT),
                tex_entry(1),
                wgpu::BindGroupLayoutEntry {
                    binding: 2,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
                tex_entry(3),
            ],
        });
        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("sputnik layout"),
            bind_group_layouts: &[&bind_group_layout],
            push_constant_ranges: &[],
        });

        let land = texture_r8(device, queue, "sputnik land", LAND_W, LAND_H, &data.land);
        let atlas = match &data.atlas {
            Some(a) => texture_r8(device, queue, "sputnik font", a.w, a.h, &a.pixels),
            None => texture_r8(device, queue, "sputnik font", 1, 1, &[0]),
        };
        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            address_mode_u: wgpu::AddressMode::Repeat,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });

        let line_attrs = wgpu::vertex_attr_array![0 => Float32x4, 1 => Float32x4, 2 => Float32x4];
        let pipeline = |label: &str, vs: &str, fs: &str, stride: u64, attrs: &[wgpu::VertexAttribute], replace: bool| {
            let buffers: Vec<wgpu::VertexBufferLayout> = if stride == 0 {
                vec![]
            } else {
                vec![wgpu::VertexBufferLayout { array_stride: stride, step_mode: wgpu::VertexStepMode::Instance, attributes: attrs }]
            };
            let over = wgpu::BlendComponent {
                src_factor: wgpu::BlendFactor::One,
                dst_factor: wgpu::BlendFactor::OneMinusSrcAlpha,
                operation: wgpu::BlendOperation::Add,
            };
            device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some(label),
                layout: Some(&layout),
                vertex: wgpu::VertexState { module: &shader, entry_point: Some(vs), compilation_options: Default::default(), buffers: &buffers },
                primitive: wgpu::PrimitiveState { topology: wgpu::PrimitiveTopology::TriangleStrip, cull_mode: None, ..Default::default() },
                depth_stencil: None,
                multisample: Default::default(),
                fragment: Some(wgpu::FragmentState {
                    module: &shader,
                    entry_point: Some(fs),
                    compilation_options: Default::default(),
                    targets: &[Some(wgpu::ColorTargetState {
                        format: FORMAT,
                        blend: if replace { None } else { Some(wgpu::BlendState { color: over, alpha: over }) },
                        write_mask: wgpu::ColorWrites::ALL,
                    })],
                }),
                multiview: None,
                cache: None,
            })
        };
        let sky = pipeline("sputnik sky", "vs_full", "fs_sky", 0, &[], true);
        let lines = pipeline("sputnik lines", "vs_line", "fs_line", std::mem::size_of::<Line>() as u64, &line_attrs, false);
        let ball = pipeline("sputnik ball", "vs_ball", "fs_ball", 0, &[], false);
        let text = pipeline("sputnik text", "vs_text", "fs_text", std::mem::size_of::<Glyph>() as u64, &line_attrs, false);

        let static_lines = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("sputnik static lines"),
            contents: bytemuck::cast_slice(&data.static_lines),
            usage: wgpu::BufferUsages::VERTEX,
        });
        let static_count = data.static_lines.len() as u32;

        let uniform_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("sputnik globals"),
            size: std::mem::size_of::<Globals>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("sputnik globals"),
            layout: &bind_group_layout,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: uniform_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&land) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::Sampler(&sampler) },
                wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::TextureView(&atlas) },
            ],
        });
        let vertex_buffer = |label, size: usize| {
            device.create_buffer(&wgpu::BufferDescriptor {
                label: Some(label),
                size: size as u64,
                usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            })
        };
        let dyn_lines = vertex_buffer("sputnik dynamic lines", DYN_LINES * std::mem::size_of::<Line>());
        let glyphs = vertex_buffer("sputnik glyphs", DYN_GLYPHS * std::mem::size_of::<Glyph>());

        // Area-weighted box filter from the full-size crop down to the card
        let down_shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("downsample"),
            source: wgpu::ShaderSource::Wgsl(DOWNSAMPLE.into()),
        });
        let downsample_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("downsample"),
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
                uniform_entry(1, wgpu::ShaderStages::FRAGMENT),
            ],
        });
        let down_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("downsample"),
            bind_group_layouts: &[&downsample_layout],
            push_constant_ranges: &[],
        });
        let downsample_pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("downsample"),
            layout: Some(&down_layout),
            vertex: wgpu::VertexState { module: &down_shader, entry_point: Some("vs"), compilation_options: Default::default(), buffers: &[] },
            primitive: Default::default(),
            depth_stencil: None,
            multisample: Default::default(),
            fragment: Some(wgpu::FragmentState {
                module: &down_shader,
                entry_point: Some("fs"),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState { format: FORMAT, blend: None, write_mask: wgpu::ColorWrites::ALL })],
            }),
            multiview: None,
            cache: None,
        });
        let params = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("downsample params"),
            size: 16,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        Gpu {
            data,
            frame: Frame::default(),
            sky,
            lines,
            ball,
            text,
            static_lines,
            static_count,
            uniform_buffer,
            bind_group,
            dyn_lines,
            glyphs,
            downsample_pipeline,
            downsample_layout,
            params,
            scene: None,
            last: None,
        }
    }

    fn make_scene(&self, device: &wgpu::Device, crop: (u32, u32), output: (u32, u32)) -> Scene {
        let colour = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("sputnik scene"),
            size: wgpu::Extent3d { width: crop.0, height: crop.1, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: FORMAT,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        });
        let view = colour.create_view(&Default::default());
        let downsample_bind = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("downsample"),
            layout: &self.downsample_layout,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(&view) },
                wgpu::BindGroupEntry { binding: 1, resource: self.params.as_entire_binding() },
            ],
        });
        Scene { crop, output, colour, downsample_bind }
    }
}
