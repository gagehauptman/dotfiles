//! quickshell-bevy: run a Bevy app inside a Quickshell dashboard card.
//!
//! An app is a cdylib that exposes one Bevy plugin through [`widget!`]:
//!
//! ```ignore
//! use bevy::prelude::*;
//! use quickshell_bevy::prelude::*;
//!
//! pub struct MyScene;
//! impl Plugin for MyScene {
//!     fn build(&self, app: &mut App) { app.add_systems(Startup, setup); }
//! }
//! quickshell_bevy::widget!(MyScene);
//! ```
//!
//! Tag a camera with [`WidgetCamera`] and the harness keeps it pointed at the
//! card's image (a default transparent 3D camera is spawned if the plugin adds
//! none); read [`WidgetInput`] for the pointer and the card size.
//!
//! How it works: Quickshell (Qt Quick on the Vulkan RHI) hands over its
//! VkInstance, physical device, VkDevice and graphics queue; wgpu adopts them,
//! Bevy renders into an image on that device, and the Qt side (qml/bevyview.cpp)
//! wraps the very same VkImage as a scene-graph texture — nothing is copied.
//! Bevy leaves its target in COLOR_ATTACHMENT_OPTIMAL and wgpu remembers that;
//! Qt samples it and never changes the layout because the texture is imported
//! as SHADER_READ_ONLY_OPTIMAL. Two explicit barriers per frame, submitted on
//! the shared queue in order, keep both sides' view of the layout true.
//! Everything runs on Qt's render thread.
use std::ffi::{c_char, CStr};
use std::sync::{Arc, Mutex};

use ash::vk;
use ash::vk::Handle as _;
use bevy::asset::{AssetPlugin, RenderAssetUsages};
use bevy::core_pipeline::tonemapping::Tonemapping;
use bevy::prelude::*;
use bevy::render::camera::RenderTarget;
use bevy::render::pipelined_rendering::PipelinedRenderingPlugin;
use bevy::render::render_asset::RenderAssets;
use bevy::render::render_resource::{Extent3d, TextureDimension, TextureFormat, TextureUsages};
use bevy::render::renderer::{RenderAdapter, RenderAdapterInfo, RenderDevice, RenderInstance, RenderQueue, WgpuWrapper};
use bevy::render::settings::{RenderCreation, RenderResources};
use bevy::render::texture::GpuImage;
use bevy::render::{RenderApp, RenderPlugin};
use bevy::window::{ExitCondition, WindowPlugin};
use wgpu_hal::api::Vulkan;

pub mod prelude {
    pub use crate::widget;
    pub use crate::{WidgetCamera, WidgetInput, WidgetTarget};
}

// ------------------------------------------------------------------ app-facing API

/// Marker for the camera that draws the card. The harness keeps its render
/// target on the widget image (also across resizes).
#[derive(Component, Default, Debug, Clone, Copy)]
pub struct WidgetCamera;

/// Pointer over the card (0..1 of its size, `down` while the button is held)
/// and the card size in pixels. Updated every frame before `PreUpdate` systems.
#[derive(Resource, Default, Debug, Clone, Copy)]
pub struct WidgetInput {
    pub x: f32,
    pub y: f32,
    pub down: bool,
    pub width: u32,
    pub height: u32,
}

/// The image the card shows. Managed by the harness; read-only for apps.
#[derive(Resource, Default, Debug, Clone)]
pub struct WidgetTarget {
    pub handle: Handle<Image>,
    pub width: u32,
    pub height: u32,
}

/// Exports the C entry points Quickshell's `BevyView` looks up (`dlopen`) for
/// a cdylib whose scene is the given Bevy plugin (any `impl Plugins`).
#[macro_export]
macro_rules! widget {
    ($plugin:expr) => {
        #[no_mangle]
        pub unsafe extern "C" fn bevy_widget_create(
            init: *const $crate::ffi::Init,
            err: *mut ::std::ffi::c_char,
            err_len: u32,
        ) -> *mut $crate::ffi::Widget {
            $crate::ffi::create(init, err, err_len, |app| {
                app.add_plugins($plugin);
            })
        }
        #[no_mangle]
        pub unsafe extern "C" fn bevy_widget_frame(w: *mut $crate::ffi::Widget, width: u32, height: u32) -> u64 {
            $crate::ffi::frame(w, width, height)
        }
        #[no_mangle]
        pub unsafe extern "C" fn bevy_widget_pointer(w: *mut $crate::ffi::Widget, x: f32, y: f32, down: bool) {
            $crate::ffi::pointer(w, x, y, down)
        }
        #[no_mangle]
        pub unsafe extern "C" fn bevy_widget_destroy(w: *mut $crate::ffi::Widget) {
            $crate::ffi::destroy(w)
        }
    };
}

