//! Headless snapshot of a dashboard app. Loads an app library the way the
//! Quickshell plugin does, but on a Vulkan device of its own, runs it for a
//! while (feeding optional drag and wheel input) and writes the last frame
//! as a PNG. Useful for checking an app without the shell, or on a locked
//! or headless machine.
//!
//!   bevy-snapshot <lib.so> <out.png> [--size 1400x900] [--seconds 20]
//!                 [--options '{"json": true}'] [--scroll 3] [--drag x0,y0,x1,y1]
//!                 [--send id=value]... [--bg 1e1e2e]
//!
//! Drag coordinates are fractions of the frame. `--send` presses a control
//! the app declares (a toggle takes true/false), and the app's controls and
//! readouts are printed at the end. `--bg` composites the frame over a colour
//! (the target is transparent outside what the app draws).
use std::ffi::{c_char, CStr, CString};
use std::path::Path;
use std::time::{Duration, Instant};

use ash::khr;
use ash::vk;
use ash::vk::Handle as _;
use quickshell_bevy::ffi::{Init, Widget};

type CreateFn = unsafe extern "C" fn(*const Init, *mut c_char, u32) -> *mut Widget;
type FrameFn = unsafe extern "C" fn(*mut Widget, u32, u32) -> u64;
type PointerFn = unsafe extern "C" fn(*mut Widget, f32, f32, bool);
type ScrollFn = unsafe extern "C" fn(*mut Widget, f32);
type UiFn = unsafe extern "C" fn(*mut Widget, *mut u64) -> *const c_char;
type EventFn = unsafe extern "C" fn(*mut Widget, *const c_char, *const c_char);
type DestroyFn = unsafe extern "C" fn(*mut Widget);

struct Args {
    lib: String,
    out: String,
    width: u32,
    height: u32,
    seconds: f32,
    options: String,
    scroll: f32,
    drag: Option<[f32; 4]>,
    send: Vec<(String, String)>,
    bg: Option<[u8; 3]>,
}

fn parse_args() -> Result<Args, String> {
    let mut it = std::env::args().skip(1);
    let usage = "usage: bevy-snapshot <lib.so> <out.png> [--size WxH] [--seconds N] [--options JSON] [--scroll N] [--drag x0,y0,x1,y1] [--send id=value]... [--bg rrggbb]";
    let lib = it.next().ok_or(usage)?;
    let out = it.next().ok_or(usage)?;
    let mut a = Args { lib, out, width: 1400, height: 900, seconds: 20.0, options: "{}".into(), scroll: 0.0, drag: None, send: Vec::new(), bg: None };
    while let Some(flag) = it.next() {
        let val = it.next().ok_or_else(|| format!("{flag} needs a value"))?;
        match flag.as_str() {
            "--size" => {
                let (w, h) = val.split_once('x').ok_or("--size wants WxH")?;
                a.width = w.parse().map_err(|_| "bad width")?;
                a.height = h.parse().map_err(|_| "bad height")?;
            }
            "--seconds" => a.seconds = val.parse().map_err(|_| "bad --seconds")?,
            "--options" => a.options = val,
            "--scroll" => a.scroll = val.parse().map_err(|_| "bad --scroll")?,
            "--drag" => {
                let v: Vec<f32> = val.split(',').map(|s| s.parse().map_err(|_| "bad --drag")).collect::<Result<_, _>>()?;
                a.drag = Some(v.try_into().map_err(|_| "--drag wants x0,y0,x1,y1")?);
            }
            "--send" => {
                let (id, value) = val.split_once('=').unwrap_or((&val, ""));
                a.send.push((id.to_string(), value.to_string()));
            }
            "--bg" => {
                let v = u32::from_str_radix(val.trim_start_matches('#'), 16).map_err(|_| "bad --bg")?;
                a.bg = Some([(v >> 16) as u8, (v >> 8) as u8, v as u8]);
            }
            _ => return Err(format!("unknown flag {flag}\n{usage}")),
        }
    }
    Ok(a)
}

/// Instance, device and a graphics queue, with every feature the device
/// supports enabled (wgpu assumes the ones it finds supported are on).
struct Gpu {
    _entry: ash::Entry,
    instance: ash::Instance,
    physical: vk::PhysicalDevice,
    device: ash::Device,
    queue: vk::Queue,
    family: u32,
    api_version: u32,
    extensions: Vec<CString>,
}

fn vk_err<T>(r: Result<T, vk::Result>, what: &str) -> Result<T, String> {
    r.map_err(|e| format!("{what}: {e}"))
}

