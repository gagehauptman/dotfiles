//! Renders the Sputnik scene offscreen to PPM stills, for looking at it
//! without a Wayland output (any size, any time):
//!
//!     SPUTNIK_SEED=7 cargo run --release --example sputnik_shot -- 3440x1440 out 0 60 300
//!
//! writes out-0.ppm, out-60.ppm, out-300.ppm (seconds since the scene started;
//! with SPUTNIK_SEED set the scene's clock starts at 0 and its randomness is
//! fixed). A prefix of `-` only renders (a GPU timing run, no files).
#[path = "../src/sputnik.rs"]
mod sputnik;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (w, h) = args[0].split_once('x').map(|(a, b)| (a.parse::<u32>().unwrap(), b.parse::<u32>().unwrap())).unwrap();
    let prefix = &args[1];
    let times: Vec<f64> = args[2..].iter().map(|s| s.parse().unwrap()).collect();

    let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
        backends: wgpu::Backends::VULKAN,
        ..wgpu::InstanceDescriptor::new_without_display_handle()
    });
    let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions::default())).expect("adapter");
    let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor::default())).expect("device");
    let format = wgpu::TextureFormat::Rgba8Unorm;
    let gpu = sputnik::SputnikGpu::new(&device, &queue, format);
    let mut surface = gpu.surface(&device);

    let tex = device.create_texture(&wgpu::TextureDescriptor {
        label: None,
        size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
        view_formats: &[],
    });
    let view = tex.create_view(&Default::default());
    let bpr = (w * 4).div_ceil(256) * 256;
    let buf = device.create_buffer(&wgpu::BufferDescriptor {
        label: None,
        size: (bpr * h) as u64,
        usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
        mapped_at_creation: false,
    });
    let clock = std::time::Instant::now();
    for &t in &times {
        let mut enc = device.create_command_encoder(&Default::default());
        // A few frames' worth of history isn't needed: every frame is a pure function of time.
        gpu.encode(&queue, &mut enc, &view, &mut surface, t, w, h);
        if prefix == "-" {
            queue.submit([enc.finish()]);
            device.poll(wgpu::PollType::wait_indefinitely()).unwrap();
            continue;
        }
        enc.copy_texture_to_buffer(
            wgpu::TexelCopyTextureInfo { texture: &tex, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
            wgpu::TexelCopyBufferInfo { buffer: &buf, layout: wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(bpr), rows_per_image: Some(h) } },
            wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
        );
        queue.submit([enc.finish()]);
        buf.slice(..).map_async(wgpu::MapMode::Read, |_| {});
        device.poll(wgpu::PollType::wait_indefinitely()).unwrap();
        let data = buf.slice(..).get_mapped_range().unwrap().to_vec();
        buf.unmap();
        let mut out = format!("P6\n{w} {h}\n255\n").into_bytes();
        for y in 0..h {
            for x in 0..w {
                let o = (y * bpr + x * 4) as usize;
                out.extend_from_slice(&data[o..o + 3]);
            }
        }
        std::fs::write(format!("{prefix}-{t}.ppm"), out).unwrap();
    }
    eprintln!("{} frames in {:.1} ms", times.len(), clock.elapsed().as_secs_f64() * 1e3);
}
