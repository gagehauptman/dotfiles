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
use smithay_client_toolkit::reexports::protocols::wp::viewporter::client::{wp_viewport, wp_viewporter};
use wgpu::rwh::{RawDisplayHandle, RawWindowHandle, WaylandDisplayHandle, WaylandWindowHandle};
use wgpu::util::DeviceExt;
use rustix::event::{poll, PollFd, PollFlags, Timespec};
use std::fs::File;
use std::io::Read;
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;
use std::ptr::NonNull;
use std::time::{Duration, Instant};

// Shader, geometry and layout are shared with the selector preview
// (bevy/apps/spinning_globe) so both draw the same globe.
use globe_scene::{build_continent_lines, build_points, bytemuck, Globals, LineInstance, PointInstance, SHADER};

// The other scene this renderer hosts (bins/space_shuttle), on the same
// layers, so switching between them is only a redraw.
mod shuttle;

// The globe rotates slowly, so 30 fps is plenty. Override with `--fps N` or
// the GLOBE_FPS env var; 0 disables the cap (frame callbacks still pace us).
const DEFAULT_FPS: u32 = 30;

/// The wallpapers this renderer draws, named like their bins/<stem> dirs.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Scene {
    Globe,
    Shuttle,
}

impl Scene {
    fn from_name(name: &str) -> Option<Self> {
        match name {
            "spinning_globe" | "globe" => Some(Scene::Globe),
            "space_shuttle" | "shuttle" => Some(Scene::Shuttle),
            _ => None,
        }
    }
}

/// `--scene NAME` or WALLPAPER_SCENE; the globe by default.
fn scene_from_args() -> Scene {
    let mut name = std::env::var("WALLPAPER_SCENE").ok();
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        if arg == "--scene" {
            name = args.next();
        } else if let Some(v) = arg.strip_prefix("--scene=") {
            name = Some(v.to_owned());
        }
    }
    name.and_then(|n| {
        let scene = Scene::from_name(&n);
        if scene.is_none() {
            eprintln!("spinning_globe: unknown scene {n:?}, showing the globe");
        }
        scene
    })
    .unwrap_or(Scene::Globe)
}

fn main() {
    let launched = Instant::now();
    let frame_interval = fps_cap_from_args();
    let scene = scene_from_args();
    let start_hidden = std::env::args().any(|a| a == "--hidden")
        || std::env::var("GLOBE_HIDDEN").is_ok_and(|v| v == "1");
    let mut control = open_control_fifo();

    let conn = Connection::connect_to_env().expect("Failed to connect to Wayland");
    let (globals, mut event_queue) = registry_queue_init(&conn).expect("Failed to init registry");
    let qh = event_queue.handle();

    let compositor = CompositorState::bind(&globals, &qh).expect("wl_compositor not available");
    let layer_shell = LayerShell::bind(&globals, &qh).expect("layer shell not available");
    let viewporter: Option<wp_viewporter::WpViewporter> = globals.bind(&qh, 1..=1, ()).ok();
    if viewporter.is_none() {
        eprintln!("spinning_globe: no wp_viewporter; hidden = full-size transparent frame");
    }

    let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
        backends: wgpu::Backends::VULKAN,
        ..wgpu::InstanceDescriptor::new_without_display_handle()
    });

    let mut state = AppState {
        registry_state: RegistryState::new(&globals),
        output_state: OutputState::new(&globals, &qh),
        compositor,
        layer_shell,
        viewporter,
        conn: conn.clone(),
        instance,
        gpu: None,
        surfaces: Vec::new(),
        frame_interval,
        frozen_rotation: std::env::var("GLOBE_ROTATION").ok().and_then(|v| v.parse().ok()),
        frozen_time: std::env::var("WALLPAPER_TIME").ok().and_then(|v| v.parse().ok()),
        scene,
        visible: !start_hidden,
        launched,
        first_frame_logged: false,
    };

    // Surfaces are created per-output as new_output fires (covers both the
    // outputs present at startup and any hotplugged later).
    //
    // Event loop: draw whatever is due, then sleep on the Wayland socket (and
    // the control FIFO) until either an event arrives or the next capped frame
    // is due.
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
        let (ready, control_ready) = {
            let mut fds = vec![PollFd::from_borrowed_fd(guard.connection_fd(), PollFlags::IN)];
            if let Some((file, _)) = &control {
                fds.push(PollFd::new(file, PollFlags::IN));
            }
            match poll(&mut fds, timeout.as_ref()) {
                Ok(_) => (
                    !fds[0].revents().is_empty(),
                    fds.get(1).is_some_and(|f| !f.revents().is_empty()),
                ),
                Err(rustix::io::Errno::INTR) => (false, false),
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

        if control_ready {
            if let Some((file, _)) = &mut control {
                for cmd in read_commands(file) {
                    let mut words = cmd.split_whitespace();
                    match (words.next(), words.next()) {
                        (Some("show"), None) => state.set_visible(true, &qh),
                        (Some("show"), Some(name)) => match Scene::from_name(name) {
                            Some(scene) => state.show_scene(scene, &qh),
                            None => eprintln!("spinning_globe: unknown scene {name:?}"),
                        },
                        (Some("hide"), None) => state.set_visible(false, &qh),
                        _ => eprintln!("spinning_globe: unknown command {cmd:?}"),
                    }
                }
            }
        }
    }
}

