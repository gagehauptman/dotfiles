//! The spinning globe wallpaper, live, for its entry in the wallpaper
//! selector. It draws the wallpaper's own scene (`globe_scene`: the same
//! shader, geometry and layout as scripts/wallpaper/bins/spinning_globe) at
//! the monitor's resolution, cropped to the card's aspect like the old preview
//! screenshot was, then box-filters it down to the card. So the preview is the
//! real wallpaper, only smaller.
//!
//! Options: `output: [w, h]`, the monitor size the wallpaper would fill
//! (default 2560×1440); `fps` (default 30, like the wallpaper).
//!
//! Bevy only hosts it here: the only camera is inactive, and a render-world
//! system encodes the two globe passes and the downscale straight on wgpu
//! into the card's image.
use std::time::{Duration, Instant};

use bevy::prelude::*;
use bevy::render::render_asset::RenderAssets;
use bevy::render::renderer::{RenderDevice, RenderQueue};
use bevy::render::texture::GpuImage;
use bevy::render::{Extract, ExtractSchedule, Render, RenderApp, RenderSet};
use globe_scene::{build_continent_lines, build_points, bytemuck, Globals, LineInstance, PointInstance};
use quickshell_bevy::prelude::*;
use wgpu::util::DeviceExt;

const DOWNSAMPLE: &str = include_str!("downsample.wgsl");
// Scene and card share this format: the scene's additive maths runs on the
// encoded bytes (as in the wallpaper), and Qt reads the card as plain RGBA8.
const FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba8Unorm;

pub struct SpinningGlobe;

impl Plugin for SpinningGlobe {
    fn build(&self, app: &mut App) {
        app.add_systems(Startup, setup);
        if let Some(render_app) = app.get_sub_app_mut(RenderApp) {
            render_app.add_systems(ExtractSchedule, extract).add_systems(Render, draw.in_set(RenderSet::Render));
        }
    }
}
quickshell_bevy::widget!(SpinningGlobe);

#[derive(Resource, Clone, Copy)]
struct Settings {
    output: (u32, u32),
    interval: Duration,
}

fn setup(mut commands: Commands, options: Res<WidgetOptions>) {
    let json: serde_json::Value = serde_json::from_str(&options.0).unwrap_or_default();
    let dim = |i: usize, default: u32| json["output"][i].as_u64().filter(|&v| v > 0).map_or(default, |v| v.min(16384) as u32);
    let fps = json["fps"].as_f64().filter(|&f| f > 0.0).unwrap_or(30.0);
    commands.insert_resource(Settings {
        output: (dim(0, 2560), dim(1, 1440)),
        interval: Duration::from_secs_f64(1.0 / fps),
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

/// GPU state, made on the first frame.
struct Gpu {
    line_pipeline: wgpu::RenderPipeline,
    point_pipeline: wgpu::RenderPipeline,
    downsample_pipeline: wgpu::RenderPipeline,
    downsample_layout: wgpu::BindGroupLayout,
    globals: wgpu::Buffer,
    globals_bind: wgpu::BindGroup,
    params: wgpu::Buffer,
    lines: wgpu::Buffer,
    line_count: u32,
    points: wgpu::Buffer,
    point_count: u32,
    // Offscreen full-resolution crop, rebuilt when the card or output changes
    scene: Option<(wgpu::Texture, (u32, u32), (u32, u32), wgpu::BindGroup)>,
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

    // Centre crop of the output with the card's aspect, in output pixels
    // (the wallpaper renders at the layer's logical size, as given).
    let (ow, oh) = info.settings.output;
    let k = (ow as f32 / tw as f32).min(oh as f32 / th as f32);
    let crop = (((tw as f32 * k).round() as u32).clamp(1, ow), ((th as f32 * k).round() as u32).clamp(1, oh));
    if gpu.scene.as_ref().map_or(true, |s| s.1 != crop || s.2 != info.settings.output) {
        let texture = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("globe scene"),
            size: wgpu::Extent3d { width: crop.0, height: crop.1, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: FORMAT,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        });
        let view = texture.create_view(&Default::default());
        let bind = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("downsample"),
            layout: &gpu.downsample_layout,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(&view) },
                wgpu::BindGroupEntry { binding: 1, resource: gpu.params.as_entire_binding() },
            ],
        });
        gpu.scene = Some((texture, crop, info.settings.output, bind));
    }
    let (scene, _, _, downsample_bind) = gpu.scene.as_ref().unwrap();

    // Wall-clock rotation, shared with the wallpaper so the preview matches it.
    let rotation = globe_scene::rotation_now();
    queue.write_buffer(&gpu.globals, 0, bytemuck::bytes_of(&Globals::for_crop(ow, oh, crop.0, crop.1, rotation)));
    queue.write_buffer(&gpu.params, 0, bytemuck::cast_slice(&[crop.0 as f32, crop.1 as f32, tw as f32, th as f32]));

    let scene_view = scene.create_view(&Default::default());
    let card_view = target.texture.create_view(&wgpu::TextureViewDescriptor { format: Some(FORMAT), ..Default::default() });
    let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("spinning globe") });
    {
        let [r, g, b] = globe_scene::BG;
        let mut pass = begin(&mut encoder, &scene_view, wgpu::Color { r, g, b, a: 1.0 });
        pass.set_bind_group(0, &gpu.globals_bind, &[]);
        // Landmasses first (MAX blend), then the additive grid and outline.
        pass.set_pipeline(&gpu.line_pipeline);
        pass.set_vertex_buffer(0, gpu.lines.slice(..));
        pass.draw(0..4, 0..gpu.line_count);
        pass.set_pipeline(&gpu.point_pipeline);
        pass.set_vertex_buffer(0, gpu.points.slice(..));
        pass.draw(0..4, 0..gpu.point_count);
    }
    {
        let mut pass = begin(&mut encoder, &card_view, wgpu::Color::BLACK);
        pass.set_pipeline(&gpu.downsample_pipeline);
        pass.set_bind_group(0, downsample_bind, &[]);
        pass.draw(0..3, 0..1);
    }
    queue.submit(Some(encoder.finish()));
}

