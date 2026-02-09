mod continents;

use smithay_client_toolkit::{
    compositor::{CompositorHandler, CompositorState},
    delegate_compositor, delegate_layer, delegate_output, delegate_registry, delegate_shm,
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
    shm::{slot::SlotPool, Shm, ShmHandler},
};
use wayland_client::{
    globals::registry_queue_init,
    protocol::{wl_output, wl_shm, wl_surface},
    Connection, QueueHandle,
};
use std::f32::consts::PI;
use std::time::Instant;

use continents::ALL_LANDMASSES;

fn main() {
    let conn = Connection::connect_to_env().expect("Failed to connect to Wayland");
    let (globals, mut event_queue) = registry_queue_init(&conn).expect("Failed to init registry");
    let qh = event_queue.handle();

    let compositor = CompositorState::bind(&globals, &qh).expect("wl_compositor not available");
    let layer_shell = LayerShell::bind(&globals, &qh).expect("layer shell not available");
    let shm = Shm::bind(&globals, &qh).expect("wl_shm not available");

    let surface = compositor.create_surface(&qh);
    
    let layer_surface = layer_shell.create_layer_surface(
        &qh,
        surface,
        Layer::Background,
        Some("wargames-globe"),
        None,
    );
    
    layer_surface.set_anchor(Anchor::all());
    layer_surface.set_exclusive_zone(-1);
    layer_surface.set_keyboard_interactivity(KeyboardInteractivity::None);
    layer_surface.commit();

    let mut state = AppState {
        registry_state: RegistryState::new(&globals),
        output_state: OutputState::new(&globals, &qh),
        shm,
        pool: None,
        layer_surface: Some(layer_surface),
        width: 0,
        height: 0,
        configured: false,
        start_time: Instant::now(),
        running: true,
        frame_pending: false,
    };

    while state.running {
        event_queue.blocking_dispatch(&mut state).unwrap();
    }
}

struct AppState {
    registry_state: RegistryState,
    output_state: OutputState,
    shm: Shm,
    pool: Option<SlotPool>,
    layer_surface: Option<LayerSurface>,
    width: u32,
    height: u32,
    configured: bool,
    start_time: Instant,
    running: bool,
    frame_pending: bool,
}

// Catppuccin Mocha colors
const BG_R: u8 = 30;  // Base #1e1e2e
const BG_G: u8 = 30;
const BG_B: u8 = 46;

const GREEN_R: u8 = 166; // Green #a6e3a1
const GREEN_G: u8 = 227;
const GREEN_B: u8 = 161;

const TEAL_R: u8 = 148; // Teal #94e2d5
const TEAL_G: u8 = 226;
const TEAL_B: u8 = 213;