// ------------------------------------------------------------------ harness plugin

#[derive(Resource, Clone)]
struct SharedInput(Arc<Mutex<(f32, f32, bool)>>);

struct HarnessPlugin;

impl Plugin for HarnessPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<WidgetInput>()
            .init_resource::<WidgetTarget>()
            .add_systems(PostStartup, ensure_camera)
            .add_systems(PreUpdate, (sync_input, aim_cameras));
    }
}

fn sync_input(shared: Res<SharedInput>, target: Res<WidgetTarget>, mut input: ResMut<WidgetInput>) {
    let (x, y, down) = shared.0.lock().map(|p| *p).unwrap_or((0.5, 0.5, false));
    *input = WidgetInput { x, y, down, width: target.width, height: target.height };
}

fn aim_cameras(target: Res<WidgetTarget>, mut cams: Query<&mut Camera, With<WidgetCamera>>) {
    for mut cam in &mut cams {
        let aimed = matches!(&cam.target, RenderTarget::Image(t) if t.handle == target.handle);
        if !aimed {
            cam.target = RenderTarget::Image(target.handle.clone().into());
        }
    }
}

fn ensure_camera(mut commands: Commands, cams: Query<(), With<WidgetCamera>>) {
    if cams.is_empty() {
        commands.spawn((
            Camera3d::default(),
            WidgetCamera,
            Camera { clear_color: ClearColorConfig::Custom(Color::NONE), ..default() },
            Tonemapping::ReinhardLuminance,
            Msaa::Sample4,
            Transform::from_xyz(0.0, 2.0, 6.0).looking_at(Vec3::ZERO, Vec3::Y),
        ));
    }
}

// ------------------------------------------------------------------ FFI (used by the macro)

#[doc(hidden)]
pub mod ffi {
    use super::*;

    /// Mirrors `BevyWidgetInit` in qml/bevyview.h.
    #[repr(C)]
    pub struct Init {
        pub instance: u64,
        pub physical_device: u64,
        pub device: u64,
        pub queue_family: u32,
        pub queue_index: u32,
        pub api_version: u32,
        pub instance_extensions: *const *const c_char,
        pub instance_extension_count: u32,
        pub assets_dir: *const c_char,
    }

    pub struct Widget {
        input: Arc<Mutex<(f32, f32, bool)>>,
        app: App,
        sync: QueueSync,
        target: Option<Target>,
        retired: Vec<(Handle<Image>, u64)>,
        frame: u64,
    }

    struct Target {
        handle: Handle<Image>,
        width: u32,
        height: u32,
        image: vk::Image, // known once the render world has uploaded it
        shown: bool,      // Qt has sampled it at least once (layout dance active)
    }

