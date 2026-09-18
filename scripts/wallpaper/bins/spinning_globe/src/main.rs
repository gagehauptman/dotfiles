mod continents;

use smithay_client_toolkit::{
    compositor::{CompositorHandler, CompositorState},
    delegate_compositor, delegate_layer, delegate_output, delegate_registry,
    output::{OutputHandler, OutputState},
    registry::{ProvidesRegistryState, RegistryState},
    registry_handlers,
    shell::{
        wlr_layer::{
            Anchor, KeyboardInteractivity, Layer, LayerShell, LayerShellHandler, LayerSurface,
            LayerSurfaceConfigure,
        },
        WaylandSurface,
    },
};
use wayland_client::{
    globals::registry_queue_init,
    protocol::{wl_output, wl_surface},
    Connection, Proxy, QueueHandle,
};
use wgpu::rwh::{RawDisplayHandle, RawWindowHandle, WaylandDisplayHandle, WaylandWindowHandle};
use wgpu::util::DeviceExt;
use rustix::event::{poll, PollFd, PollFlags, Timespec};
use std::f32::consts::PI;
use std::ptr::NonNull;
use std::time::{Duration, Instant};

use continents::ALL_LANDMASSES;

const SHADER: &str = include_str!("globe.wgsl");

// The globe rotates slowly, so 30 fps is plenty. Override with `--fps N` or
// the GLOBE_FPS env var; 0 disables the cap (frame callbacks still pace us).
const DEFAULT_FPS: u32 = 30;

fn main() {
    let frame_interval = fps_cap_from_args();

    let conn = Connection::connect_to_env().expect("Failed to connect to Wayland");
    let (globals, mut event_queue) = registry_queue_init(&conn).expect("Failed to init registry");
    let qh = event_queue.handle();

    let compositor = CompositorState::bind(&globals, &qh).expect("wl_compositor not available");
    let layer_shell = LayerShell::bind(&globals, &qh).expect("layer shell not available");

    let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
        backends: wgpu::Backends::VULKAN,
        ..wgpu::InstanceDescriptor::new_without_display_handle()
    });

    let mut state = AppState {
        registry_state: RegistryState::new(&globals),
        output_state: OutputState::new(&globals, &qh),
        compositor,
        layer_shell,
        conn: conn.clone(),
        instance,
        gpu: None,
        surfaces: Vec::new(),
        start_time: Instant::now(),
        frame_interval,
        frozen_rotation: std::env::var("GLOBE_ROTATION").ok().and_then(|v| v.parse().ok()),
    };

    // Surfaces are created per-output as new_output fires (covers both the
    // outputs present at startup and any hotplugged later).
    //
    // Event loop: draw whatever is due, then sleep on the Wayland socket until
    // either an event arrives or the next capped frame is due.
    loop {
        let timeout = state.draw_due(&qh);

        event_queue.flush().expect("Wayland connection lost");
        if event_queue.dispatch_pending(&mut state).unwrap() > 0 {
            continue;
        }
        let Some(guard) = event_queue.prepare_read() else {
            continue;
        };

        let timeout = timeout.map(|d| Timespec {
            tv_sec: d.as_secs() as i64,
            tv_nsec: d.subsec_nanos() as i64,
        });
        let ready = {
            let mut fds = [PollFd::from_borrowed_fd(guard.connection_fd(), PollFlags::IN)];
            match poll(&mut fds, timeout.as_ref()) {
                Ok(n) => n > 0,
                Err(rustix::io::Errno::INTR) => false,
                Err(e) => panic!("poll on Wayland socket failed: {e}"),
            }
        };
        if ready {
            // WouldBlock just means another thread (Mesa's WSI) already read.
            let _ = guard.read();
        } else {
            drop(guard);
        }

        event_queue.dispatch_pending(&mut state).unwrap();
    }
}

fn fps_cap_from_args() -> Option<Duration> {
    let mut fps = std::env::var("GLOBE_FPS").ok().and_then(|v| v.parse::<u32>().ok());

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        if arg == "--fps" {
            fps = args.next().and_then(|v| v.parse().ok());
        } else if let Some(v) = arg.strip_prefix("--fps=") {
            fps = v.parse().ok();
        }
    }

    match fps.unwrap_or(DEFAULT_FPS) {
        0 => None,
        n => Some(Duration::from_secs_f64(1.0 / n as f64)),
    }
}