impl Gpu {
    fn new() -> Result<Gpu, String> {
        let entry = unsafe { ash::Entry::load() }.map_err(|e| format!("libvulkan: {e}"))?;
        let supported = unsafe { entry.try_enumerate_instance_version() }.ok().flatten().unwrap_or(vk::API_VERSION_1_0);
        let api_version = supported.min(vk::API_VERSION_1_3);
        let available = vk_err(unsafe { entry.enumerate_instance_extension_properties(None) }, "instance extensions")?;
        let wanted = [khr::surface::NAME, khr::get_physical_device_properties2::NAME];
        let extensions: Vec<CString> = wanted
            .iter()
            .filter(|w| available.iter().any(|e| e.extension_name_as_c_str().map(|n| n == **w).unwrap_or(false)))
            .map(|w| (*w).to_owned())
            .collect();
        let ext_ptrs: Vec<*const c_char> = extensions.iter().map(|e| e.as_ptr()).collect();
        let app = vk::ApplicationInfo::default().api_version(api_version);
        let instance = vk_err(
            unsafe { entry.create_instance(&vk::InstanceCreateInfo::default().application_info(&app).enabled_extension_names(&ext_ptrs), None) },
            "create instance",
        )?;
        let devices = vk_err(unsafe { instance.enumerate_physical_devices() }, "physical devices")?;
        let mut pick: Option<(vk::PhysicalDevice, u32, bool)> = None;
        for pd in devices {
            let props = unsafe { instance.get_physical_device_properties(pd) };
            let discrete = props.device_type == vk::PhysicalDeviceType::DISCRETE_GPU;
            let families = unsafe { instance.get_physical_device_queue_family_properties(pd) };
            let Some(family) = families.iter().position(|q| q.queue_flags.contains(vk::QueueFlags::GRAPHICS | vk::QueueFlags::COMPUTE)) else { continue };
            if pick.map_or(true, |(_, _, d)| discrete && !d) {
                pick = Some((pd, family as u32, discrete));
            }
        }
        let (physical, family, _) = pick.ok_or("no Vulkan device with a graphics queue")?;

        let mut f11 = vk::PhysicalDeviceVulkan11Features::default();
        let mut f12 = vk::PhysicalDeviceVulkan12Features::default();
        let mut f13 = vk::PhysicalDeviceVulkan13Features::default();
        let mut features = vk::PhysicalDeviceFeatures2::default().push_next(&mut f11).push_next(&mut f12);
        if api_version >= vk::API_VERSION_1_3 {
            features = features.push_next(&mut f13);
        }
        unsafe { instance.get_physical_device_features2(physical, &mut features) };
        let priorities = [1.0f32];
        let queue_info = [vk::DeviceQueueCreateInfo::default().queue_family_index(family).queue_priorities(&priorities)];
        let dev_exts = [khr::swapchain::NAME.as_ptr()];
        let info = vk::DeviceCreateInfo::default().queue_create_infos(&queue_info).enabled_extension_names(&dev_exts).push_next(&mut features);
        let device = vk_err(unsafe { instance.create_device(physical, &info, None) }, "create device")?;
        let queue = unsafe { device.get_device_queue(family, 0) };
        Ok(Gpu { _entry: entry, instance, physical, device, queue, family, api_version, extensions })
    }

    fn memory_type(&self, bits: u32, flags: vk::MemoryPropertyFlags) -> Option<u32> {
        let props = unsafe { self.instance.get_physical_device_memory_properties(self.physical) };
        (0..props.memory_type_count).find(|i| bits & (1 << i) != 0 && props.memory_types[*i as usize].property_flags.contains(flags))
    }