/// Control FIFO for keeping the globe warm: `show`, `show <scene>` (switch
/// to that scene and show it) or `hide`, one per line.
/// Opened read-write so it never sees EOF and writers never block while the
/// globe is alive. Path: $GLOBE_CONTROL or $XDG_RUNTIME_DIR/spinning_globe.ctl.
fn open_control_fifo() -> Option<(File, PathBuf)> {
    let path = std::env::var_os("GLOBE_CONTROL").map(PathBuf::from).or_else(|| {
        std::env::var_os("XDG_RUNTIME_DIR").map(|d| PathBuf::from(d).join("spinning_globe.ctl"))
    })?;
    let _ = std::fs::remove_file(&path);
    if let Err(e) = rustix::fs::mknodat(
        rustix::fs::CWD,
        &path,
        rustix::fs::FileType::Fifo,
        rustix::fs::Mode::from_raw_mode(0o600),
        0,
    ) {
        eprintln!("spinning_globe: can't create control FIFO {}: {e}", path.display());
        return None;
    }
    match std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(rustix::fs::OFlags::NONBLOCK.bits() as i32)
        .open(&path)
    {
        Ok(f) => Some((f, path)),
        Err(e) => {
            eprintln!("spinning_globe: can't open control FIFO {}: {e}", path.display());
            None
        }
    }
}

fn read_commands(file: &mut File) -> Vec<String> {
    let mut buf = [0u8; 256];
    let mut text = String::new();
    loop {
        match file.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => text.push_str(&String::from_utf8_lossy(&buf[..n])),
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => break, // WouldBlock: drained
        }
    }
    text.lines().map(str::trim).filter(|l| !l.is_empty()).map(str::to_owned).collect()
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
    // Made the first time this output shows the shuttle
    shuttle: Option<shuttle::ShuttleSurface>,
    output: wl_output::WlOutput,
    layer_surface: LayerSurface,
    // Stretches the 1x1 hidden buffer over the whole output.
    viewport: Option<wp_viewport::WpViewport>,
    viewport_stretched: bool,
    width: u32,
    height: u32,
    // Size and alpha mode the swapchain is currently configured for
    swapchain_size: (u32, u32),
    swapchain_alpha: wgpu::CompositeAlphaMode,
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
    viewporter: Option<wp_viewporter::WpViewporter>,
    conn: Connection,
    instance: wgpu::Instance,
    // Created lazily with the first surface (adapter selection needs one).
    gpu: Option<Gpu>,
    surfaces: Vec<GlobeSurface>,
    frame_interval: Option<Duration>,
    frozen_rotation: Option<f32>,
    // WALLPAPER_TIME=<unix seconds> freezes the shuttle scene's clock.
    frozen_time: Option<f64>,
    scene: Scene,
    // Hidden = every surface shows one transparent 1x1 buffer stretched over
    // the output by wp_viewport (full-size transparent without viewporter),
    // and no rendering. The layers stay mapped at full size, so hiding and
    // showing never makes Hyprland refocus or animate a resize, and awww's
    // layer shows through.
    visible: bool,
    launched: Instant,
    first_frame_logged: bool,
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
    shuttle: shuttle::ShuttleGpu,
    format: wgpu::TextureFormat,
    view_format: wgpu::TextureFormat,
    present_mode: wgpu::PresentMode,
    alpha_mode: wgpu::CompositeAlphaMode,
    // Used for the 1x1 hidden surface so it's see-through.
    hidden_alpha_mode: wgpu::CompositeAlphaMode,
}