struct GlobeSurface {
    // Declared first so the swapchain is torn down before the wl_surface.
    gpu_surface: wgpu::Surface<'static>,
    uniform_buffer: wgpu::Buffer,
    bind_group: wgpu::BindGroup,
    output: wl_output::WlOutput,
    layer_surface: LayerSurface,
    width: u32,
    height: u32,
    // Size the swapchain is currently configured for
    swapchain_size: (u32, u32),
    configured: bool,
    frame_pending: bool,
    needs_redraw: bool,
    next_frame_at: Instant,
}

struct AppState {
    registry_state: RegistryState,
    output_state: OutputState,
    compositor: CompositorState,
    layer_shell: LayerShell,
    conn: Connection,
    instance: wgpu::Instance,
    // Created lazily with the first surface (adapter selection needs one).
    gpu: Option<Gpu>,
    surfaces: Vec<GlobeSurface>,
    start_time: Instant,
    frame_interval: Option<Duration>,
    frozen_rotation: Option<f32>,
}

// Catppuccin Mocha colors (the teal/green are in globe.wgsl)
const BG_R: u8 = 30;  // Base #1e1e2e
const BG_G: u8 = 30;
const BG_B: u8 = 46;

const TEAL_GRID_INTENSITY: f32 = 0.25;
const TEAL_OUTLINE_INTENSITY: f32 = 0.5;

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct Globals {
    viewport: [f32; 2],
    center: [f32; 2],
    radius: f32,
    rotation: f32,
    _pad: [f32; 2],
}

/// One glowing pixel: a point on the globe (kind 0, lon/lat in radians) or a
/// point on the fixed outline circle (kind 1, screen angle in radians).
#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct PointInstance {
    lon_lat: [f32; 2],
    intensity: f32,
    kind: f32,
}

/// One continent sub-segment, both ends as lon/lat in radians.
#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct LineInstance {
    a: [f32; 2],
    b: [f32; 2],
}

struct Gpu {
    device: wgpu::Device,
    queue: wgpu::Queue,
    bind_group_layout: wgpu::BindGroupLayout,
    line_pipeline: wgpu::RenderPipeline,
    point_pipeline: wgpu::RenderPipeline,
    line_buffer: wgpu::Buffer,
    line_count: u32,
    point_buffer: wgpu::Buffer,
    point_count: u32,
    format: wgpu::TextureFormat,
    view_format: wgpu::TextureFormat,
    present_mode: wgpu::PresentMode,
    alpha_mode: wgpu::CompositeAlphaMode,
}

