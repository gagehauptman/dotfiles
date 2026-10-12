//! The Sputnik scene (`sputnik_scene`) on this renderer's wgpu. Pipelines, the
//! static orbit lines, the land mask and the font atlas are made once at
//! startup so switching to it is instant; each surface gets its uniform
//! buffer and two small buffers rewritten every frame (ground track,
//! antennas and streaks; text).
use sputnik_scene::{bytemuck, Frame, Glyph, Globals, Line, SceneData, LAND_H, LAND_W};
use wgpu::util::DeviceExt;

const DYN_LINES: usize = 512;
const DYN_GLYPHS: usize = 1024;

pub struct SputnikGpu {
    data: SceneData,
    bind_group_layout: wgpu::BindGroupLayout,
    land: wgpu::TextureView,
    atlas: wgpu::TextureView,
    sampler: wgpu::Sampler,
    sky: wgpu::RenderPipeline,
    lines: wgpu::RenderPipeline,
    ball: wgpu::RenderPipeline,
    text: wgpu::RenderPipeline,
    static_lines: wgpu::Buffer,
    static_count: u32,
}

pub struct SputnikSurface {
    uniform_buffer: wgpu::Buffer,
    bind_group: wgpu::BindGroup,
    dyn_lines: wgpu::Buffer,
    glyphs: wgpu::Buffer,
    frame: Frame,
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

impl SputnikGpu {
    pub fn new(device: &wgpu::Device, queue: &wgpu::Queue, format: wgpu::TextureFormat) -> Self {
        let data = SceneData::build();
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("sputnik shader"),
            source: wgpu::ShaderSource::Wgsl(sputnik_scene::SHADER.into()),
        });
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
        let bind_group_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("sputnik globals"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
                    ty: wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform, has_dynamic_offset: false, min_binding_size: None },
                    count: None,
                },
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
            bind_group_layouts: &[Some(&bind_group_layout)],
            ..Default::default()
        });

        let land = texture_r8(device, queue, "sputnik land", LAND_W, LAND_H, &data.land);
        let atlas = match &data.atlas {
            Some(a) => texture_r8(device, queue, "sputnik font", a.w, a.h, &a.pixels),
            None => {
                eprintln!("sputnik: no usable font found, no lettering");
                texture_r8(device, queue, "sputnik font", 1, 1, &[0])
            }
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
            let buffers: Vec<Option<wgpu::VertexBufferLayout>> = if stride == 0 {
                vec![]
            } else {
                vec![Some(wgpu::VertexBufferLayout { array_stride: stride, step_mode: wgpu::VertexStepMode::Instance, attributes: attrs })]
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
                multisample: wgpu::MultisampleState::default(),
                fragment: Some(wgpu::FragmentState {
                    module: &shader,
                    entry_point: Some(fs),
                    compilation_options: Default::default(),
                    targets: &[Some(wgpu::ColorTargetState {
                        format,
                        blend: if replace { None } else { Some(wgpu::BlendState { color: over, alpha: over }) },
                        write_mask: wgpu::ColorWrites::ALL,
                    })],
                }),
                multiview_mask: None,
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

        SputnikGpu { data, bind_group_layout, land, atlas, sampler, sky, lines, ball, text, static_lines, static_count }
    }

    pub fn surface(&self, device: &wgpu::Device) -> SputnikSurface {
        let uniform_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("sputnik globals"),
            size: std::mem::size_of::<Globals>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("sputnik globals"),
            layout: &self.bind_group_layout,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: uniform_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&self.land) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::Sampler(&self.sampler) },
                wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::TextureView(&self.atlas) },
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
        SputnikSurface {
            uniform_buffer,
            bind_group,
            dyn_lines: vertex_buffer("sputnik dynamic lines", DYN_LINES * std::mem::size_of::<Line>()),
            glyphs: vertex_buffer("sputnik glyphs", DYN_GLYPHS * std::mem::size_of::<Glyph>()),
            frame: Frame::default(),
        }
    }

    /// Encodes the whole scene into `view` (a `width` × `height` output) at
    /// wall-clock time `now` (Unix seconds).
    pub fn encode(&self, queue: &wgpu::Queue, encoder: &mut wgpu::CommandEncoder, view: &wgpu::TextureView, surface: &mut SputnikSurface, now: f64, width: u32, height: u32) {
        let frame = &mut surface.frame;
        self.data.frame(now, width, height, frame);
        frame.lines.truncate(DYN_LINES);
        frame.text.truncate(DYN_GLYPHS);
        let ground = frame.ground.min(frame.lines.len());
        queue.write_buffer(&surface.uniform_buffer, 0, bytemuck::bytes_of(frame.globals.as_ref().unwrap()));
        queue.write_buffer(&surface.dyn_lines, 0, bytemuck::cast_slice(&frame.lines));
        queue.write_buffer(&surface.glyphs, 0, bytemuck::cast_slice(&frame.text));

        let [r, g, b] = sputnik_scene::BG;
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("sputnik"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view,
                depth_slice: None,
                resolve_target: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color { r, g, b, a: 1.0 }), store: wgpu::StoreOp::Store },
            })],
            ..Default::default()
        });
        pass.set_bind_group(0, &surface.bind_group, &[]);
        pass.set_pipeline(&self.sky);
        pass.draw(0..4, 0..1);

        pass.set_pipeline(&self.lines);
        pass.set_vertex_buffer(0, self.static_lines.slice(..));
        pass.draw(0..4, 0..self.static_count);
        pass.set_vertex_buffer(0, surface.dyn_lines.slice(..));
        pass.draw(0..4, 0..ground as u32);

        pass.set_pipeline(&self.ball);
        pass.draw(0..4, 0..1);

        pass.set_pipeline(&self.lines);
        pass.set_vertex_buffer(0, surface.dyn_lines.slice(..));
        pass.draw(0..4, ground as u32..frame.lines.len() as u32);

        if !frame.text.is_empty() {
            pass.set_pipeline(&self.text);
            pass.set_vertex_buffer(0, surface.glyphs.slice(..));
            pass.draw(0..4, 0..frame.text.len() as u32);
        }
    }
}
