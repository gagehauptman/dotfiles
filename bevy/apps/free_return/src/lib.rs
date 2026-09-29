//! The free-return wallpaper, live, for its entry in the wallpaper selector.
//! It draws the wallpaper's own scene (`free_return_scene`: the same shader,
//! trajectory, layout and wall clock as the renderer in
//! scripts/wallpaper/bins/spinning_globe) at the monitor's resolution,
//! cropped to the card's aspect, then box-filters it down to the card with
//! the globe preview's downsample shader. So the preview is the real
//! wallpaper, only smaller, at the same moment of the flight.
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
use free_return_scene::{bytemuck, Blend, Globals, SceneData, Source, DRAWS};
use quickshell_bevy::prelude::*;
use wgpu::util::DeviceExt;

// Shared with the globe's preview.
const DOWNSAMPLE: &str = include_str!("../../spinning_globe/src/downsample.wgsl");
// Scene and card share this format: the scene's additive maths runs on the
// encoded bytes (as in the wallpaper), and Qt reads the card as plain RGBA8.
const FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba8Unorm;

pub struct FreeReturn;

impl Plugin for FreeReturn {
    fn build(&self, app: &mut App) {
        app.add_systems(Startup, setup);
        if let Some(render_app) = app.get_sub_app_mut(RenderApp) {
            render_app.add_systems(ExtractSchedule, extract).add_systems(Render, draw.in_set(RenderSet::Render));
        }
    }
}
quickshell_bevy::widget!(FreeReturn);

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
    pipelines: Vec<wgpu::RenderPipeline>,
    buffers: Vec<Option<wgpu::Buffer>>,
    counts: Vec<(u32, u32)>,
    globals: wgpu::Buffer,
    globals_bind: wgpu::BindGroup,
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
    let gpu = gpu.get_or_insert_with(|| Gpu::new(device));

    // Frame cap: the card's image keeps the last frame in between. A new
    // target (resize) always gets drawn.
    let now = Instant::now();
    if let Some((at, handle, size)) = &gpu.last {
        if *handle == info.target && *size == info.size && now.duration_since(*at) < info.settings.interval {
            return;
        }
    }
    gpu.last = Some((now, info.target.clone(), info.size));

    // Centre crop of the output with the card's aspect, in output pixels.
    let (ow, oh) = info.settings.output;
    let k = (ow as f32 / tw as f32).min(oh as f32 / th as f32);
    let crop = (((tw as f32 * k).round() as u32).clamp(1, ow), ((th as f32 * k).round() as u32).clamp(1, oh));
    if gpu.scene.as_ref().map_or(true, |s| s.crop != crop || s.output != info.settings.output) {
        gpu.scene = Some(gpu.make_scene(device, crop, info.settings.output));
    }

    let t = info.settings.time.unwrap_or_else(|| free_return_scene::unix_secs(SystemTime::now()));
    let globals = Globals::at_secs(t, ow, oh, &gpu.data).for_crop(crop.0, crop.1);
    queue.write_buffer(&gpu.globals, 0, bytemuck::bytes_of(&globals));
    queue.write_buffer(&gpu.params, 0, bytemuck::cast_slice(&[crop.0 as f32, crop.1 as f32, tw as f32, th as f32]));

    let scene = gpu.scene.as_ref().unwrap();
    let scene_view = scene.colour.create_view(&Default::default());
    let card_view = target.texture.create_view(&wgpu::TextureViewDescriptor { format: Some(FORMAT), ..Default::default() });
    let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("free return") });
    {
        let [r, g, b] = free_return_scene::BG;
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("free return"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &scene_view,
                resolve_target: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color { r, g, b, a: 1.0 }), store: wgpu::StoreOp::Store },
            })],
            depth_stencil_attachment: None,
            timestamp_writes: None,
            occlusion_query_set: None,
        });
        pass.set_bind_group(0, &gpu.globals_bind, &[]);
        for (d, pipeline) in DRAWS.iter().zip(&gpu.pipelines) {
            let i = d.source.index();
            pass.set_pipeline(pipeline);
            if let Some(buffer) = &gpu.buffers[i] {
                pass.set_vertex_buffer(0, buffer.slice(..));
            }
            let (vertices, instances) = gpu.counts[i];
            pass.draw(0..vertices, 0..instances);
        }
    }
    {
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("free return downsample"),
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

impl Gpu {
    fn new(device: &wgpu::Device) -> Self {
        let uniform_entry = |binding, visibility| wgpu::BindGroupLayoutEntry {
            binding,
            visibility,
            ty: wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform, has_dynamic_offset: false, min_binding_size: None },
            count: None,
        };

        // The wallpaper's pipelines, as in its free_return.rs
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("free return shader"),
            source: wgpu::ShaderSource::Wgsl(free_return_scene::SHADER.into()),
        });
        let globals_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("free return globals"),
            entries: &[uniform_entry(0, wgpu::ShaderStages::VERTEX_FRAGMENT)],
        });
        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("free return layout"),
            bind_group_layouts: &[&globals_layout],
            push_constant_ranges: &[],
        });
        let pair_attrs = wgpu::vertex_attr_array![0 => Float32x4, 1 => Float32x4];
        let single_attrs = wgpu::vertex_attr_array![0 => Float32x4];
        let pipelines = DRAWS
            .iter()
            .map(|d| {
                let stride = d.source.stride();
                let buffers: Vec<wgpu::VertexBufferLayout> = match stride {
                    0 => vec![],
                    _ => vec![wgpu::VertexBufferLayout {
                        array_stride: stride,
                        step_mode: wgpu::VertexStepMode::Instance,
                        attributes: if stride == 32 { &pair_attrs } else { &single_attrs },
                    }],
                };
                let operation = match d.blend {
                    Blend::Add => wgpu::BlendOperation::Add,
                    Blend::Max => wgpu::BlendOperation::Max,
                };
                let blend = wgpu::BlendState {
                    color: wgpu::BlendComponent { src_factor: wgpu::BlendFactor::One, dst_factor: wgpu::BlendFactor::One, operation },
                    alpha: wgpu::BlendComponent::REPLACE,
                };
                device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                    label: Some(d.label),
                    layout: Some(&layout),
                    vertex: wgpu::VertexState { module: &shader, entry_point: Some(d.vs), compilation_options: Default::default(), buffers: &buffers },
                    primitive: wgpu::PrimitiveState { topology: wgpu::PrimitiveTopology::TriangleStrip, cull_mode: None, ..Default::default() },
                    depth_stencil: None,
                    multisample: Default::default(),
                    fragment: Some(wgpu::FragmentState {
                        module: &shader,
                        entry_point: Some(d.fs),
                        compilation_options: Default::default(),
                        targets: &[Some(wgpu::ColorTargetState { format: FORMAT, blend: Some(blend), write_mask: wgpu::ColorWrites::ALL })],
                    }),
                    multiview: None,
                    cache: None,
                })
            })
            .collect();

        let data = SceneData::build();
        let buffers = Source::ALL
            .iter()
            .map(|&s| {
                data.bytes(s).map(|contents| {
                    device.create_buffer_init(&wgpu::util::BufferInitDescriptor { label: Some("free return scene"), contents, usage: wgpu::BufferUsages::VERTEX })
                })
            })
            .collect();
        let counts = Source::ALL.iter().map(|&s| data.counts(s)).collect();

        let globals = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("free return globals"),
            size: std::mem::size_of::<Globals>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let globals_bind = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("free return globals"),
            layout: &globals_layout,
            entries: &[wgpu::BindGroupEntry { binding: 0, resource: globals.as_entire_binding() }],
        });

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
            pipelines,
            buffers,
            counts,
            globals,
            globals_bind,
            downsample_pipeline,
            downsample_layout,
            params,
            scene: None,
            last: None,
        }
    }

    fn make_scene(&self, device: &wgpu::Device, crop: (u32, u32), output: (u32, u32)) -> Scene {
        let colour = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("free return scene"),
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