impl Gpu {
    fn new(instance: &wgpu::Instance, surface: &wgpu::Surface<'_>) -> Result<Self, String> {
        // WGPU_ADAPTER_NAME / WGPU_POWER_PREF are honoured if set.
        let adapter = pollster::block_on(async {
            match wgpu::util::initialize_adapter_from_env(instance, Some(surface)).await {
                Ok(a) => Ok(a),
                Err(_) => {
                    instance
                        .request_adapter(&wgpu::RequestAdapterOptions {
                            power_preference: wgpu::PowerPreference::HighPerformance,
                            compatible_surface: Some(surface),
                            ..Default::default()
                        })
                        .await
                }
            }
        })
        .map_err(|e| format!("no Vulkan adapter that can present to this Wayland surface ({e})"))?;

        let info = adapter.get_info();
        eprintln!("spinning_globe: using {} ({:?}, {})", info.name, info.backend, info.driver);

        let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
            label: Some("globe device"),
            ..Default::default()
        }))
        .map_err(|e| format!("failed to create Vulkan device: {e}"))?;

        // Pick a plain (non-sRGB) 8-bit format so the additive maths happens in
        // the same 8-bit space as the old Argb8888 buffer. If only sRGB formats
        // exist, render through a non-sRGB view of the same texture.
        let caps = surface.get_capabilities(&adapter);
        if caps.formats.is_empty() {
            return Err("surface reports no supported formats".into());
        }
        let format = caps
            .formats
            .iter()
            .copied()
            .find(|f| matches!(f, wgpu::TextureFormat::Bgra8Unorm | wgpu::TextureFormat::Rgba8Unorm))
            .unwrap_or(caps.formats[0]);
        let view_format = format.remove_srgb_suffix();

        // Mailbox never blocks in present, which matters for a wallpaper whose
        // output may be off; we pace ourselves with frame callbacks anyway.
        let present_mode = [wgpu::PresentMode::Mailbox, wgpu::PresentMode::Fifo]
            .into_iter()
            .find(|m| caps.present_modes.contains(m))
            .unwrap_or(caps.present_modes[0]);
        let alpha_mode = if caps.alpha_modes.contains(&wgpu::CompositeAlphaMode::Opaque) {
            wgpu::CompositeAlphaMode::Opaque
        } else {
            caps.alpha_modes[0]
        };
        eprintln!("spinning_globe: format {format:?}, present mode {present_mode:?}");

        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("globe shader"),
            source: wgpu::ShaderSource::Wgsl(SHADER.into()),
        });

        let bind_group_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("globals"),
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::VERTEX,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            }],
        });
        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("globe layout"),
            bind_group_layouts: &[Some(&bind_group_layout)],
            ..Default::default()
        });

        let make_pipeline = |label: &str, vs: &str, fs: &str, stride: u64, attrs: &[wgpu::VertexAttribute], blend: wgpu::BlendComponent| {
            device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some(label),
                layout: Some(&pipeline_layout),
                vertex: wgpu::VertexState {
                    module: &shader,
                    entry_point: Some(vs),
                    compilation_options: Default::default(),
                    buffers: &[Some(wgpu::VertexBufferLayout {
                        array_stride: stride,
                        step_mode: wgpu::VertexStepMode::Instance,
                        attributes: attrs,
                    })],
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
                    entry_point: Some(fs),
                    compilation_options: Default::default(),
                    targets: &[Some(wgpu::ColorTargetState {
                        format: view_format,
                        blend: Some(wgpu::BlendState { color: blend, alpha: wgpu::BlendComponent::REPLACE }),
                        write_mask: wgpu::ColorWrites::ALL,
                    })],
                }),
                multiview_mask: None,
                cache: None,
            })
        };

        // Continent lines: MAX blend so overlapping sub-segments don't pile up.
        let line_pipeline = make_pipeline(
            "continent lines",
            "vs_line",
            "fs_line",
            std::mem::size_of::<LineInstance>() as u64,
            &wgpu::vertex_attr_array![0 => Float32x2, 1 => Float32x2],
            wgpu::BlendComponent {
                src_factor: wgpu::BlendFactor::One,
                dst_factor: wgpu::BlendFactor::One,
                operation: wgpu::BlendOperation::Max,
            },
        );
        // Grid/outline points: additive, exactly like draw_glow_pixel.
        let point_pipeline = make_pipeline(
            "glow points",
            "vs_point",
            "fs_point",
            std::mem::size_of::<PointInstance>() as u64,
            &wgpu::vertex_attr_array![0 => Float32x2, 1 => Float32, 2 => Float32],
            wgpu::BlendComponent {
                src_factor: wgpu::BlendFactor::One,
                dst_factor: wgpu::BlendFactor::One,
                operation: wgpu::BlendOperation::Add,
            },
        );

        let lines = build_continent_lines();
        let points = build_points();
        let line_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("continent lines"),
            contents: bytemuck::cast_slice(&lines),
            usage: wgpu::BufferUsages::VERTEX,
        });
        let point_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("glow points"),
            contents: bytemuck::cast_slice(&points),
            usage: wgpu::BufferUsages::VERTEX,
        });

        Ok(Gpu {
            device,
            queue,
            bind_group_layout,
            line_pipeline,
            point_pipeline,
            line_buffer,
            line_count: lines.len() as u32,
            point_buffer,
            point_count: points.len() as u32,
            format,
            view_format,
            present_mode,
            alpha_mode,
        })
    }

    fn configure_surface(&self, surface: &wgpu::Surface<'_>, width: u32, height: u32) {
        surface.configure(
            &self.device,
            &wgpu::SurfaceConfiguration {
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                format: self.format,
                color_space: wgpu::SurfaceColorSpace::default(),
                width,
                height,
                present_mode: self.present_mode,
                desired_maximum_frame_latency: 2,
                alpha_mode: self.alpha_mode,
                view_formats: if self.view_format == self.format { vec![] } else { vec![self.view_format] },
            },
        );
    }
}