    /// Copy a colour image the app left in SHADER_READ_ONLY_OPTIMAL into RGBA bytes.
    fn read_back(&self, image: vk::Image, width: u32, height: u32) -> Result<Vec<u8>, String> {
        let d = &self.device;
        let size = (width * height * 4) as u64;
        unsafe {
            vk_err(d.queue_wait_idle(self.queue), "queue idle")?;
            let buffer = vk_err(d.create_buffer(&vk::BufferCreateInfo::default().size(size).usage(vk::BufferUsageFlags::TRANSFER_DST), None), "buffer")?;
            let req = d.get_buffer_memory_requirements(buffer);
            let mt = self.memory_type(req.memory_type_bits, vk::MemoryPropertyFlags::HOST_VISIBLE | vk::MemoryPropertyFlags::HOST_COHERENT).ok_or("no host visible memory")?;
            let memory = vk_err(d.allocate_memory(&vk::MemoryAllocateInfo::default().allocation_size(req.size).memory_type_index(mt), None), "memory")?;
            vk_err(d.bind_buffer_memory(buffer, memory, 0), "bind")?;
            let pool = vk_err(d.create_command_pool(&vk::CommandPoolCreateInfo::default().queue_family_index(self.family), None), "pool")?;
            let cb = vk_err(d.allocate_command_buffers(&vk::CommandBufferAllocateInfo::default().command_pool(pool).level(vk::CommandBufferLevel::PRIMARY).command_buffer_count(1)), "cb")?[0];
            vk_err(d.begin_command_buffer(cb, &vk::CommandBufferBeginInfo::default().flags(vk::CommandBufferUsageFlags::ONE_TIME_SUBMIT)), "begin")?;
            let range = vk::ImageSubresourceRange::default().aspect_mask(vk::ImageAspectFlags::COLOR).level_count(1).layer_count(1);
            let barrier = |old, new, src_access, dst_access| {
                vk::ImageMemoryBarrier::default()
                    .image(image)
                    .old_layout(old)
                    .new_layout(new)
                    .src_access_mask(src_access)
                    .dst_access_mask(dst_access)
                    .src_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                    .dst_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                    .subresource_range(range)
            };
            d.cmd_pipeline_barrier(
                cb,
                vk::PipelineStageFlags::FRAGMENT_SHADER,
                vk::PipelineStageFlags::TRANSFER,
                vk::DependencyFlags::empty(),
                &[],
                &[],
                &[barrier(vk::ImageLayout::SHADER_READ_ONLY_OPTIMAL, vk::ImageLayout::TRANSFER_SRC_OPTIMAL, vk::AccessFlags::SHADER_READ, vk::AccessFlags::TRANSFER_READ)],
            );
            let region = vk::BufferImageCopy::default()
                .image_subresource(vk::ImageSubresourceLayers::default().aspect_mask(vk::ImageAspectFlags::COLOR).layer_count(1))
                .image_extent(vk::Extent3D { width, height, depth: 1 });
            d.cmd_copy_image_to_buffer(cb, image, vk::ImageLayout::TRANSFER_SRC_OPTIMAL, buffer, &[region]);
            d.cmd_pipeline_barrier(
                cb,
                vk::PipelineStageFlags::TRANSFER,
                vk::PipelineStageFlags::FRAGMENT_SHADER,
                vk::DependencyFlags::empty(),
                &[],
                &[],
                &[barrier(vk::ImageLayout::TRANSFER_SRC_OPTIMAL, vk::ImageLayout::SHADER_READ_ONLY_OPTIMAL, vk::AccessFlags::TRANSFER_READ, vk::AccessFlags::SHADER_READ)],
            );
            vk_err(d.end_command_buffer(cb), "end")?;
            let fence = vk_err(d.create_fence(&vk::FenceCreateInfo::default(), None), "fence")?;
            let cbs = [cb];
            vk_err(d.queue_submit(self.queue, &[vk::SubmitInfo::default().command_buffers(&cbs)], fence), "submit")?;
            vk_err(d.wait_for_fences(&[fence], true, u64::MAX), "wait")?;
            let ptr = vk_err(d.map_memory(memory, 0, size, vk::MemoryMapFlags::empty()), "map")? as *const u8;
            let bytes = std::slice::from_raw_parts(ptr, size as usize).to_vec();
            d.unmap_memory(memory);
            d.destroy_fence(fence, None);
            d.destroy_command_pool(pool, None);
            d.destroy_buffer(buffer, None);
            d.free_memory(memory, None);
            Ok(bytes)
        }
    }
}