    fn write_err(err: *mut c_char, err_len: u32, msg: &str) {
        if err.is_null() || err_len == 0 {
            return;
        }
        let bytes = msg.as_bytes();
        let n = bytes.len().min(err_len as usize - 1);
        unsafe {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), err as *mut u8, n);
            *err.add(n) = 0;
        }
    }

    /// # Safety
    /// `init` must describe a live Vulkan device; called on the thread that
    /// will also call `frame` (Qt's render thread).
    pub unsafe fn create(init: *const Init, err: *mut c_char, err_len: u32, setup: fn(&mut App)) -> *mut Widget {
        let init = &*init;
        match std::panic::catch_unwind(|| build(init, setup)) {
            Ok(Ok(w)) => Box::into_raw(Box::new(w)),
            Ok(Err(e)) => {
                write_err(err, err_len, &e);
                std::ptr::null_mut()
            }
            Err(_) => {
                write_err(err, err_len, "bevy panicked during setup");
                std::ptr::null_mut()
            }
        }
    }

    /// Advance one frame for a `width` × `height` card. Returns the VkImage
    /// holding it (in SHADER_READ_ONLY_OPTIMAL), or 0 while the first is pending.
    /// # Safety
    /// Render thread only.
    pub unsafe fn frame(w: *mut Widget, width: u32, height: u32) -> u64 {
        if w.is_null() {
            return 0;
        }
        let w = &mut *w;
        match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| w.frame(width, height))) {
            Ok(img) => img.as_raw(),
            Err(_) => {
                eprintln!("bevy: frame panicked");
                0
            }
        }
    }

    /// # Safety
    /// Any thread.
    pub unsafe fn pointer(w: *mut Widget, x: f32, y: f32, down: bool) {
        if w.is_null() {
            return;
        }
        if let Ok(mut p) = (*w).input.lock() {
            *p = (x, y, down);
        }
    }

    /// # Safety
    /// Render thread only; waits for the device to go idle first.
    pub unsafe fn destroy(w: *mut Widget) {
        if w.is_null() {
            return;
        }
        let w = Box::from_raw(w);
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(move || drop(w)));
    }

    fn build(init: &Init, setup: fn(&mut App)) -> Result<Widget, String> {
        let entry = unsafe { ash::Entry::load() }.map_err(|e| format!("libvulkan: {e}"))?;
        let raw_instance = unsafe { ash::Instance::load(entry.static_fn(), vk::Instance::from_raw(init.instance)) };
        let mut exts: Vec<&'static CStr> = Vec::new();
        for i in 0..init.instance_extension_count as usize {
            let p = unsafe { *init.instance_extensions.add(i) };
            if p.is_null() {
                continue;
            }
            let s = unsafe { CStr::from_ptr(p) }.to_owned();
            exts.push(Box::leak(s.into_boxed_c_str()));
        }
        // The drop callbacks mark the handles as owned by Qt: without them wgpu
        // would destroy the VkInstance/VkDevice when the app is dropped.
        let hal_instance = unsafe {
            wgpu_hal::vulkan::Instance::from_raw(
                entry,
                raw_instance,
                init.api_version,
                0,
                None,
                exts,
                wgpu::InstanceFlags::empty(),
                false,
                Some(Box::new(|| {})),
            )
        }
        .map_err(|e| format!("wgpu instance: {e}"))?;
        let exposed = hal_instance
            .expose_adapter(vk::PhysicalDevice::from_raw(init.physical_device))
            .ok_or("wgpu could not expose Qt's physical device")?;
        let raw_device = unsafe {
            ash::Device::load(hal_instance.shared_instance().raw_instance().fp_v1_0(), vk::Device::from_raw(init.device))
        };
        // Qt enables VK_KHR_swapchain; everything else wgpu uses is Vulkan core here.
        let open = unsafe {
            exposed.adapter.device_from_raw(
                raw_device.clone(),
                Some(Box::new(|| {})),
                &[ash::khr::swapchain::NAME],
                wgpu::Features::empty(),
                &wgpu::MemoryHints::Performance,
                init.queue_family,
                init.queue_index,
            )
        }
        .map_err(|e| format!("wgpu device: {e}"))?;
        let raw_queue = open.device.raw_queue();
        let sync = QueueSync::new(raw_device, raw_queue, init.queue_family)?;
        // Bevy sizes its GPU-driven paths from the adapter's real limits (as it
        // would when it creates the device itself); WebGPU defaults are too small.
        let mut limits = exposed.capabilities.limits.clone();
        // RADV reports 4-byte offset alignments; Bevy's dynamic uniform buffers
        // (encase) need at least 32, so ask for the WebGPU defaults there — a
        // larger minimum is always satisfiable.
        limits.min_uniform_buffer_offset_alignment = limits.min_uniform_buffer_offset_alignment.max(256);
        limits.min_storage_buffer_offset_alignment = limits.min_storage_buffer_offset_alignment.max(256);

        let instance = unsafe { wgpu::Instance::from_hal::<Vulkan>(hal_instance) };
        let adapter = unsafe { instance.create_adapter_from_hal(exposed) };
        let (device, queue) = unsafe {
            adapter.create_device_from_hal(
                open,
                &wgpu::DeviceDescriptor {
                    label: Some("quickshell bevy"),
                    required_features: wgpu::Features::empty(),
                    required_limits: limits,
                    memory_hints: wgpu::MemoryHints::Performance,
                },
                None,
            )
        }
        .map_err(|e| format!("wgpu device: {e}"))?;
        // Never let a validation error abort the shell: log it and carry on
        device.on_uncaptured_error(Box::new(|e| eprintln!("bevy: wgpu error: {e}")));

        let resources = RenderResources(
            RenderDevice::from(device),
            RenderQueue(Arc::new(WgpuWrapper::new(queue))),
            RenderAdapterInfo(WgpuWrapper::new(adapter.get_info())),
            RenderAdapter(Arc::new(WgpuWrapper::new(adapter))),
            RenderInstance(Arc::new(WgpuWrapper::new(instance))),
        );
        let assets_dir = if init.assets_dir.is_null() {
            String::new()
        } else {
            unsafe { CStr::from_ptr(init.assets_dir) }.to_string_lossy().into_owned()
        };

        let input = Arc::new(Mutex::new((0.5f32, 0.5f32, false)));
        let mut app = App::new();
        app.insert_resource(SharedInput(input.clone()));
        let mut plugins = DefaultPlugins
            .set(RenderPlugin { render_creation: RenderCreation::Manual(resources), synchronous_pipeline_compilation: true, ..default() })
            .set(WindowPlugin { primary_window: None, exit_condition: ExitCondition::DontExit, close_when_requested: false })
            .set(bevy::log::LogPlugin { filter: "warn,wgpu=error,naga=error".into(), ..default() })
            .disable::<PipelinedRenderingPlugin>();
        if !assets_dir.is_empty() {
            plugins = plugins.set(AssetPlugin { file_path: assets_dir, ..default() });
        }
        app.add_plugins(plugins);
        app.add_plugins(HarnessPlugin);
        setup(&mut app);
        while app.plugins_state() != bevy::app::PluginsState::Ready {
            bevy::tasks::tick_global_task_pools_on_main_thread();
        }
        app.finish();
        app.cleanup();
        Ok(Widget { input, app, sync, target: None, retired: Vec::new(), frame: 0 })
    }

    impl Widget {
        fn frame(&mut self, width: u32, height: u32) -> vk::Image {
            let (width, height) = (width.max(1), height.max(1));
            self.frame += 1;
            let frame = self.frame;
            // New size: a fresh target; the old one stays alive a few frames
            // since Qt may still be sampling it.
            if self.target.as_ref().map_or(true, |t| t.width != width || t.height != height) {
                let handle = new_target(self.app.world_mut(), width, height);
                self.app.world_mut().insert_resource(WidgetTarget { handle: handle.clone(), width, height });
                if let Some(old) = self.target.take() {
                    self.retired.push((old.handle, frame));
                }
                self.target = Some(Target { handle, width, height, image: vk::Image::null(), shown: false });
            }
            self.retired.retain(|(_, f)| frame - *f < 6);

            // Back to the layout wgpu expects before it renders into the target again
            if let Some(t) = self.target.as_ref() {
                if t.shown {
                    self.sync.barrier(
                        t.image,
                        vk::ImageLayout::SHADER_READ_ONLY_OPTIMAL,
                        vk::ImageLayout::COLOR_ATTACHMENT_OPTIMAL,
                        vk::PipelineStageFlags::FRAGMENT_SHADER,
                        vk::AccessFlags::SHADER_READ,
                        vk::PipelineStageFlags::COLOR_ATTACHMENT_OUTPUT,
                        vk::AccessFlags::COLOR_ATTACHMENT_WRITE,
                    );
                }
            }

            self.app.update();

            // Find the VkImage behind the target (uploaded by the render world)
            let Some(t) = self.target.as_mut() else { return vk::Image::null() };
            if t.image == vk::Image::null() {
                let render_world = self.app.sub_app(RenderApp).world();
                if let Some(gpu) = render_world.resource::<RenderAssets<GpuImage>>().get(&t.handle) {
                    t.image = unsafe { gpu.texture.as_hal::<Vulkan, _, _>(|tex| tex.map(|tex| tex.raw_handle())) }.unwrap_or(vk::Image::null());
                }
                if t.image == vk::Image::null() {
                    return vk::Image::null();
                }
            }
            // Hand it to Qt in the layout the imported texture declares
            self.sync.barrier(
                t.image,
                vk::ImageLayout::COLOR_ATTACHMENT_OPTIMAL,
                vk::ImageLayout::SHADER_READ_ONLY_OPTIMAL,
                vk::PipelineStageFlags::COLOR_ATTACHMENT_OUTPUT,
                vk::AccessFlags::COLOR_ATTACHMENT_WRITE,
                vk::PipelineStageFlags::FRAGMENT_SHADER,
                vk::AccessFlags::SHADER_READ,
            );
            t.shown = true;
            t.image
        }
    }

    impl Drop for Widget {
        fn drop(&mut self) {
            unsafe { self.sync.device.device_wait_idle().ok() };
        }
    }

    fn new_target(world: &mut World, width: u32, height: u32) -> Handle<Image> {
        let mut image = Image::new_fill(
            Extent3d { width, height, depth_or_array_layers: 1 },
            TextureDimension::D2,
            &[0, 0, 0, 0],
            TextureFormat::Rgba8UnormSrgb,
            RenderAssetUsages::default(),
        );
        image.texture_descriptor.usage = TextureUsages::TEXTURE_BINDING | TextureUsages::COPY_DST | TextureUsages::RENDER_ATTACHMENT;
        // Qt views the image as plain RGBA8 (it wants the encoded bytes); a
        // second view format makes wgpu create the image mutable-format.
        image.texture_descriptor.view_formats = &[TextureFormat::Rgba8Unorm];
        world.resource_mut::<Assets<Image>>().add(image)
    }

    // -------------------------------------------------------------- queue barriers

    pub(super) struct QueueSync {
        pub(super) device: ash::Device,
        queue: vk::Queue,
        pool: vk::CommandPool,
        bufs: Vec<vk::CommandBuffer>,
        fences: Vec<vk::Fence>,
        submitted: Vec<bool>,
        cursor: usize,
    }

    impl QueueSync {
        fn new(device: ash::Device, queue: vk::Queue, family: u32) -> Result<Self, String> {
            const RING: usize = 8;
            unsafe {
                let pool = device
                    .create_command_pool(
                        &vk::CommandPoolCreateInfo::default().queue_family_index(family).flags(vk::CommandPoolCreateFlags::RESET_COMMAND_BUFFER),
                        None,
                    )
                    .map_err(|e| format!("command pool: {e}"))?;
                let bufs = device
                    .allocate_command_buffers(
                        &vk::CommandBufferAllocateInfo::default().command_pool(pool).level(vk::CommandBufferLevel::PRIMARY).command_buffer_count(RING as u32),
                    )
                    .map_err(|e| format!("command buffers: {e}"))?;
                let mut fences = Vec::new();
                for _ in 0..RING {
                    fences.push(device.create_fence(&vk::FenceCreateInfo::default(), None).map_err(|e| format!("fence: {e}"))?);
                }
                Ok(Self { device, queue, pool, bufs, fences, submitted: vec![false; RING], cursor: 0 })
            }
        }

        #[allow(clippy::too_many_arguments)]
        fn barrier(
            &mut self,
            image: vk::Image,
            old: vk::ImageLayout,
            new: vk::ImageLayout,
            src_stage: vk::PipelineStageFlags,
            src_access: vk::AccessFlags,
            dst_stage: vk::PipelineStageFlags,
            dst_access: vk::AccessFlags,
        ) {
            let i = self.cursor % self.bufs.len();
            self.cursor += 1;
            let (cb, fence) = (self.bufs[i], self.fences[i]);
            unsafe {
                if self.submitted[i] {
                    self.device.wait_for_fences(&[fence], true, u64::MAX).ok();
                }
                self.device.reset_fences(&[fence]).ok();
                self.device.reset_command_buffer(cb, vk::CommandBufferResetFlags::empty()).ok();
                self.device
                    .begin_command_buffer(cb, &vk::CommandBufferBeginInfo::default().flags(vk::CommandBufferUsageFlags::ONE_TIME_SUBMIT))
                    .ok();
                let b = vk::ImageMemoryBarrier::default()
                    .image(image)
                    .old_layout(old)
                    .new_layout(new)
                    .src_access_mask(src_access)
                    .dst_access_mask(dst_access)
                    .src_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                    .dst_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                    .subresource_range(vk::ImageSubresourceRange {
                        aspect_mask: vk::ImageAspectFlags::COLOR,
                        base_mip_level: 0,
                        level_count: 1,
                        base_array_layer: 0,
                        layer_count: 1,
                    });
                self.device.cmd_pipeline_barrier(cb, src_stage, dst_stage, vk::DependencyFlags::empty(), &[], &[], &[b]);
                self.device.end_command_buffer(cb).ok();
                let cbs = [cb];
                let submit = vk::SubmitInfo::default().command_buffers(&cbs);
                self.device.queue_submit(self.queue, &[submit], fence).ok();
                self.submitted[i] = true;
            }
        }
    }

    impl Drop for QueueSync {
        fn drop(&mut self) {
            unsafe {
                self.device.device_wait_idle().ok();
                for f in &self.fences {
                    self.device.destroy_fence(*f, None);
                }
                self.device.destroy_command_pool(self.pool, None);
            }
        }
    }
}