/// Lat/lon grid dots and the globe outline, same sampling as the CPU loops.
fn build_points() -> Vec<PointInstance> {
    let mut points = Vec::new();

    // Latitude lines (every 30 degrees)
    for lat_deg in (-60..=60).step_by(30) {
        let lat = (lat_deg as f32).to_radians();
        for lon_deg in 0..360 {
            let lon = (lon_deg as f32).to_radians();
            points.push(PointInstance { lon_lat: [lon, lat], intensity: TEAL_GRID_INTENSITY, kind: 0.0 });
        }
    }

    // Longitude lines (every 30 degrees)
    for lon_deg in (0..180).step_by(30) {
        let lon = (lon_deg as f32).to_radians();
        for lat_deg in -90..=90 {
            let lat = (lat_deg as f32).to_radians();
            points.push(PointInstance { lon_lat: [lon, lat], intensity: TEAL_GRID_INTENSITY, kind: 0.0 });
            points.push(PointInstance { lon_lat: [lon + PI, lat], intensity: TEAL_GRID_INTENSITY, kind: 0.0 });
        }
    }

    // Globe outline
    for angle in 0..720 {
        let a = (angle as f32) * PI / 360.0;
        points.push(PointInstance { lon_lat: [a, 0.0], intensity: TEAL_OUTLINE_INTENSITY, kind: 1.0 });
    }

    points
}

/// Every landmass edge, interpolated in lat/lon space exactly like
/// draw_continent() did; each step becomes one line instance.
fn build_continent_lines() -> Vec<LineInstance> {
    let mut lines = Vec::new();

    for points in ALL_LANDMASSES {
        if points.len() < 2 {
            continue;
        }

        for i in 0..points.len() {
            let (lon1, lat1) = points[i];
            let (lon2, lat2) = points[(i + 1) % points.len()];

            let lat1_rad = lat1.to_radians();
            let lon1_rad = lon1.to_radians();
            let lat2_rad = lat2.to_radians();
            let lon2_rad = lon2.to_radians();

            // More interpolation steps for smoother lines
            let dist = ((lat2 - lat1).powi(2) + (lon2 - lon1).powi(2)).sqrt();
            let steps = ((dist * 3.0) as i32).max(20);

            let at = |s: i32| {
                let t = s as f32 / steps as f32;
                [lon1_rad + (lon2_rad - lon1_rad) * t, lat1_rad + (lat2_rad - lat1_rad) * t]
            };
            for s in 1..=steps {
                lines.push(LineInstance { a: at(s - 1), b: at(s) });
            }
        }
    }

    lines
}

