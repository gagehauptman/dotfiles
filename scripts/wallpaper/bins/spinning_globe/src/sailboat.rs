//! The sailboat scene (`sailboat_scene`) on this renderer's wgpu: a sloop
//! alone off Daytona under the real sky and weather. Pipelines and the boat
//! mesh are made once at startup so switching to it is instant; each surface
//! gets its uniform buffer, a half-size sky texture (redrawn ~10 times a
//! second, not every frame) and a small MSAA box the boat is drawn into, all
//! made on its first frame and reused (no per-frame allocations).
use std::cell::RefCell;

use sailboat_scene::{box_size, bytemuck, scene_size, sky_size, BoatVertex, Globals, World};
use wgpu::util::DeviceExt;

const SKY_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba16Float;
const SCENE_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba16Float;
const BOAT_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba8Unorm;
const DEPTH_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Depth32Float;
const MSAA: u32 = 4;

pub struct SailboatGpu {
    world: RefCell<World>,
    simple_layout: wgpu::BindGroupLayout,
    main_layout: wgpu::BindGroupLayout,
    final_layout: wgpu::BindGroupLayout,
    sampler: wgpu::Sampler,
    /// The star catalogue's cell grid and records (scene crate `stars`), read by the composite pass.
    star_buf: wgpu::Buffer,
    sky: wgpu::RenderPipeline,
    boat: wgpu::RenderPipeline,
    scene: wgpu::RenderPipeline,
    composite: wgpu::RenderPipeline,
    vertices: wgpu::Buffer,
    indices: wgpu::Buffer,
    index_count: u32,
    passes: Passes,
}

/// SAILBOAT_PROFILE=noboat|nocomp skips a pass, for measuring their cost.
struct Passes {
    boat: bool,
    scene: bool,
}

struct Targets {
    size: (u32, u32),
    sky: wgpu::TextureView,
    boat_ms: wgpu::TextureView,
    boat: wgpu::TextureView,
    depth: wgpu::TextureView,
    scene: wgpu::TextureView,
    main_bind: wgpu::BindGroup,
    final_bind: wgpu::BindGroup,
}

pub struct SailboatSurface {
    uniform_buffer: wgpu::Buffer,
    simple_bind: wgpu::BindGroup,
    targets: Option<Targets>,
    last_sky: Option<f64>,
}

impl SailboatSurface {
    /// Frees the textures while another scene shows; remade on the next frame.
    #[allow(dead_code)]
    pub fn release(&mut self) {
        self.targets = None;
        self.last_sky = None;
    }
}

