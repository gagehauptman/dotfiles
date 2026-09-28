//! The space shuttle scene (`shuttle_scene`, shared with the selector preview
//! in bevy/apps/space_shuttle) on this renderer's wgpu. Pipelines and vertex
//! buffers are made once at startup so switching to it is instant; each
//! surface gets its uniform buffer, and a depth target only while it shows
//! the shuttle.
use shuttle_scene::{bytemuck, Blend, DepthMode, Globals, SceneData, Source, DRAWS, PREPASS_DRAWS};
use wgpu::util::DeviceExt;

const DEPTH_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Depth32Float;

pub struct ShuttleGpu {
    bind_group_layout: wgpu::BindGroupLayout,
    depth_layout: wgpu::BindGroupLayout,
    pipelines: Vec<wgpu::RenderPipeline>,
    buffers: Vec<Option<wgpu::Buffer>>,
    counts: Vec<(u32, u32)>,
}

pub struct ShuttleSurface {
    uniform_buffer: wgpu::Buffer,
    bind_group: wgpu::BindGroup,
    /// The depth target, its size and a bind group of it for the edges.
    depth: Option<(wgpu::TextureView, (u32, u32), wgpu::BindGroup)>,
}

impl ShuttleSurface {
    /// Frees the depth target (while hidden or showing another scene).
    pub fn release(&mut self) {
        self.depth = None;
    }
}