impl AppState {
    fn create_surface_for_output(&mut self, qh: &QueueHandle<Self>, output: wl_output::WlOutput) {
        if self.surfaces.iter().any(|s| s.output.id() == output.id()) {
            return;
        }

        let surface = self.compositor.create_surface(qh);
        let layer_surface = self.layer_shell.create_layer_surface(
            qh,
            surface,
            Layer::Background,
            Some("wargames-globe"),
            Some(&output),
        );

        layer_surface.set_anchor(Anchor::all());
        layer_surface.set_exclusive_zone(-1);
        layer_surface.set_keyboard_interactivity(KeyboardInteractivity::None);
        layer_surface.commit();

        // wgpu surface straight on the layer surface's wl_surface. Creating it
        // doesn't attach a buffer, so this is fine before the first configure.
        let display = NonNull::new(self.conn.backend().display_ptr() as *mut _).expect("null wl_display");
        let wl_surface = NonNull::new(layer_surface.wl_surface().id().as_ptr() as *mut _).expect("null wl_surface");
        let gpu_surface = unsafe {
            self.instance.create_surface_unsafe(wgpu::SurfaceTargetUnsafe::RawHandle {
                raw_display_handle: Some(RawDisplayHandle::Wayland(WaylandDisplayHandle::new(display))),
                raw_window_handle: RawWindowHandle::Wayland(WaylandWindowHandle::new(wl_surface)),
            })
        }
        .expect("failed to create wgpu surface on wl_surface");

        if self.gpu.is_none() {
            match Gpu::new(&self.instance, &gpu_surface) {
                Ok(gpu) => self.gpu = Some(gpu),
                Err(e) => {
                    eprintln!("spinning_globe: GPU init failed: {e}");
                    eprintln!("spinning_globe: a working Vulkan driver (e.g. vulkan-radeon) is required; exiting.");
                    std::process::exit(1);
                }
            }
        }
        let gpu = self.gpu.as_ref().unwrap();

        let uniform_buffer = gpu.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("globals"),
            size: std::mem::size_of::<Globals>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let bind_group = gpu.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("globals"),
            layout: &gpu.bind_group_layout,
            entries: &[wgpu::BindGroupEntry { binding: 0, resource: uniform_buffer.as_entire_binding() }],
        });

        self.surfaces.push(GlobeSurface {
            gpu_surface,
            uniform_buffer,
            bind_group,
            output,
            layer_surface,
            width: 0,
            height: 0,
            swapchain_size: (0, 0),
            configured: false,
            frame_pending: false,
            needs_redraw: false,
            next_frame_at: Instant::now(),
        });
    }

    fn surface_index(&self, wl_surface: &wl_surface::WlSurface) -> Option<usize> {
        self.surfaces
            .iter()
            .position(|s| s.layer_surface.wl_surface().id() == wl_surface.id())
    }

    /// Draws every surface whose frame callback has fired and whose FPS-cap
    /// slot has come; returns how long until the earliest one still waiting.
    fn draw_due(&mut self, qh: &QueueHandle<Self>) -> Option<Duration> {
        let now = Instant::now();
        let mut timeout: Option<Duration> = None;

        for idx in 0..self.surfaces.len() {
            let s = &self.surfaces[idx];
            if !s.configured || !s.needs_redraw || s.frame_pending {
                continue;
            }
            if s.next_frame_at <= now {
                self.draw(idx, qh);
            } else {
                let wait = s.next_frame_at - now;
                timeout = Some(timeout.map_or(wait, |t| t.min(wait)));
            }
        }

        timeout
    }

    fn draw(&mut self, idx: usize, qh: &QueueHandle<Self>) {
        let time = self.start_time.elapsed().as_secs_f32();
        let gpu = self.gpu.as_ref().expect("GPU initialised with first surface");
        let s = &mut self.surfaces[idx];
        let width = s.width;
        let height = s.height;

        if width == 0 || height == 0 {
            return;
        }

        if s.swapchain_size != (width, height) {
            gpu.configure_surface(&s.gpu_surface, width, height);
            s.swapchain_size = (width, height);
        }

        use wgpu::CurrentSurfaceTexture as Cst;
        let frame = match s.gpu_surface.get_current_texture() {
            Cst::Success(frame) | Cst::Suboptimal(frame) => frame,
            Cst::Outdated | Cst::Lost => {
                // Reconfigure and try again on the next loop iteration.
                s.swapchain_size = (0, 0);
                s.needs_redraw = true;
                return;
            }
            Cst::Timeout | Cst::Occluded => {
                s.needs_redraw = true;
                s.next_frame_at = Instant::now() + Duration::from_millis(16);
                return;
            }
            Cst::Validation => panic!("failed to acquire swapchain image: validation error"),
        };
        let view = frame.texture.create_view(&wgpu::TextureViewDescriptor {
            format: Some(gpu.view_format),
            ..Default::default()
        });

        // Globe parameters
        let globe_radius = (height.min(width) as f32 * 0.35) as i32;
        let center_x = width as f32 / 2.0;
        let center_y = height as f32 / 2.0;

        // Rotation angle (shared start_time keeps all monitors in sync);
        // GLOBE_ROTATION=<radians> freezes it, handy for comparing renders.
        let rotation = self.frozen_rotation.unwrap_or(time * 0.15);

        gpu.queue.write_buffer(
            &s.uniform_buffer,
            0,
            bytemuck::bytes_of(&Globals {
                viewport: [width as f32, height as f32],
                center: [center_x, center_y],
                radius: globe_radius as f32,
                rotation,
                _pad: [0.0; 2],
            }),
        );

        let mut encoder = gpu.device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("globe") });
        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("globe"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        // Clear to background
                        load: wgpu::LoadOp::Clear(wgpu::Color {
                            r: BG_R as f64 / 255.0,
                            g: BG_G as f64 / 255.0,
                            b: BG_B as f64 / 255.0,
                            a: 1.0,
                        }),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                ..Default::default()
            });
            pass.set_bind_group(0, &s.bind_group, &[]);

            // Landmasses first (MAX blend), then the additive grid and outline.
            pass.set_pipeline(&gpu.line_pipeline);
            pass.set_vertex_buffer(0, gpu.line_buffer.slice(..));
            pass.draw(0..4, 0..gpu.line_count);

            pass.set_pipeline(&gpu.point_pipeline);
            pass.set_vertex_buffer(0, gpu.point_buffer.slice(..));
            pass.draw(0..4, 0..gpu.point_count);
        }
        gpu.queue.submit(Some(encoder.finish()));

        // Request the next frame callback before present() commits the surface.
        let surface = s.layer_surface.wl_surface();
        if !s.frame_pending {
            surface.frame(qh, surface.clone());
            s.frame_pending = true;
        }

        gpu.queue.present(frame);

        s.needs_redraw = false;
        if let Some(interval) = self.frame_interval {
            s.next_frame_at = Instant::now() + interval;
        }
    }
}

