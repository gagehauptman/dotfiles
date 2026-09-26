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
//! none); read [`WidgetInput`] for the pointer and the card size, and
//! [`WidgetOptions`] for the card's preset options. Declare toggles, buttons
//! and readouts in [`WidgetUi`]; the card draws them and presses come back as
//! [`WidgetEvent`]s.
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
use std::ffi::{c_char, CStr, CString};
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
use serde::Serialize;
use wgpu_hal::api::Vulkan;

pub mod prelude {
    pub use crate::widget;
    pub use crate::{rig, Control, Info, Setting, WidgetCamera, WidgetEvent, WidgetInput, WidgetOptions, WidgetTarget, WidgetUi};
}

/// Camera rigs for scenes built around a body at the origin: an overhead
/// view of a point on it, a chase view from behind one object towards
/// another, and smoothing between poses. Pure functions over `Transform`,
/// so an app can mix them with its own input handling.
pub mod rig {
    use bevy::prelude::*;

    /// Looking straight down at the point of the body in direction `dir`
    /// (a unit vector) from `dist` away from the centre, north (+Y) up.
    pub fn above(dir: Vec3, dist: f32) -> Transform {
        let dir = dir.normalize_or(Vec3::Z);
        let up = if dir.y.abs() > 0.999 { Vec3::Z } else { Vec3::Y };
        Transform::from_translation(dir * dist).looking_at(Vec3::ZERO, up)
    }

    /// Behind `subject` on the line from `target` through it, `standoff`
    /// further out, looking at `target`; up is away from the body's centre
    /// so the horizon reads naturally. Both positions are in scene units.
    pub fn chase(subject: Vec3, target: Vec3, standoff: f32) -> Transform {
        let away = (subject - target).normalize_or(subject.normalize_or(Vec3::Z));
        let eye = subject + away * standoff;
        let up = eye.normalize_or(Vec3::Y);
        let up = if up.cross(target - eye).length_squared() < 1e-6 { Vec3::Y } else { up };
        Transform::from_translation(eye).looking_at(target, up)
    }

    /// The point of a unit sphere at a latitude and longitude in radians
    /// (y north, x through longitude 0, east towards -z).
    pub fn on_sphere(lat: f32, lon: f32) -> Vec3 {
        Vec3::new(lat.cos() * lon.cos(), lat.sin(), -lat.cos() * lon.sin())
    }

    /// Moves `current` a step towards `goal` with time constant `tau`
    /// seconds (exponential approach of position and orientation).
    pub fn approach(current: &mut Transform, goal: &Transform, dt: f32, tau: f32) {
        let a = if tau <= 0.0 { 1.0 } else { 1.0 - (-dt / tau).exp() };
        current.translation = current.translation.lerp(goal.translation, a);
        current.rotation = current.rotation.slerp(goal.rotation, a);
    }
}

// ------------------------------------------------------------------ app-facing API

/// Marker for the camera that draws the card. The harness keeps its render
/// target on the widget image (also across resizes).
#[derive(Component, Default, Debug, Clone, Copy)]
pub struct WidgetCamera;

/// Pointer over the card (0..1 of its size, `down` while the button is held),
/// wheel steps since the last frame (positive = away from the user) and the
/// card size in pixels. Updated every frame before `PreUpdate` systems.
#[derive(Resource, Default, Debug, Clone, Copy)]
pub struct WidgetInput {
    pub x: f32,
    pub y: f32,
    pub down: bool,
    pub scroll: f32,
    pub width: u32,
    pub height: u32,
}

/// The preset entry's `options` object for this card, as JSON text (the
/// widget adds a `theme` object with the shell's colours as `#rrggbb`).
#[derive(Resource, Default, Debug, Clone)]
pub struct WidgetOptions(pub String);