fn run() -> Result<(), String> {
    let args = parse_args()?;
    let gpu = Gpu::new()?;
    let lib = unsafe { libloading::Library::new(&args.lib) }.map_err(|e| format!("{}: {e}", args.lib))?;
    let sym = |name: &[u8]| -> Result<*const (), String> {
        unsafe { lib.get::<*const ()>(name) }.map(|s| *s).map_err(|e| format!("{}: {e}", String::from_utf8_lossy(name)))
    };
    let (create, frame, pointer, scroll, ui, event, destroy) = unsafe {
        (
            std::mem::transmute::<*const (), CreateFn>(sym(b"bevy_widget_create\0")?),
            std::mem::transmute::<*const (), FrameFn>(sym(b"bevy_widget_frame\0")?),
            std::mem::transmute::<*const (), PointerFn>(sym(b"bevy_widget_pointer\0")?),
            std::mem::transmute::<*const (), ScrollFn>(sym(b"bevy_widget_scroll\0")?),
            std::mem::transmute::<*const (), UiFn>(sym(b"bevy_widget_ui\0")?),
            std::mem::transmute::<*const (), EventFn>(sym(b"bevy_widget_event\0")?),
            std::mem::transmute::<*const (), DestroyFn>(sym(b"bevy_widget_destroy\0")?),
        )
    };

    let assets = Path::new(&args.lib).parent().map(|p| p.join("assets")).unwrap_or_default();
    let assets = CString::new(assets.to_string_lossy().into_owned()).unwrap_or_default();
    let options = CString::new(args.options.clone()).map_err(|_| "options contain a NUL byte")?;
    let ext_ptrs: Vec<*const c_char> = gpu.extensions.iter().map(|e| e.as_ptr()).collect();
    let init = Init {
        instance: gpu.instance.handle().as_raw(),
        physical_device: gpu.physical.as_raw(),
        device: gpu.device.handle().as_raw(),
        queue_family: gpu.family,
        queue_index: 0,
        api_version: gpu.api_version,
        instance_extensions: ext_ptrs.as_ptr(),
        instance_extension_count: ext_ptrs.len() as u32,
        assets_dir: assets.as_ptr(),
        options: options.as_ptr(),
    };
    let mut err = [0 as c_char; 512];
    let widget = unsafe { create(&init, err.as_mut_ptr(), err.len() as u32) };
    if widget.is_null() {
        let msg = unsafe { CStr::from_ptr(err.as_ptr()) }.to_string_lossy().into_owned();
        return Err(format!("bevy_widget_create failed: {msg}"));
    }
    eprintln!("app up on {:?}, rendering {} s at {}x{}", Path::new(&args.lib).file_name().unwrap_or_default(), args.seconds, args.width, args.height);

    let start = Instant::now();
    let total = Duration::from_secs_f32(args.seconds.max(0.5));
    let input_at = total.saturating_sub(Duration::from_secs(2));
    let mut input_done = false;
    let mut image = vk::Image::null();
    let mut drag_step = 0u32;
    while start.elapsed() < total {
        let t = start.elapsed();
        if t >= input_at && !input_done {
            if args.scroll != 0.0 {
                unsafe { scroll(widget, args.scroll) };
            }
            if drag_step == 0 {
                for (id, value) in &args.send {
                    let (id, value) = (CString::new(id.as_str()).unwrap_or_default(), CString::new(value.as_str()).unwrap_or_default());
                    unsafe { event(widget, id.as_ptr(), value.as_ptr()) };
                }
            }
            if let Some([x0, y0, x1, y1]) = args.drag {
                // 30 frames of drag, then release
                let k = (drag_step as f32 / 30.0).min(1.0);
                unsafe { pointer(widget, x0 + (x1 - x0) * k, y0 + (y1 - y0) * k, drag_step <= 30) };
                drag_step += 1;
                if drag_step > 31 {
                    input_done = true;
                }
            } else {
                input_done = true;
            }
        }
        image = vk::Image::from_raw(unsafe { frame(widget, args.width, args.height) });
        std::thread::sleep(Duration::from_millis(16));
    }
    if image == vk::Image::null() {
        return Err("the app never produced a frame".into());
    }
    let mut gen = 0u64;
    let json = unsafe { ui(widget, &mut gen) };
    if !json.is_null() {
        eprintln!("ui: {}", unsafe { CStr::from_ptr(json) }.to_string_lossy());
    }
    let mut rgba = gpu.read_back(image, args.width, args.height)?;
    if let Some(bg) = args.bg {
        for px in rgba.chunks_exact_mut(4) {
            let a = px[3] as u32;
            for c in 0..3 {
                px[c] = ((px[c] as u32 * a + bg[c] as u32 * (255 - a)) / 255) as u8;
            }
            px[3] = 255;
        }
    }
    image::save_buffer(&args.out, &rgba, args.width, args.height, image::ColorType::Rgba8).map_err(|e| format!("{}: {e}", args.out))?;
    eprintln!("wrote {}", args.out);
    unsafe { destroy(widget) };
    Ok(())
}

fn main() {
    if let Err(e) = run() {
        eprintln!("bevy-snapshot: {e}");
        std::process::exit(1);
    }
    // the app library stays loaded (Bevy's task pools keep threads); leave without unwinding
    std::process::exit(0);
}
