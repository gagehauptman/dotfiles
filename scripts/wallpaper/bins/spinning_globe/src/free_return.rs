//! The free-return scene (`free_return_scene`, shared with the selector
//! preview in bevy/apps/free_return) on this renderer's wgpu. Pipelines,
//! vertex buffers and the trajectory are made once at startup so switching
//! to it is instant; each surface gets its uniform buffer.
use free_return_scene::{bytemuck, Blend, Globals, SceneData, Source, DRAWS};
use wgpu::util::DeviceExt;

pub struct FreeReturnGpu {
    data: SceneData,
    bind_group_layout: wgpu::BindGroupLayout,
    pipelines: Vec<wgpu::RenderPipeline>,
    buffers: Vec<Option<wgpu::Buffer>>,
    counts: Vec<(u32, u32)>,
}

pub struct FreeReturnSurface {
    uniform_buffer: wgpu::Buffer,
    bind_group: wgpu::BindGroup,
}

impl FreeReturnGpu {
    pub fn new(device: &wgpu::Device, format: wgpu::TextureFormat) -> Self {
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("free return shader"),
            source: wgpu::ShaderSource::Wgsl(free_return_scene::SHADER.into()),
        });
        let bind_group_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("free return globals"),
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
            label: Some("free return layout"),
            bind_group_layouts: &[Some(&bind_group_layout)],
            ..Default::default()
        });

        let pair_attrs = wgpu::vertex_attr_array![0 => Float32x4, 1 => Float32x4];
        let single_attrs = wgpu::vertex_attr_array![0 => Float32x4];
        let pipelines = DRAWS
            .iter()
            .map(|d| {
                let stride = d.source.stride();
                let buffers: Vec<Option<wgpu::VertexBufferLayout>> = match stride {
                    0 => vec![],
                    _ => vec![Some(wgpu::VertexBufferLayout {
                        array_stride: stride,
                        step_mode: wgpu::VertexStepMode::Instance,
                        attributes: if stride == 32 { &pair_attrs } else { &single_attrs },
                    })],
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
                    vertex: wgpu::VertexState {
                        module: &shader,
                        entry_point: Some(d.vs),
                        compilation_options: Default::default(),
                        buffers: &buffers,
                    },
                    primitive: wgpu::PrimitiveState {
                        topology: wgpu::PrimitiveTopology::TriangleStrip,
                        cull_mode: None,
                        ..Default::default()
                    },
                    depth_stencil: None,
                    multisample: wgpu::MultisampleState::default(),
                    fragment: Some(wgpu::FragmentState {
                        module: &shader,
                        entry_point: Some(d.fs),
                        compilation_options: Default::default(),
                        targets: &[Some(wgpu::ColorTargetState { format, blend: Some(blend), write_mask: wgpu::ColorWrites::ALL })],
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
                    device.create_buffer_init(&wgpu::util::BufferInitDescriptor { label: Some("free return scene"), contents, usage: wgpu::BufferUsages::VERTEX })
                })
            })
            .collect();
        let counts = Source::ALL.iter().map(|&s| data.counts(s)).collect();

        FreeReturnGpu { data, bind_group_layout, pipelines, buffers, counts }
    }

    pub fn surface(&self, device: &wgpu::Device) -> FreeReturnSurface {
        let uniform_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("free return globals"),
            size: std::mem::size_of::<Globals>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("free return globals"),
            layout: &self.bind_group_layout,
            entries: &[wgpu::BindGroupEntry { binding: 0, resource: uniform_buffer.as_entire_binding() }],
        });
        FreeReturnSurface { uniform_buffer, bind_group }
    }

    /// The scene's parameters for a `width` × `height` output at wall-clock
    /// time `t` (Unix seconds).
    pub fn globals(&self, t: f64, width: u32, height: u32) -> Globals {
        Globals::at_secs(t, width, height, &self.data)
    }

    /// Encodes the whole scene into `view`.
    pub fn encode(&self, queue: &wgpu::Queue, encoder: &mut wgpu::CommandEncoder, view: &wgpu::TextureView, surface: &FreeReturnSurface, globals: &Globals) {
        queue.write_buffer(&surface.uniform_buffer, 0, bytemuck::bytes_of(globals));
        let [r, g, b] = free_return_scene::BG;
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("free return"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view,
                depth_slice: None,
                resolve_target: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color { r, g, b, a: 1.0 }), store: wgpu::StoreOp::Store },
            })],
            ..Default::default()
        });
        pass.set_bind_group(0, &surface.bind_group, &[]);
        for (d, pipeline) in DRAWS.iter().zip(&self.pipelines) {
            let i = d.source.index();
            pass.set_pipeline(pipeline);
            if let Some(buffer) = &self.buffers[i] {
                pass.set_vertex_buffer(0, buffer.slice(..));
            }
            let (vertices, instances) = self.counts[i];
            pass.draw(0..vertices, 0..instances);
        }
    }
}