/// Controls and readouts the card draws around the scene: toggles and
/// buttons along the bottom, `label value` readouts in the title line, and
/// settings (any control type, grouped in sections) behind a gear. Add or
/// update entries from any system, in any order; only real changes reach
/// the shell. A control's state follows the user's input on its own, and
/// the card remembers settings and toggles per device, handing them back at
/// the next start in the options as `"settings": { id: value }`.
#[derive(Resource, Default, Debug, Clone)]
pub struct WidgetUi {
    controls: Vec<Control>,
    settings: Vec<Setting>,
    info: Vec<Info>,
    changed: bool,
}

impl WidgetUi {
    /// Add a toggle, or update its label and state.
    pub fn toggle(&mut self, id: &str, label: &str, on: bool) -> &mut Self {
        self.put(Control::Toggle { id: id.into(), label: label.into(), on })
    }

    /// Add a button, or update its label.
    pub fn button(&mut self, id: &str, label: &str) -> &mut Self {
        self.put(Control::Button { id: id.into(), label: label.into() })
    }

    /// Add a control to the settings panel under `section`, or update it.
    pub fn setting(&mut self, section: &str, control: Control) -> &mut Self {
        match self.settings.iter_mut().find(|s| s.control.id() == control.id()) {
            Some(s) => {
                if s.section != section || s.control != control {
                    s.section = section.into();
                    s.control = control;
                    self.changed = true;
                }
            }
            None => {
                self.settings.push(Setting { section: section.into(), control });
                self.changed = true;
            }
        }
        self
    }

    pub fn settings(&self) -> &[Setting] {
        &self.settings
    }

    /// The state of any control (pill or setting) as the string an event
    /// would carry: "true"/"false", a number, a choice, comma-joined choices, text.
    pub fn value(&self, id: &str) -> Option<String> {
        self.controls.iter().chain(self.settings.iter().map(|s| &s.control)).find(|c| c.id() == id).and_then(Control::value)
    }

    /// Set a control's state from an event string; true when something changed.
    pub fn set_value(&mut self, id: &str, value: &str) -> bool {
        let mut changed = false;
        for c in self.controls.iter_mut().chain(self.settings.iter_mut().map(|s| &mut s.control)) {
            if c.id() == id && c.set_value(value) {
                changed = true;
            }
        }
        if changed {
            self.changed = true;
        }
        changed
    }

    /// Add a readout, or update its value. An empty label shows the value alone.
    pub fn info(&mut self, id: &str, label: &str, value: impl Into<String>) -> &mut Self {
        let value = value.into();
        match self.info.iter_mut().find(|i| i.id == id) {
            Some(i) => {
                if i.label != label || i.value != value {
                    i.label = label.into();
                    i.value = value;
                    self.changed = true;
                }
            }
            None => {
                self.info.push(Info { id: id.into(), label: label.into(), value });
                self.changed = true;
            }
        }
        self
    }

    /// Drop the control, setting or readout with this id.
    pub fn remove(&mut self, id: &str) -> &mut Self {
        let n = self.controls.len() + self.settings.len() + self.info.len();
        self.controls.retain(|c| c.id() != id);
        self.settings.retain(|s| s.control.id() != id);
        self.info.retain(|i| i.id != id);
        if self.controls.len() + self.settings.len() + self.info.len() != n {
            self.changed = true;
        }
        self
    }

    /// State of a toggle, if there is one with this id.
    pub fn is_on(&self, id: &str) -> Option<bool> {
        self.controls.iter().find_map(|c| match c {
            Control::Toggle { id: i, on, .. } if i == id => Some(*on),
            _ => None,
        })
    }

    pub fn set_on(&mut self, id: &str, on: bool) -> &mut Self {
        for c in &mut self.controls {
            if let Control::Toggle { id: i, on: o, .. } = c {
                if i == id && *o != on {
                    *o = on;
                    self.changed = true;
                }
            }
        }
        self
    }

    pub fn controls(&self) -> &[Control] {
        &self.controls
    }

    pub fn infos(&self) -> &[Info] {
        &self.info
    }