impl AppState {
    fn draw(&mut self, qh: &QueueHandle<Self>) {
        let surface = self.layer_surface.as_ref().unwrap().wl_surface();
        let width = self.width;
        let height = self.height;
        
        if self.pool.is_none() {
            self.pool = Some(SlotPool::new((width * height * 4) as usize, &self.shm).unwrap());
        }
        
        let pool = self.pool.as_mut().unwrap();
        let stride = width * 4;
        let size = (stride * height) as usize;
        
        if pool.len() < size {
            pool.resize(size).unwrap();
        }
        
        let (buffer, canvas) = pool
            .create_buffer(width as i32, height as i32, stride as i32, wl_shm::Format::Argb8888)
            .unwrap();

        let time = self.start_time.elapsed().as_secs_f32();
        
        // Globe parameters
        let globe_radius = (height.min(width) as f32 * 0.35) as i32;
        let center_x = width as f32 / 2.0;
        let center_y = height as f32 / 2.0;
        
        // Rotation angle
        let rotation = time * 0.15;

        // Clear to background
        for y in 0..height {
            for x in 0..width {
                let idx = ((y * width + x) * 4) as usize;
                canvas[idx] = BG_B;
                canvas[idx + 1] = BG_G;
                canvas[idx + 2] = BG_R;
                canvas[idx + 3] = 255;
            }
        }

        // Draw latitude lines (every 30 degrees)
        for lat_deg in (-60..=60).step_by(30) {
            let lat = (lat_deg as f32).to_radians();
            for lon_deg in 0..360 {
                let lon = (lon_deg as f32).to_radians() + rotation;
                if let Some((sx, sy, visible)) = project_point(lat, lon, globe_radius as f32, center_x, center_y) {
                    if visible {
                        draw_glow_pixel(canvas, width, height, sx as i32, sy as i32, TEAL_R, TEAL_G, TEAL_B, 0.25);
                    }
                }
            }
        }

        // Draw longitude lines (every 30 degrees)
        for lon_deg in (0..180).step_by(30) {
            let lon = (lon_deg as f32).to_radians() + rotation;
            for lat_deg in -90..=90 {
                let lat = (lat_deg as f32).to_radians();
                if let Some((sx, sy, visible)) = project_point(lat, lon, globe_radius as f32, center_x, center_y) {
                    if visible {
                        draw_glow_pixel(canvas, width, height, sx as i32, sy as i32, TEAL_R, TEAL_G, TEAL_B, 0.25);
                    }
                }
                if let Some((sx, sy, visible)) = project_point(lat, lon + PI, globe_radius as f32, center_x, center_y) {
                    if visible {
                        draw_glow_pixel(canvas, width, height, sx as i32, sy as i32, TEAL_R, TEAL_G, TEAL_B, 0.25);
                    }
                }
            }
        }

        // Draw all landmasses
        for landmass in ALL_LANDMASSES {
            draw_continent(canvas, width, height, landmass, globe_radius as f32, center_x, center_y, rotation);
        }

        // Draw globe outline
        for angle in 0..720 {
            let a = (angle as f32) * PI / 360.0;
            let x = center_x + globe_radius as f32 * a.cos();
            let y = center_y + globe_radius as f32 * a.sin();
            draw_glow_pixel(canvas, width, height, x as i32, y as i32, TEAL_R, TEAL_G, TEAL_B, 0.5);
        }

        surface.attach(Some(buffer.wl_buffer()), 0, 0);
        surface.damage_buffer(0, 0, width as i32, height as i32);
        
        // Request next frame callback for vsync
        if !self.frame_pending {
            surface.frame(qh, surface.clone());
            self.frame_pending = true;
        }
        
        surface.commit();
    }
}

fn project_point(lat: f32, lon: f32, radius: f32, cx: f32, cy: f32) -> Option<(f32, f32, bool)> {
    let x = lat.cos() * lon.cos();
    let y = lat.cos() * lon.sin();
    let z = lat.sin();
    
    let visible = x > 0.0;
    
    let screen_x = cx + y * radius;
    let screen_y = cy - z * radius;
    
    Some((screen_x, screen_y, visible))
}

fn draw_continent(canvas: &mut [u8], width: u32, height: u32, points: &[(f32, f32)], radius: f32, cx: f32, cy: f32, rotation: f32) {
    if points.len() < 2 {
        return;
    }
    
    for i in 0..points.len() {
        let (lon1, lat1) = points[i];
        let (lon2, lat2) = points[(i + 1) % points.len()];
        
        let lat1_rad = lat1.to_radians();
        let lon1_rad = lon1.to_radians() + rotation;
        let lat2_rad = lat2.to_radians();
        let lon2_rad = lon2.to_radians() + rotation;
        
        // More interpolation steps for smoother lines
        let dist = ((lat2 - lat1).powi(2) + (lon2 - lon1).powi(2)).sqrt();
        let steps = ((dist * 3.0) as i32).max(20);
        
        let mut prev_x: Option<i32> = None;
        let mut prev_y: Option<i32> = None;
        let mut prev_visible = false;
        
        for s in 0..=steps {
            let t = s as f32 / steps as f32;
            let lat = lat1_rad + (lat2_rad - lat1_rad) * t;
            let lon = lon1_rad + (lon2_rad - lon1_rad) * t;
            
            if let Some((sx, sy, visible)) = project_point(lat, lon, radius, cx, cy) {
                let ix = sx as i32;
                let iy = sy as i32;
                
                if visible {
                    // Draw line from previous point if both visible
                    if prev_visible {
                        if let (Some(px), Some(py)) = (prev_x, prev_y) {
                            draw_line(canvas, width, height, px, py, ix, iy, GREEN_R, GREEN_G, GREEN_B, 1.0);
                        }
                    }
                    prev_x = Some(ix);
                    prev_y = Some(iy);
                    prev_visible = true;
                } else {
                    prev_visible = false;
                }
            }
        }
    }
}