impl CompositorHandler for AppState {
    fn scale_factor_changed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: i32) {}
    fn transform_changed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: wl_output::Transform) {}
    fn frame(&mut self, _: &Connection, _: &QueueHandle<Self>, surface: &wl_surface::WlSurface, _: u32) {
        if let Some(idx) = self.surface_index(surface) {
            let s = &mut self.surfaces[idx];
            s.frame_pending = false;
            // The main loop draws it once the FPS-cap slot comes up.
            s.needs_redraw = true;
        }
    }
    fn surface_enter(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: &wl_output::WlOutput) {}
    fn surface_leave(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: &wl_output::WlOutput) {}
}

impl OutputHandler for AppState {
    fn output_state(&mut self) -> &mut OutputState { &mut self.output_state }
    fn new_output(&mut self, _: &Connection, qh: &QueueHandle<Self>, output: wl_output::WlOutput) {
        self.create_surface_for_output(qh, output);
    }
    fn update_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
    fn output_destroyed(&mut self, _: &Connection, _: &QueueHandle<Self>, output: wl_output::WlOutput) {
        // Dropping the GlobeSurface destroys the swapchain, then the LayerSurface
        self.surfaces.retain(|s| s.output.id() != output.id());
    }
}

impl LayerShellHandler for AppState {
    fn closed(&mut self, _: &Connection, _: &QueueHandle<Self>, layer: &LayerSurface) {
        // Compositor closed this surface (usually the output went away);
        // keep running so remaining/hotplugged outputs stay covered.
        self.surfaces
            .retain(|s| s.layer_surface.wl_surface().id() != layer.wl_surface().id());
    }

    fn configure(&mut self, _: &Connection, qh: &QueueHandle<Self>, layer: &LayerSurface, configure: LayerSurfaceConfigure, _: u32) {
        let Some(idx) = self.surface_index(layer.wl_surface()) else {
            return;
        };

        let s = &mut self.surfaces[idx];
        let (w, h) = configure.new_size;
        // Anchored to all edges, so the compositor sends the output size;
        // fall back to something sane if it sends 0.
        s.width = if w == 0 { 1920 } else { w };
        s.height = if h == 0 { 1080 } else { h };
        s.configured = true;
        s.needs_redraw = true;

        // Draw right away so the (re)sized surface gets a buffer, cap or not.
        self.draw(idx, qh);
    }
}

impl ProvidesRegistryState for AppState {
    fn registry(&mut self) -> &mut RegistryState { &mut self.registry_state }
    registry_handlers![OutputState];
}

delegate_compositor!(AppState);
delegate_output!(AppState);
delegate_layer!(AppState);
delegate_registry!(AppState);