    fn put(&mut self, next: Control) -> &mut Self {
        match self.controls.iter_mut().find(|c| c.id() == next.id()) {
            Some(c) => {
                if *c != next {
                    *c = next;
                    self.changed = true;
                }
            }
            None => {
                self.controls.push(next);
                self.changed = true;
            }
        }
        self
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Control {
    Toggle { id: String, label: String, on: bool },
    Button { id: String, label: String },
    /// a number in [min, max]; the event carries it as text
    Slider { id: String, label: String, min: f32, max: f32, step: f32, value: f32 },
    /// one of `options`; the event carries the choice
    Select { id: String, label: String, options: Vec<String>, value: String },
    /// any of `options`; the event carries the choices comma-separated
    Multi { id: String, label: String, options: Vec<String>, values: Vec<String> },
    /// free text with a placeholder; the event carries the text
    Text { id: String, label: String, value: String, hint: String },
}

impl Control {
    pub fn toggle(id: &str, label: &str, on: bool) -> Control {
        Control::Toggle { id: id.into(), label: label.into(), on }
    }
    pub fn button(id: &str, label: &str) -> Control {
        Control::Button { id: id.into(), label: label.into() }
    }
    pub fn slider(id: &str, label: &str, min: f32, max: f32, step: f32, value: f32) -> Control {
        Control::Slider { id: id.into(), label: label.into(), min, max, step, value }
    }
    pub fn select(id: &str, label: &str, options: &[&str], value: &str) -> Control {
        Control::Select { id: id.into(), label: label.into(), options: options.iter().map(|o| o.to_string()).collect(), value: value.into() }
    }
    pub fn multi(id: &str, label: &str, options: &[&str], values: &[String]) -> Control {
        Control::Multi { id: id.into(), label: label.into(), options: options.iter().map(|o| o.to_string()).collect(), values: values.to_vec() }
    }
    pub fn text(id: &str, label: &str, value: &str, hint: &str) -> Control {
        Control::Text { id: id.into(), label: label.into(), value: value.into(), hint: hint.into() }
    }

    pub fn id(&self) -> &str {
        match self {
            Control::Toggle { id, .. }
            | Control::Button { id, .. }
            | Control::Slider { id, .. }
            | Control::Select { id, .. }
            | Control::Multi { id, .. }
            | Control::Text { id, .. } => id,
        }
    }

    /// The state as the string an event carries (buttons have none).
    pub fn value(&self) -> Option<String> {
        match self {
            Control::Toggle { on, .. } => Some(on.to_string()),
            Control::Button { .. } => None,
            Control::Slider { value, .. } => Some(value.to_string()),
            Control::Select { value, .. } => Some(value.clone()),
            Control::Multi { values, .. } => Some(values.join(",")),
            Control::Text { value, .. } => Some(value.clone()),
        }
    }

    /// Take the state from an event string; true when it changed.
    pub fn set_value(&mut self, v: &str) -> bool {
        match self {
            Control::Toggle { on, .. } => match v {
                "true" if !*on => {
                    *on = true;
                    true
                }
                "false" if *on => {
                    *on = false;
                    true
                }
                _ => false,
            },
            Control::Button { .. } => false,
            Control::Slider { value, min, max, .. } => match v.trim().parse::<f32>() {
                Ok(n) if (n.clamp(*min, *max) - *value).abs() > 1e-6 => {
                    *value = n.clamp(*min, *max);
                    true
                }
                _ => false,
            },
            Control::Select { value, options, .. } => {
                if options.iter().any(|o| o == v) && value != v {
                    *value = v.to_string();
                    true
                } else {
                    false
                }
            }
            Control::Multi { values, options, .. } => {
                let next: Vec<String> = v.split(',').map(str::trim).filter(|x| options.iter().any(|o| o == x)).map(String::from).collect();
                if next != *values {
                    *values = next;
                    true
                } else {
                    false
                }
            }
            Control::Text { value, .. } => {
                if value != v {
                    *value = v.to_string();
                    true
                } else {
                    false
                }
            }
        }
    }
}

/// A control in the settings panel and the section it sits under.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Setting {
    pub section: String,
    #[serde(flatten)]
    pub control: Control,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Info {
    pub id: String,
    pub label: String,
    pub value: String,
}

/// A control the user pressed. A toggle carries its new state (`"true"` or
/// `"false"`, see [`WidgetEvent::on`]), a button an empty value.
#[derive(Event, Debug, Clone)]
pub struct WidgetEvent {
    pub id: String,
    pub value: String,
}

impl WidgetEvent {
    pub fn on(&self) -> bool {
        self.value == "true"
    }
}

#[derive(Serialize)]
struct UiJson<'a> {
    controls: &'a [Control],
    settings: &'a [Setting],
    info: &'a [Info],
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
        pub unsafe extern "C" fn bevy_widget_scroll(w: *mut $crate::ffi::Widget, dy: f32) {
            $crate::ffi::scroll(w, dy)
        }
        #[no_mangle]
        pub unsafe extern "C" fn bevy_widget_ui(w: *mut $crate::ffi::Widget, generation: *mut u64) -> *const ::core::ffi::c_char {
            $crate::ffi::ui(w, generation)
        }
        #[no_mangle]
        pub unsafe extern "C" fn bevy_widget_event(w: *mut $crate::ffi::Widget, id: *const ::core::ffi::c_char, value: *const ::core::ffi::c_char) {
            $crate::ffi::event(w, id, value)
        }
        #[no_mangle]
        pub unsafe extern "C" fn bevy_widget_destroy(w: *mut $crate::ffi::Widget) {
            $crate::ffi::destroy(w)
        }
    };
}

