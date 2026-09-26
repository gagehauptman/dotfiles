//! Labels painted on the globe. Glyphs come from the system monospace font
//! (fontconfig; Bevy's built-in font when there is none), rasterised on demand
//! into one atlas texture. Each label is a strip of textured quads whose
//! baseline follows the great circle through its anchor, so names turn,
//! curve and foreshorten with the globe and hide behind its limb instead of
//! floating in screen space.
use std::collections::HashMap;

use ab_glyph::{Font as _, FontVec, PxScale, ScaleFont as _};
use bevy::prelude::*;
use bevy::render::mesh::{Indices, PrimitiveTopology};
use bevy::render::render_asset::RenderAssetUsages;
use bevy::render::render_resource::{Extent3d, TextureDimension, TextureFormat};

use crate::sphere;

pub const ATLAS_SIZE: u32 = 1024;
/// Glyphs are rasterised at this size and scaled onto the globe.
pub const RASTER_PX: f32 = 22.0;

#[derive(Clone, Copy, Debug)]
pub struct Glyph {
    /// atlas rectangle in texture coordinates: u0, v0 (top), u1, v1 (bottom)
    pub uv: [f32; 4],
    /// box in raster pixels relative to the pen position on the baseline, y up
    pub x0: f32,
    pub x1: f32,
    pub y0: f32,
    pub y1: f32,
    pub advance: f32,
}

pub struct Atlas {
    font: FontVec,
    pixels: Vec<u8>,
    cursor: (u32, u32, u32), // next x, row y, row height
    glyphs: HashMap<char, Option<Glyph>>,
    pub dirty: bool,
    pub ascent: f32,
}

impl Atlas {
    /// Starts with every printable Latin glyph (ASCII, Latin-1, Latin
    /// Extended-A) rasterised, so the atlas texture rarely changes later.
    pub fn new(bytes: Vec<u8>) -> Option<Atlas> {
        let font = FontVec::try_from_vec(bytes).ok()?;
        let ascent = font.as_scaled(PxScale::from(RASTER_PX)).ascent();
        let mut atlas = Atlas {
            font,
            pixels: vec![0; (ATLAS_SIZE * ATLAS_SIZE * 4) as usize],
            cursor: (1, 1, 0),
            glyphs: HashMap::new(),
            dirty: true,
            ascent,
        };
        for c in (0x20..0x7f).chain(0xa0..0x180).filter_map(char::from_u32) {
            atlas.glyph(c);
        }
        Some(atlas)
    }

    /// The system's monospace font through fontconfig, if there is one.
    pub fn system_font() -> Option<Vec<u8>> {
        let out = std::process::Command::new("fc-match").args(["-f", "%{file}", "monospace"]).output().ok()?;
        let path = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if path.is_empty() {
            return None;
        }
        std::fs::read(path).ok()
    }

    pub fn glyph(&mut self, c: char) -> Option<Glyph> {
        if !self.glyphs.contains_key(&c) {
            let g = self.rasterize(c);
            self.glyphs.insert(c, g);
        }
        self.glyphs.get(&c).copied().flatten()
    }

    fn rasterize(&mut self, c: char) -> Option<Glyph> {
        let scale = PxScale::from(RASTER_PX);
        let id = self.font.glyph_id(c);
        let advance = self.font.as_scaled(scale).h_advance(id);
        let Some(outline) = self.font.outline_glyph(id.with_scale_and_position(scale, ab_glyph::point(0.0, 0.0))) else {
            // whitespace and glyphs without an outline still move the pen
            return Some(Glyph { uv: [0.0; 4], x0: 0.0, x1: 0.0, y0: 0.0, y1: 0.0, advance });
        };
        let b = outline.px_bounds();
        let (w, h) = (b.width().ceil() as u32 + 1, b.height().ceil() as u32 + 1);
        let (mut x, mut y, mut row) = self.cursor;
        if x + w + 1 > ATLAS_SIZE {
            x = 1;
            y += row + 1;
            row = 0;
        }
        if y + h + 1 > ATLAS_SIZE {
            return None; // atlas full: the glyph is skipped
        }
        let pixels = &mut self.pixels;
        outline.draw(|gx, gy, cov| {
            let i = ((y + gy) * ATLAS_SIZE + x + gx) as usize * 4;
            if i + 3 < pixels.len() {
                pixels[i] = 255;
                pixels[i + 1] = 255;
                pixels[i + 2] = 255;
                pixels[i + 3] = (cov * 255.0) as u8;
            }
        });
        self.cursor = (x + w + 1, y, row.max(h));
        self.dirty = true;
        let s = ATLAS_SIZE as f32;
        Some(Glyph {
            uv: [x as f32 / s, y as f32 / s, (x as f32 + b.width()) / s, (y as f32 + b.height()) / s],
            x0: b.min.x,
            x1: b.max.x,
            y0: -b.max.y,
            y1: -b.min.y,
            advance,
        })
    }

    /// Advance width of a string in raster pixels.
    pub fn width(&mut self, text: &str) -> f32 {
        text.chars().map(|c| self.glyph(c).map(|g| g.advance).unwrap_or(0.0)).sum()
    }