impl Gpu {
    fn new(instance: &wgpu::Instance, surface: &wgpu::Surface<'_>) -> Result<Self, String> {
        // WGPU_ADAPTER_NAME / WGPU_POWER_PREF are honoured if set. Otherwise
        // the first GPU that can present here: Mesa's device-select layer
        // lists the compositor's GPU first, so on a hybrid laptop that's the
        // integrated one driving the panel. Asking for HighPerformance took
        // the discrete GPU there, kept it awake for a wallpaper and copied
        // every frame across to the other GPU.
        let adapter = pollster::block_on(async {
            if let Ok(a) = wgpu::util::initialize_adapter_from_env(instance, Some(surface)).await {
                return Ok(a);
            }
            if std::env::var_os("WGPU_POWER_PREF").is_none() {
                let adapters = instance.enumerate_adapters(wgpu::Backends::VULKAN).await;
                if let Some(a) = adapters.into_iter().find(|a| a.is_surface_supported(surface)) {
                    return Ok(a);
                }
            }
            instance
                .request_adapter(&wgpu::RequestAdapterOptions {
                    power_preference: wgpu::PowerPreference::from_env().unwrap_or_default(),
                    compatible_surface: Some(surface),
                    ..Default::default()
                })
                .await
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
        let hidden_alpha_mode = [wgpu::CompositeAlphaMode::PreMultiplied, wgpu::CompositeAlphaMode::PostMultiplied]
            .into_iter()
            .find(|m| caps.alpha_modes.contains(m))
            .unwrap_or(alpha_mode);
        eprintln!("spinning_globe: format {format:?}, present mode {present_mode:?}, hidden alpha {hidden_alpha_mode:?}");

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

        let shuttle = shuttle::ShuttleGpu::new(&device, view_format);

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
            shuttle,
            format,
            view_format,
            present_mode,
            alpha_mode,
            hidden_alpha_mode,
        })
    }