// ------------------------------------------------------------------ harness plugin

#[derive(Default)]
struct InputState {
    x: f32,
    y: f32,
    down: bool,
    scroll: f32,                   // accumulated wheel steps, drained each frame
    events: Vec<(String, String)>, // control presses, drained each frame
    /// button changes not yet seen by a frame, with where they happened:
    /// delivered one per frame, so a press and release inside one frame
    /// interval still reach the app as a press, then a release
    edges: std::collections::VecDeque<(f32, f32, bool)>,
}

#[derive(Resource, Clone)]
struct SharedInput(Arc<Mutex<InputState>>);

/// Latest UI JSON and its generation, read by the Qt side after each frame.
#[derive(Resource, Clone)]
struct SharedUi(Arc<Mutex<(u64, String)>>);

struct HarnessPlugin;

impl Plugin for HarnessPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<WidgetInput>()
            .init_resource::<WidgetTarget>()
            .init_resource::<WidgetUi>()
            .add_event::<WidgetEvent>()
            .add_systems(PostStartup, ensure_camera)
            .add_systems(PreUpdate, (sync_input, aim_cameras))
            .add_systems(Last, publish_ui);
    }
}

fn sync_input(
    shared: Res<SharedInput>,
    target: Res<WidgetTarget>,
    mut input: ResMut<WidgetInput>,
    mut ui: ResMut<WidgetUi>,
    mut events: EventWriter<WidgetEvent>,
) {
    let (x, y, down, scroll, pending) = match shared.0.lock() {
        Ok(mut s) => {
            let (x, y, down) = s.edges.pop_front().unwrap_or((s.x, s.y, s.down));
            let out = (x, y, down, s.scroll, std::mem::take(&mut s.events));
            s.scroll = 0.0;
            out
        }
        Err(_) => (0.5, 0.5, false, 0.0, Vec::new()),
    };
    *input = WidgetInput { x, y, down, scroll, width: target.width, height: target.height };
    for (id, value) in pending {
        // The control follows the input; the app then reads its new state or the event
        ui.set_value(&id, &value);
        events.write(WidgetEvent { id, value });
    }
}