    pub fn image(&self) -> Image {
        Image::new(
            Extent3d { width: ATLAS_SIZE, height: ATLAS_SIZE, depth_or_array_layers: 1 },
            TextureDimension::D2,
            self.pixels.clone(),
            TextureFormat::Rgba8UnormSrgb,
            RenderAssetUsages::RENDER_WORLD,
        )
    }
}

/// Textured quads for lines of text lying on the sphere.
#[derive(Default)]
pub struct TextMesh {
    positions: Vec<[f32; 3]>,
    normals: Vec<[f32; 3]>,
    uvs: Vec<[f32; 2]>,
    colors: Vec<[f32; 4]>,
    indices: Vec<u32>,
}

impl TextMesh {
    /// One line of text centred on `anchor` (a unit vector), its baseline on
    /// the great circle through the anchor towards local east. `k` is world
    /// units per raster pixel, `radius` where the quads sit, `shift` an offset
    /// in raster pixels (for a shadow copy).
    pub fn text(&mut self, atlas: &mut Atlas, text: &str, anchor: Vec3, k: f32, radius: f32, color: [f32; 4], shift: Vec2) {
        let (east, north) = sphere::frame(anchor);
        let width = atlas.width(text);
        let mut pen = -width / 2.0 + shift.x;
        let vshift = -atlas.ascent * 0.36 + shift.y; // baseline below the anchor so the x-height sits on it
        for c in text.chars() {
            let Some(g) = atlas.glyph(c) else { continue };
            if g.x1 > g.x0 {
                let (x0, x1) = ((pen + g.x0) * k, (pen + g.x1) * k);
                let (y0, y1) = ((g.y0 + vshift) * k, (g.y1 + vshift) * k);
                let q0 = anchor * x0.cos() + east * x0.sin();
                let q1 = anchor * x1.cos() + east * x1.sin();
                let base = self.positions.len() as u32;
                for (q, y, uv) in [(q0, y1, [g.uv[0], g.uv[1]]), (q1, y1, [g.uv[2], g.uv[1]]), (q0, y0, [g.uv[0], g.uv[3]]), (q1, y0, [g.uv[2], g.uv[3]])] {
                    self.positions.push(((q + north * y) * radius).to_array());
                    self.normals.push(q.to_array());
                    self.uvs.push(uv);
                    self.colors.push(color);
                }
                self.indices.extend_from_slice(&[base, base + 2, base + 3, base, base + 3, base + 1]);
            }
            pen += g.advance;
        }
    }

    /// One line of flat text at `anchor` in the plane of `right` and `up`
    /// (unit vectors; a camera's axes make a billboard). `k` is world units
    /// per raster pixel, `shift` an offset in raster pixels.
    pub fn text_at(&mut self, atlas: &mut Atlas, text: &str, anchor: Vec3, right: Vec3, up: Vec3, k: f32, color: [f32; 4], shift: Vec2) {
        let width = atlas.width(text);
        let mut pen = -width / 2.0 + shift.x;
        let vshift = -atlas.ascent * 0.36 + shift.y;
        for c in text.chars() {
            let Some(g) = atlas.glyph(c) else { continue };
            if g.x1 > g.x0 {
                let (x0, x1) = ((pen + g.x0) * k, (pen + g.x1) * k);
                let (y0, y1) = ((g.y0 + vshift) * k, (g.y1 + vshift) * k);
                let base = self.positions.len() as u32;
                for (x, y, uv) in [(x0, y1, [g.uv[0], g.uv[1]]), (x1, y1, [g.uv[2], g.uv[1]]), (x0, y0, [g.uv[0], g.uv[3]]), (x1, y0, [g.uv[2], g.uv[3]])] {
                    self.positions.push((anchor + right * x + up * y).to_array());
                    self.normals.push(right.cross(up).to_array());
                    self.uvs.push(uv);
                    self.colors.push(color);
                }
                self.indices.extend_from_slice(&[base, base + 2, base + 3, base, base + 3, base + 1]);
            }
            pen += g.advance;
        }
    }

    pub fn mesh(mut self) -> Mesh {
        if self.positions.is_empty() {
            // nothing to show: a triangle inside the globe keeps the buffers non-empty
            for _ in 0..3 {
                self.positions.push([0.0; 3]);
                self.normals.push([0.0, 1.0, 0.0]);
                self.uvs.push([0.0; 2]);
                self.colors.push([0.0; 4]);
            }
            self.indices.extend_from_slice(&[0, 1, 2]);
        }
        Mesh::new(PrimitiveTopology::TriangleList, RenderAssetUsages::default())
            .with_inserted_attribute(Mesh::ATTRIBUTE_POSITION, self.positions)
            .with_inserted_attribute(Mesh::ATTRIBUTE_NORMAL, self.normals)
            .with_inserted_attribute(Mesh::ATTRIBUTE_UV_0, self.uvs)
            .with_inserted_attribute(Mesh::ATTRIBUTE_COLOR, self.colors)
            .with_inserted_indices(Indices::U32(self.indices))
    }
}