fn begin<'a>(encoder: &'a mut wgpu::CommandEncoder, view: &'a wgpu::TextureView, clear: wgpu::Color) -> wgpu::RenderPass<'a> {
    encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        label: Some("spinning globe"),
        color_attachments: &[Some(wgpu::RenderPassColorAttachment {
            view,
            resolve_target: None,
            ops: wgpu::Operations { load: wgpu::LoadOp::Clear(clear), store: wgpu::StoreOp::Store },
        })],
        depth_stencil_attachment: None,
        timestamp_writes: None,
        occlusion_query_set: None,
    })
}

impl Gpu {
    fn new(device: &wgpu::Device) -> Self {
        let uniform_entry = |binding, visibility| wgpu::BindGroupLayoutEntry {
            binding,
            visibility,
            ty: wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform, has_dynamic_offset: false, min_binding_size: None },
            count: None,
        };

        // The wallpaper's two pipelines, as in its main.rs
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("globe shader"),
            source: wgpu::ShaderSource::Wgsl(globe_scene::SHADER.into()),
        });
        let globals_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("globals"),
            entries: &[uniform_entry(0, wgpu::ShaderStages::VERTEX)],
        });
        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("globe layout"),
            bind_group_layouts: &[&globals_layout],
            push_constant_ranges: &[],
        });
        let pipeline = |label, layout: &wgpu::PipelineLayout, module, vs, fs, buffers: &[wgpu::VertexBufferLayout], strip, blend| {
            device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some(label),
                layout: Some(layout),
                vertex: wgpu::VertexState { module, entry_point: Some(vs), compilation_options: Default::default(), buffers },
                primitive: wgpu::PrimitiveState {
                    topology: if strip { wgpu::PrimitiveTopology::TriangleStrip } else { wgpu::PrimitiveTopology::TriangleList },
                    cull_mode: None,
                    ..Default::default()
                },
                depth_stencil: None,
                multisample: Default::default(),
                fragment: Some(wgpu::FragmentState {
                    module,
                    entry_point: Some(fs),
                    compilation_options: Default::default(),
                    targets: &[Some(wgpu::ColorTargetState { format: FORMAT, blend, write_mask: wgpu::ColorWrites::ALL })],
                }),
                multiview: None,
                cache: None,
            })
        };
        let blend = |operation| {
            Some(wgpu::BlendState {
                color: wgpu::BlendComponent { src_factor: wgpu::BlendFactor::One, dst_factor: wgpu::BlendFactor::One, operation },
                alpha: wgpu::BlendComponent::REPLACE,
            })
        };
        let line_attrs = wgpu::vertex_attr_array![0 => Float32x2, 1 => Float32x2];
        let point_attrs = wgpu::vertex_attr_array![0 => Float32x2, 1 => Float32, 2 => Float32];
        let instances = |stride: usize, attributes| wgpu::VertexBufferLayout {
            array_stride: stride as u64,
            step_mode: wgpu::VertexStepMode::Instance,
            attributes,
        };
        let line_pipeline = pipeline(
            "continent lines",
            &layout,
            &shader,
            "vs_line",
            "fs_line",
            &[instances(std::mem::size_of::<LineInstance>(), &line_attrs)],
            true,
            blend(wgpu::BlendOperation::Max),
        );
        let point_pipeline = pipeline(
            "glow points",
            &layout,
            &shader,
            "vs_point",
            "fs_point",
            &[instances(std::mem::size_of::<PointInstance>(), &point_attrs)],
            true,
            blend(wgpu::BlendOperation::Add),
        );

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
        let down_pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("downsample"),
            bind_group_layouts: &[&downsample_layout],
            push_constant_ranges: &[],
        });
        let downsample_pipeline = pipeline("downsample", &down_pipeline_layout, &down_shader, "vs", "fs", &[], false, None);

        let globals = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("globals"),
            size: std::mem::size_of::<Globals>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let globals_bind = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("globals"),
            layout: &globals_layout,
            entries: &[wgpu::BindGroupEntry { binding: 0, resource: globals.as_entire_binding() }],
        });
        let params = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("downsample params"),
            size: 16,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let line_data = build_continent_lines();
        let point_data = build_points();
        let lines = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("continent lines"),
            contents: bytemuck::cast_slice(&line_data),
            usage: wgpu::BufferUsages::VERTEX,
        });
        let points = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("glow points"),
            contents: bytemuck::cast_slice(&point_data),
            usage: wgpu::BufferUsages::VERTEX,
        });

        Gpu {
            line_pipeline,
            point_pipeline,
            downsample_pipeline,
            downsample_layout,
            globals,
            globals_bind,
            params,
            lines,
            line_count: line_data.len() as u32,
            points,
            point_count: point_data.len() as u32,
            scene: None,
            last: None,
        }
    }
}