impl SailboatGpu {
    pub fn new(device: &wgpu::Device, format: wgpu::TextureFormat) -> Self {
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
        let simple_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("sailboat globals"),
            entries: &[uniform_entry],
        });
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
            bind_group_layouts: &[Some(&final_layout)],
            ..Default::default()
        });
        let simple_pl = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("sailboat simple"),
            bind_group_layouts: &[Some(&simple_layout)],
            ..Default::default()
        });
        let main_pl = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("sailboat composite"),
            bind_group_layouts: &[Some(&main_layout)],
            ..Default::default()
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
                primitive: wgpu::PrimitiveState::default(),
                depth_stencil: None,
                multisample: wgpu::MultisampleState::default(),
                fragment: Some(wgpu::FragmentState {
                    module: &shader,
                    entry_point: Some(fs),
                    compilation_options: Default::default(),
                    targets: &[Some(wgpu::ColorTargetState { format: target, blend: None, write_mask: wgpu::ColorWrites::ALL })],
                }),
                multiview_mask: None,
                cache: None,
            })
        };
        let sky = fullscreen("sailboat sky", &simple_pl, "fs_sky", SKY_FORMAT);
        let scene = fullscreen("sailboat scene", &main_pl, "fs_scene", SCENE_FORMAT);
        let composite = fullscreen("sailboat composite", &final_pl, "fs_main", format);

        let attrs = wgpu::vertex_attr_array![0 => Float32x4, 1 => Float32x4, 2 => Float32x4];
        let boat = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("sailboat boat"),
            layout: Some(&simple_pl),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vs_boat"),
                compilation_options: Default::default(),
                buffers: &[Some(wgpu::VertexBufferLayout {
                    array_stride: std::mem::size_of::<BoatVertex>() as u64,
                    step_mode: wgpu::VertexStepMode::Vertex,
                    attributes: &attrs,
                })],
            },
            primitive: wgpu::PrimitiveState { cull_mode: None, ..Default::default() },
            depth_stencil: Some(wgpu::DepthStencilState {
                format: DEPTH_FORMAT,
                depth_write_enabled: Some(true),
                depth_compare: Some(wgpu::CompareFunction::Less),
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
            multiview_mask: None,
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

        let star_buf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("sailboat stars"),
            contents: bytemuck::cast_slice(&sailboat_scene::stars::gpu_table()),
            usage: wgpu::BufferUsages::STORAGE,
        });

        SailboatGpu {
            world: RefCell::new(World::new()),
            simple_layout,
            main_layout,
            final_layout,
            sampler,
            star_buf,
            sky,
            boat,
            scene,
            composite,
            vertices,
            indices,
            index_count: idx.len() as u32,
            passes: {
                let p = std::env::var("SAILBOAT_PROFILE").unwrap_or_default();
                Passes { boat: p != "noboat", scene: p != "nocomp" }
            },
        }
    }

    /// For tools: replace the world (e.g. with forced weather).
    #[allow(dead_code)]
    pub fn set_world(&self, world: World) {
        *self.world.borrow_mut() = world;
    }

    pub fn surface(&self, device: &wgpu::Device) -> SailboatSurface {
        let uniform_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("sailboat globals"),
            size: std::mem::size_of::<Globals>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let simple_bind = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("sailboat globals"),
            layout: &self.simple_layout,
            entries: &[wgpu::BindGroupEntry { binding: 0, resource: uniform_buffer.as_entire_binding() }],
        });
        SailboatSurface { uniform_buffer, simple_bind, targets: None, last_sky: None }
    }

    fn targets(&self, device: &wgpu::Device, uniform: &wgpu::Buffer, w: u32, h: u32) -> Targets {
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
                wgpu::BindGroupEntry { binding: 0, resource: uniform.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&sky) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(&boat) },
                wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::Sampler(&self.sampler) },
            ],
        });
        let final_bind = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("sailboat final"),
            layout: &self.final_layout,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: uniform.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(&boat) },
                wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::Sampler(&self.sampler) },
                wgpu::BindGroupEntry { binding: 4, resource: wgpu::BindingResource::TextureView(&scene) },
                wgpu::BindGroupEntry { binding: 5, resource: self.star_buf.as_entire_binding() },
            ],
        });
        Targets { size: (w, h), sky, boat_ms, boat, depth, scene, main_bind, final_bind }
    }

    /// Encodes the scene into `view` (a `width` × `height` output) at
    /// wall-clock time `now` (Unix seconds).
    #[allow(clippy::too_many_arguments)]
    pub fn encode(
        &self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        encoder: &mut wgpu::CommandEncoder,
        view: &wgpu::TextureView,
        surface: &mut SailboatSurface,
        now: f64,
        width: u32,
        height: u32,
    ) {
        let (globals, sky_due) = {
            let mut world = self.world.borrow_mut();
            world.update(now);
            (world.globals(width, height), world.sky_due(surface.last_sky, now))
        };
        if surface.targets.as_ref().is_none_or(|t| t.size != (width, height)) {
            surface.targets = Some(self.targets(device, &surface.uniform_buffer, width, height));
            surface.last_sky = None;
        }
        let sky_due = sky_due || surface.last_sky.is_none();
        queue.write_buffer(&surface.uniform_buffer, 0, bytemuck::bytes_of(&globals));
        let t = surface.targets.as_ref().unwrap();

        if sky_due {
            surface.last_sky = Some(now);
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("sailboat sky"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &t.sky,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color::BLACK), store: wgpu::StoreOp::Store },
                })],
                ..Default::default()
            });
            pass.set_pipeline(&self.sky);
            pass.set_bind_group(0, &surface.simple_bind, &[]);
            pass.draw(0..3, 0..1);
        }
        if self.passes.boat {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("sailboat boat"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &t.boat_ms,
                    depth_slice: None,
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
            pass.set_pipeline(&self.boat);
            pass.set_bind_group(0, &surface.simple_bind, &[]);
            pass.set_vertex_buffer(0, self.vertices.slice(..));
            pass.set_index_buffer(self.indices.slice(..), wgpu::IndexFormat::Uint16);
            pass.draw_indexed(0..self.index_count, 0, 0..1);
        }
        if self.passes.scene {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("sailboat scene"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &t.scene,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color::BLACK), store: wgpu::StoreOp::Store },
                })],
                ..Default::default()
            });
            pass.set_pipeline(&self.scene);
            pass.set_bind_group(0, &t.main_bind, &[]);
            pass.draw(0..3, 0..1);
        }
        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("sailboat"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color::BLACK), store: wgpu::StoreOp::Store },
                })],
                ..Default::default()
            });
            pass.set_pipeline(&self.composite);
            pass.set_bind_group(0, &t.final_bind, &[]);
            pass.draw(0..3, 0..1);
        }
    }
}