impl ShuttleGpu {
    pub fn new(device: &wgpu::Device, format: wgpu::TextureFormat) -> Self {
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("shuttle shader"),
            source: wgpu::ShaderSource::Wgsl(shuttle_scene::SHADER.into()),
        });
        let bind_group_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("shuttle globals"),
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            }],
        });
        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("shuttle layout"),
            bind_group_layouts: &[Some(&bind_group_layout)],
            ..Default::default()
        });
        let depth_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("shuttle depth"),
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Texture {
                    sample_type: wgpu::TextureSampleType::Depth,
                    view_dimension: wgpu::TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            }],
        });
        let sampled_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("shuttle edges layout"),
            bind_group_layouts: &[Some(&bind_group_layout), Some(&depth_layout)],
            ..Default::default()
        });

        let instance_attrs = wgpu::vertex_attr_array![0 => Float32x4, 1 => Float32x4];
        let vertex_attrs = wgpu::vertex_attr_array![0 => Float32x4];
        let pipelines = DRAWS
            .iter()
            .map(|d| {
                let buffers: Vec<Option<wgpu::VertexBufferLayout>> = if d.source.instanced() {
                    vec![Some(wgpu::VertexBufferLayout { array_stride: 32, step_mode: wgpu::VertexStepMode::Instance, attributes: &instance_attrs })]
                } else if d.source == Source::Mesh {
                    vec![Some(wgpu::VertexBufferLayout { array_stride: 16, step_mode: wgpu::VertexStepMode::Vertex, attributes: &vertex_attrs })]
                } else {
                    vec![]
                };
                let (compare, write) = match d.depth {
                    DepthMode::Prepass => (wgpu::CompareFunction::Less, true),
                    DepthMode::Test => (wgpu::CompareFunction::LessEqual, false),
                    DepthMode::Sampled => (wgpu::CompareFunction::Always, false),
                };
                let blend = |operation| wgpu::BlendState {
                    color: wgpu::BlendComponent { src_factor: wgpu::BlendFactor::One, dst_factor: wgpu::BlendFactor::One, operation },
                    alpha: wgpu::BlendComponent::REPLACE,
                };
                let (blend, write_mask) = match d.blend {
                    Blend::Add => (Some(blend(wgpu::BlendOperation::Add)), wgpu::ColorWrites::ALL),
                    Blend::Max => (Some(blend(wgpu::BlendOperation::Max)), wgpu::ColorWrites::ALL),
                    Blend::DepthOnly => (None, wgpu::ColorWrites::empty()),
                };
                device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                    label: Some(d.label),
                    layout: Some(if d.depth == DepthMode::Sampled { &sampled_layout } else { &layout }),
                    vertex: wgpu::VertexState {
                        module: &shader,
                        entry_point: Some(d.vs),
                        compilation_options: Default::default(),
                        buffers: &buffers,
                    },
                    primitive: wgpu::PrimitiveState {
                        topology: if d.source.strip() { wgpu::PrimitiveTopology::TriangleStrip } else { wgpu::PrimitiveTopology::TriangleList },
                        cull_mode: None,
                        ..Default::default()
                    },
                    depth_stencil: Some(wgpu::DepthStencilState {
                        format: DEPTH_FORMAT,
                        depth_write_enabled: Some(write),
                        depth_compare: Some(compare),
                        stencil: Default::default(),
                        bias: Default::default(),
                    }),
                    multisample: wgpu::MultisampleState::default(),
                    fragment: Some(wgpu::FragmentState {
                        module: &shader,
                        entry_point: Some(d.fs),
                        compilation_options: Default::default(),
                        targets: &[Some(wgpu::ColorTargetState { format, blend, write_mask })],
                    }),
                    multiview_mask: None,
                    cache: None,
                })
            })
            .collect();

        let data = SceneData::build();
        let buffers = Source::ALL
            .iter()
            .map(|&s| {
                data.bytes(s).map(|contents| {
                    device.create_buffer_init(&wgpu::util::BufferInitDescriptor { label: Some("shuttle scene"), contents, usage: wgpu::BufferUsages::VERTEX })
                })
            })
            .collect();
        let counts = Source::ALL.iter().map(|&s| data.counts(s)).collect();

        ShuttleGpu { bind_group_layout, depth_layout, pipelines, buffers, counts }
    }

    pub fn surface(&self, device: &wgpu::Device) -> ShuttleSurface {
        let uniform_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("shuttle globals"),
            size: std::mem::size_of::<Globals>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("shuttle globals"),
            layout: &self.bind_group_layout,
            entries: &[wgpu::BindGroupEntry { binding: 0, resource: uniform_buffer.as_entire_binding() }],
        });
        ShuttleSurface { uniform_buffer, bind_group, depth: None }
    }

    /// Encodes the whole scene into `view` (a `width` × `height` output).
    pub fn encode(
        &self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        encoder: &mut wgpu::CommandEncoder,
        view: &wgpu::TextureView,
        surface: &mut ShuttleSurface,
        globals: &Globals,
    ) {
        let size = (globals.viewport[0] as u32, globals.viewport[1] as u32);
        if surface.depth.as_ref().map_or(true, |d| d.1 != size) {
            let texture = device.create_texture(&wgpu::TextureDescriptor {
                label: Some("shuttle depth"),
                size: wgpu::Extent3d { width: size.0, height: size.1, depth_or_array_layers: 1 },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: DEPTH_FORMAT,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING,
                view_formats: &[],
            });
            let view = texture.create_view(&Default::default());
            let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("shuttle depth"),
                layout: &self.depth_layout,
                entries: &[wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(&view) }],
            });
            surface.depth = Some((view, size, bind_group));
        }
        queue.write_buffer(&surface.uniform_buffer, 0, bytemuck::bytes_of(globals));

        let [r, g, b] = shuttle_scene::BG;
        let (depth, _, depth_bind) = surface.depth.as_ref().unwrap();
        // The orbiter's surfaces' depth in a pass of its own, then the rest
        // with it read-only, as the edges also read it as a texture.
        for (first, draws) in [(true, 0..PREPASS_DRAWS), (false, PREPASS_DRAWS..DRAWS.len())] {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("shuttle"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: if first { wgpu::LoadOp::Clear(wgpu::Color { r, g, b, a: 1.0 }) } else { wgpu::LoadOp::Load },
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
                    view: depth,
                    depth_ops: first.then_some(wgpu::Operations { load: wgpu::LoadOp::Clear(1.0), store: wgpu::StoreOp::Store }),
                    stencil_ops: None,
                }),
                ..Default::default()
            });
            pass.set_bind_group(0, &surface.bind_group, &[]);
            for (d, pipeline) in DRAWS[draws.clone()].iter().zip(&self.pipelines[draws]) {
                let i = d.source.index();
                pass.set_pipeline(pipeline);
                if d.depth == DepthMode::Sampled {
                    pass.set_bind_group(1, depth_bind, &[]);
                }
                if let Some(buffer) = &self.buffers[i] {
                    pass.set_vertex_buffer(0, buffer.slice(..));
                }
                let (vertices, instances) = self.counts[i];
                pass.draw(0..vertices, 0..instances);
            }
        }
    }
}