fn publish_ui(mut ui: ResMut<WidgetUi>, shared: Res<SharedUi>) {
    if !ui.changed {
        return;
    }
    ui.changed = false;
    let json = serde_json::to_string(&UiJson { controls: &ui.controls, settings: &ui.settings, info: &ui.info }).unwrap_or_default();
    if let Ok(mut s) = shared.0.lock() {
        if s.1 != json {
            s.0 += 1;
            s.1 = json;
        }
    }
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
        pub options: *const c_char,   // JSON, may be null
    }

    pub struct Widget {
        input: Arc<Mutex<InputState>>,
        ui: Arc<Mutex<(u64, String)>>,
        ui_json: CString,
        ui_gen: u64,
        app: App,
        sync: QueueSync,
        target: Option<Target>,
        retired: Vec<(Handle<Image>, u64)>,
        frame: u64,
        /// A system panicked: the schedules are gone, so the app is frozen on
        /// its last frame instead of panicking again every frame.
        dead: bool,
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
        if w.dead {
            return w.target.as_ref().map(|t| t.image.as_raw()).unwrap_or(0);
        }
        match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| w.frame(width, height))) {
            Ok(img) => img.as_raw(),
            Err(_) => {
                eprintln!("bevy: a system panicked; the app is frozen on its last frame");
                w.dead = true;
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
            if down != p.down {
                if p.edges.len() >= 64 {
                    p.edges.pop_front();
                }
                p.edges.push_back((x, y, down));
            }
            p.x = x;
            p.y = y;
            p.down = down;
        }
    }

    /// Wheel movement in steps (one notch = 1). # Safety: any thread.
    pub unsafe fn scroll(w: *mut Widget, dy: f32) {
        if w.is_null() {
            return;
        }
        if let Ok(mut p) = (*w).input.lock() {
            p.scroll += dy;
        }
    }

    /// The app's controls and readouts as JSON (`{"controls": [...], "info": [...]}`)
    /// with their generation, so a caller only re-parses when the number
    /// changes. Null until the app declares something. The pointer stays valid
    /// until the next call.
    /// # Safety
    /// Render thread only (the thread that calls `frame`).
    pub unsafe fn ui(w: *mut Widget, generation: *mut u64) -> *const c_char {
        if w.is_null() {
            return std::ptr::null();
        }
        let w = &mut *w;
        if let Ok(s) = w.ui.lock() {
            if s.0 != w.ui_gen {
                w.ui_gen = s.0;
                w.ui_json = CString::new(s.1.as_str()).unwrap_or_default();
            }
        }
        if !generation.is_null() {
            *generation = w.ui_gen;
        }
        if w.ui_gen == 0 {
            std::ptr::null()
        } else {
            w.ui_json.as_ptr()
        }
    }

    /// A control press: the control id and, for a toggle, its new state as
    /// "true"/"false". # Safety: any thread.
    pub unsafe fn event(w: *mut Widget, id: *const c_char, value: *const c_char) {
        if w.is_null() || id.is_null() {
            return;
        }
        let id = CStr::from_ptr(id).to_string_lossy().into_owned();
        let value = if value.is_null() { String::new() } else { CStr::from_ptr(value).to_string_lossy().into_owned() };
        if let Ok(mut p) = (*w).input.lock() {
            p.events.push((id, value));
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
        let cstring = |p: *const c_char| if p.is_null() { String::new() } else { unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned() };
        let assets_dir = cstring(init.assets_dir);
        let options = cstring(init.options);

        let input = Arc::new(Mutex::new(InputState { x: 0.5, y: 0.5, ..Default::default() }));
        let ui = Arc::new(Mutex::new((0u64, String::new())));
        let mut app = App::new();
        app.insert_resource(SharedInput(input.clone()));
        app.insert_resource(SharedUi(ui.clone()));
        app.insert_resource(WidgetOptions(options));
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
        Ok(Widget { input, ui, ui_json: CString::default(), ui_gen: 0, app, sync, target: None, retired: Vec::new(), frame: 0, dead: false })
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
