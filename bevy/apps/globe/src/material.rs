//! The globe surface material: fill colour, weather and light pollution
//! layers, sun direction. Both layers are index textures (cloud-top coldness
//! plus coverage, light pollution zone) looked up through 256 x 1 palettes,
//! each with a global equirectangular texture and a Mercator inset window at
//! the source's best zoom around home. Kept in its own module because the
//! `ShaderType` derive (encase 0.10) emits per-field check functions that
//! trip dead_code on recent compilers.
#![allow(dead_code)]

use bevy::asset::weak_handle;
use bevy::image::{ImageAddressMode, ImageFilterMode, ImageSampler, ImageSamplerDescriptor};
use bevy::pbr::Material;
use bevy::prelude::*;
use bevy::render::render_asset::RenderAssetUsages;
use bevy::render::render_resource::{AsBindGroup, Extent3d, Shader, ShaderRef, ShaderType, TextureDimension, TextureFormat};

pub const GLOBE_SHADER: Handle<Shader> = weak_handle!("b6f0c3b2-5a1e-4d7c-9f0e-3c2a8e5d1b47");

#[derive(ShaderType, Debug, Clone, Copy, Default)]
pub struct GlobeParams {
    pub fill: Vec4,
    pub rim: Vec4,
    pub sun: Vec4,
    /// x = weather opacity, y = light pollution opacity, z = weather saturation
    pub layers: Vec4,
    /// inset windows: x = west edge (radians), y = longitude span (radians),
    /// z = Mercator y of the north edge (0 at the pole), w = its span; y = 0 means none
    pub inset_wx: Vec4,
    pub inset_lp: Vec4,
}

#[derive(Asset, TypePath, AsBindGroup, Debug, Clone)]
pub struct GlobeMaterial {
    #[uniform(0)]
    pub params: GlobeParams,
    /// Rg8: cloud-top coldness index, coverage; equirectangular
    #[texture(1)]
    #[sampler(2)]
    pub weather: Handle<Image>,
    /// R8: light pollution zone; equirectangular
    #[texture(3)]
    #[sampler(4)]
    pub lp: Handle<Image>,
    #[texture(5)]
    #[sampler(6)]
    pub weather_inset: Handle<Image>,
    #[texture(7)]
    #[sampler(8)]
    pub lp_inset: Handle<Image>,
    /// 256 x 1 palettes
    #[texture(9)]
    #[sampler(10)]
    pub weather_lut: Handle<Image>,
    #[texture(11)]
    #[sampler(12)]
    pub lp_lut: Handle<Image>,
}

impl Material for GlobeMaterial {
    fn fragment_shader() -> ShaderRef {
        ShaderRef::Handle(GLOBE_SHADER)
    }
}

/// A data texture. `wrap` repeats across the antimeridian (global layers);
/// `smooth` filters bilinearly (continuous fields, not zone indices).
pub fn texture(width: u32, height: u32, data: Vec<u8>, format: TextureFormat, smooth: bool, wrap: bool) -> Image {
    let mut img = Image::new(Extent3d { width, height, depth_or_array_layers: 1 }, TextureDimension::D2, data, format, RenderAssetUsages::RENDER_WORLD);
    let filter = if smooth { ImageFilterMode::Linear } else { ImageFilterMode::Nearest };
    img.sampler = ImageSampler::Descriptor(ImageSamplerDescriptor {
        address_mode_u: if wrap { ImageAddressMode::Repeat } else { ImageAddressMode::ClampToEdge },
        address_mode_v: ImageAddressMode::ClampToEdge,
        mag_filter: filter,
        min_filter: filter,
        ..default()
    });
    img
}