    fn configure_surface(&self, surface: &wgpu::Surface<'_>, width: u32, height: u32, alpha_mode: wgpu::CompositeAlphaMode) {
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
                alpha_mode,
                view_formats: if self.view_format == self.format { vec![] } else { vec![self.view_format] },
            },
        );
    }
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

        // Always full-output: show/hide never changes the layer's geometry,
        // since Hyprland animates that (the globe grew from the top-left).
        layer_surface.set_anchor(Anchor::all());
        layer_surface.set_size(0, 0);
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

        let viewport = self.viewporter.as_ref().map(|v| v.get_viewport(layer_surface.wl_surface(), qh, ()));

        self.surfaces.push(GlobeSurface {
            gpu_surface,
            uniform_buffer,
            bind_group,
            shuttle: None,
            output,
            layer_surface,
            viewport,
            viewport_stretched: false,
            width: 0,
            height: 0,
            swapchain_size: (0, 0),
            swapchain_alpha: wgpu::CompositeAlphaMode::Auto,
            configured: false,
            frame_pending: false,
            needs_redraw: false,
            next_frame_at: Instant::now(),
        });
    }

    /// Switch to `scene` and show it: a redraw on the same layers.
    fn show_scene(&mut self, scene: Scene, qh: &QueueHandle<Self>) {
        if self.scene != scene {
            self.scene = scene;
            // So set_visible redraws every surface right away.
            self.visible = false;
        }
        self.set_visible(true, qh);
    }

    fn set_visible(&mut self, visible: bool, qh: &QueueHandle<Self>) {
        if self.visible == visible {
            return;
        }
        self.visible = visible;
        self.launched = Instant::now();
        self.first_frame_logged = false;
        // Draw the new state right away, full-size and complete, in a single
        // commit; the layer's geometry never changes.
        let now = Instant::now();
        for idx in 0..self.surfaces.len() {
            let s = &mut self.surfaces[idx];
            if !s.configured {
                continue;
            }
            s.frame_pending = false;
            s.needs_redraw = true;
            s.next_frame_at = now;
            self.draw(idx, qh);
        }
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
            if !self.visible || !s.configured || !s.needs_redraw || s.frame_pending {
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
        let gpu = self.gpu.as_ref().expect("GPU initialised with first surface");
        let s = &mut self.surfaces[idx];
        let width = s.width;
        let height = s.height;

        if width == 0 || height == 0 {
            return;
        }

        let visible = self.visible;
        let alpha = if visible { gpu.alpha_mode } else { gpu.hidden_alpha_mode };
        let stretch = !visible && s.viewport.is_some();
        let buffer_size = if stretch { (1, 1) } else { (width, height) };
        if s.swapchain_size != buffer_size || s.swapchain_alpha != alpha {
            gpu.configure_surface(&s.gpu_surface, buffer_size.0, buffer_size.1, alpha);
            s.swapchain_size = buffer_size;
            s.swapchain_alpha = alpha;
        }
        // Viewport state is double-buffered, so this lands in the same commit
        // as the buffer present() attaches: no frame at a wrong size.
        if let Some(viewport) = &s.viewport {
            if stretch {
                viewport.set_destination(width as i32, height as i32);
            } else if s.viewport_stretched {
                viewport.set_destination(-1, -1);
            }
            s.viewport_stretched = stretch;
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

        let mut encoder = gpu.device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("globe") });
        if visible && self.scene == Scene::Shuttle {
            // Also on the wall clock, shared with its selector preview.
            let t = self.frozen_time.unwrap_or_else(|| shuttle_scene::unix_secs(std::time::SystemTime::now()));
            let globals = shuttle_scene::Globals::at_secs(t, width, height);
            let target = s.shuttle.get_or_insert_with(|| gpu.shuttle.surface(&gpu.device));
            gpu.shuttle.encode(&gpu.device, &gpu.queue, &mut encoder, &view, target, &globals);
        } else {
            // The shuttle's depth target is only kept while it shows.
            if let Some(target) = &mut s.shuttle {
                target.release();
            }

            // Rotation from the wall clock, the same function the selector
            // preview uses, so both show the same face at the same moment (and
            // every monitor agrees); GLOBE_ROTATION=<radians> freezes it, handy
            // for comparing renders.
            let rotation = self.frozen_rotation.unwrap_or_else(globe_scene::rotation_now);

            gpu.queue.write_buffer(&s.uniform_buffer, 0, bytemuck::bytes_of(&Globals::for_output(width, height, rotation)));

            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("globe"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        // Clear to background
                        load: wgpu::LoadOp::Clear(if visible {
                            let [r, g, b] = globe_scene::BG;
                            wgpu::Color { r, g, b, a: 1.0 }
                        } else {
                            wgpu::Color::TRANSPARENT
                        }),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                ..Default::default()
            });
            if !visible {
                // Hidden: one transparent pixel, then no more frames.
                drop(pass);
                gpu.queue.submit(Some(encoder.finish()));
                gpu.queue.present(frame);
                s.needs_redraw = false;
                return;
            }
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
        if !self.first_frame_logged {
            self.first_frame_logged = true;
            eprintln!("spinning_globe: first visible frame ({:?}) {:.1} ms after start/show", self.scene, self.launched.elapsed().as_secs_f64() * 1000.0);
        }
        if let Some(interval) = self.frame_interval {
            s.next_frame_at = Instant::now() + interval;
        }
    }
}

impl Drop for GlobeSurface {
    fn drop(&mut self) {
        if let Some(viewport) = self.viewport.take() {
            viewport.destroy();
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
        s.frame_pending = false;
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
wayland_client::delegate_noop!(AppState: ignore wp_viewporter::WpViewporter);
wayland_client::delegate_noop!(AppState: ignore wp_viewport::WpViewport);