fn draw_line(canvas: &mut [u8], width: u32, height: u32, x0: i32, y0: i32, x1: i32, y1: i32, r: u8, g: u8, b: u8, intensity: f32) {
    let dx = (x1 - x0).abs();
    let dy = -(y1 - y0).abs();
    let sx = if x0 < x1 { 1 } else { -1 };
    let sy = if y0 < y1 { 1 } else { -1 };
    let mut err = dx + dy;
    
    let mut x = x0;
    let mut y = y0;
    
    loop {
        draw_glow_pixel(canvas, width, height, x, y, r, g, b, intensity);
        // Add slight glow
        draw_glow_pixel(canvas, width, height, x + 1, y, r, g, b, intensity * 0.3);
        draw_glow_pixel(canvas, width, height, x - 1, y, r, g, b, intensity * 0.3);
        draw_glow_pixel(canvas, width, height, x, y + 1, r, g, b, intensity * 0.3);
        draw_glow_pixel(canvas, width, height, x, y - 1, r, g, b, intensity * 0.3);
        
        if x == x1 && y == y1 {
            break;
        }
        
        let e2 = 2 * err;
        if e2 >= dy {
            err += dy;
            x += sx;
        }
        if e2 <= dx {
            err += dx;
            y += sy;
        }
    }
}

fn draw_glow_pixel(canvas: &mut [u8], width: u32, height: u32, x: i32, y: i32, r: u8, g: u8, b: u8, intensity: f32) {
    if x < 0 || y < 0 || x >= width as i32 || y >= height as i32 {
        return;
    }
    
    let idx = ((y as u32 * width + x as u32) * 4) as usize;
    if idx + 3 >= canvas.len() {
        return;
    }
    
    let existing_b = canvas[idx] as f32;
    let existing_g = canvas[idx + 1] as f32;
    let existing_r = canvas[idx + 2] as f32;
    
    canvas[idx] = ((existing_b + b as f32 * intensity).min(255.0)) as u8;
    canvas[idx + 1] = ((existing_g + g as f32 * intensity).min(255.0)) as u8;
    canvas[idx + 2] = ((existing_r + r as f32 * intensity).min(255.0)) as u8;
}

impl CompositorHandler for AppState {
    fn scale_factor_changed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: i32) {}
    fn transform_changed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: wl_output::Transform) {}
    fn frame(&mut self, _: &Connection, qh: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: u32) {
        self.frame_pending = false;
        if self.configured && self.width > 0 && self.height > 0 {
            self.draw(qh);
        }
    }
    fn surface_enter(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: &wl_output::WlOutput) {}
    fn surface_leave(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: &wl_output::WlOutput) {}
}

impl OutputHandler for AppState {
    fn output_state(&mut self) -> &mut OutputState { &mut self.output_state }
    fn new_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
    fn update_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
    fn output_destroyed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
}

impl LayerShellHandler for AppState {
    fn closed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &LayerSurface) {
        self.running = false;
    }

    fn configure(&mut self, _: &Connection, qh: &QueueHandle<Self>, layer: &LayerSurface, configure: LayerSurfaceConfigure, _: u32) {
        self.width = configure.new_size.0.max(1920);
        self.height = configure.new_size.1.max(1080);
        self.configured = true;
        
        if self.width == 0 || self.height == 0 {
            layer.set_size(1920, 1080);
            layer.commit();
        }
        
        self.draw(qh);
    }
}

impl ShmHandler for AppState {
    fn shm_state(&mut self) -> &mut Shm { &mut self.shm }
}

impl ProvidesRegistryState for AppState {
    fn registry(&mut self) -> &mut RegistryState { &mut self.registry_state }
    registry_handlers![OutputState];
}

delegate_compositor!(AppState);
delegate_output!(AppState);
delegate_layer!(AppState);
delegate_shm!(AppState);
delegate_registry!(AppState);
