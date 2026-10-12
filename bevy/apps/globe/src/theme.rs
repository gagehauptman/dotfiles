//! The globe in the wallpaper's theme. The card hands over the shell's
//! colours (`theme`: Theme.colors as #rrggbb by role), `dark`, `fonts`
//! (ui, mono, display) and `look`, the wallpaper's own `globe` block from its
//! theme.json; at create time in the options, and on every theme change as a
//! `theme` control event with the same keys as JSON (see BevyWidget.qml), so
//! the running globe recolours in place.
//!
//! Every ink is derived from the palette, so any theme gets a globe:
//!
//!   ocean    panelDeep tinted 12% towards blue      land   inset tinted 12% towards accent
//!   coast    accent                                  borders textSecondary, regions textMuted
//!   grid     textMuted                               glow   accent (the rim)
//!   home     accent2 (pink without it)               names  textPrimary / textSecondary
//!   aircraft green, yellow, orange, blue by altitude airports blue, drives red
//!   clouds   textPrimary, cold tops blue, green, yellow, red
//!   lights   blue, teal, green, yellow, orange, red, pink, textPrimary
//!
//! `look` overrides any of them (a palette role or #rrggbb[aa]): ocean, land,
//! coast, borders, regions, grid, glow, home, countries, region_names,
//! cities, capitals, airports, aircraft_low, aircraft_mid, aircraft_high,
//! aircraft_cruise, drives, terminator, dusk_warm, dusk_cool, clouds,
//! weather (four cold-top colours), lights (eight zone colours); numbers
//! glow_strength (default 0.1), land_strength (0 = no land fill, 1 =
//! the land colour as given) and night (night-side darkening, 0.3; 0.15 on
//! light themes); `font`, a role (ui, mono, display) or a family
//! for the names (default mono). The preset's `colors` still win over both.
//! Without any theme it is the old look: Catppuccin Mocha, no land fill.
use std::collections::HashMap;

use bevy::prelude::*;
use serde::Deserialize;

use crate::config::parse_color;
use crate::Palette;

/// What the card sends: in the options at create time, as JSON in a `theme` event after.
#[derive(Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(default)]
pub struct ThemeIn {
    pub theme: HashMap<String, String>,
    pub dark: Option<bool>,
    pub fonts: HashMap<String, String>,
    pub look: HashMap<String, serde_json::Value>,
}

impl ThemeIn {
    pub fn parse(json: &str) -> ThemeIn {
        serde_json::from_str(json).unwrap_or_else(|e| {
            eprintln!("globe: theme: {e}");
            ThemeIn::default()
        })
    }

    /// The family the names are set in: `look.font` as a role or a family,
    /// else the theme's mono; "monospace" (fontconfig's) without a theme.
    pub fn font_family(&self) -> String {
        let want = self.look.get("font").and_then(|v| v.as_str()).unwrap_or("mono");
        let family = match want {
            "ui" | "mono" | "display" => self.fonts.get(want).cloned().unwrap_or_default(),
            f => f.to_string(),
        };
        if family.trim().is_empty() { "monospace".into() } else { family }
    }
}

/// A theme colour by role (QML prints #aarrggbb for translucent ones), or the fallback.
fn role(theme: &HashMap<String, String>, key: &str, fallback: &str) -> Color {
    let s = theme.get(key).map(String::as_str).unwrap_or(fallback);
    let hex = s.trim_start_matches('#');
    let hex = if hex.len() == 8 { &hex[2..] } else { hex };
    let v = u32::from_str_radix(hex, 16).ok().filter(|_| hex.len() == 6);
    let v = v.unwrap_or_else(|| u32::from_str_radix(fallback.trim_start_matches('#'), 16).unwrap_or(0));
    Color::srgb_u8((v >> 16) as u8, (v >> 8) as u8, v as u8)
}

/// sRGB mix, as a designer would pick it off the palette.
fn mix(a: Color, b: Color, t: f32) -> Color {
    let (a, b) = (a.to_srgba(), b.to_srgba());
    Color::srgba(a.red + (b.red - a.red) * t, a.green + (b.green - a.green) * t, a.blue + (b.blue - a.blue) * t, a.alpha + (b.alpha - a.alpha) * t)
}

/// Relative luminance (WCAG), for keeping the names readable.
fn luminance(c: Color) -> f32 {
    let l = c.to_linear();
    0.2126 * l.red + 0.7152 * l.green + 0.0722 * l.blue
}

fn contrast(a: Color, b: Color) -> f32 {
    let (x, y) = (luminance(a), luminance(b));
    (x.max(y) + 0.05) / (x.min(y) + 0.05)
}

/// `c`, pushed away from `bg` towards `ink` until it reads at `min` contrast.
fn legible(c: Color, bg: Color, ink: Color, min: f32) -> Color {
    let mut out = c;
    let mut t = 0.0;
    while contrast(out, bg) < min && t < 1.0 {
        t += 0.1;
        out = mix(c, ink, t);
    }
    out.with_alpha(c.alpha())
}

pub fn palette(t: &ThemeIn, overrides: &HashMap<String, String>) -> Palette {
    let th = &t.theme;
    let themed = !th.is_empty();
    let pick = |key: &str, fallback: &str| role(th, key, fallback);
    // overrides: the preset's `colors` first, then the wallpaper's `look`
    let look_str = |key: &str| t.look.get(key).and_then(|v| v.as_str()).and_then(|c| parse_color(c, th));
    let over = |key: &str, base: Color| overrides.get(key).and_then(|c| parse_color(c, th)).or_else(|| look_str(key)).unwrap_or(base);
    let over2 = |keys: [&str; 2], base: Color| over(keys[0], over(keys[1], base));
    let num = |key: &str, default: f32| t.look.get(key).and_then(|v| v.as_f64()).map_or(default, |v| v as f32);
    let list = |key: &str, base: Vec<Color>| -> Vec<Color> {
        let given: Vec<Color> = t.look.get(key).and_then(|v| v.as_array()).map(|a| a.iter().filter_map(|c| c.as_str().and_then(|c| parse_color(c, th))).collect()).unwrap_or_default();
        if given.len() == base.len() { given } else { base }
    };

    let (panel_deep, inset) = (pick("panelDeep", "#11111b"), pick("inset", "#313244"));
    let (blue, accent) = (pick("blue", "#89b4fa"), pick("accent", "#89b4fa"));
    let (text1, text2, muted) = (pick("textPrimary", "#cdd6f4"), pick("textSecondary", "#a6adc8"), pick("textMuted", "#6c7086"));
    let dark = t.dark.unwrap_or_else(|| luminance(panel_deep) < 0.2);

    // The old look without a theme: the deep panel as the fill, no land, teal lines
    let ocean = over2(["ocean", "fill"], if themed { mix(panel_deep, blue, if dark { 0.12 } else { 0.10 }) } else { pick("panelDeep", "#181825") });
    let land_base = if dark { mix(inset, accent, 0.12) } else { mix(mix(inset, panel_deep, 0.15), accent, 0.10) };
    let land = over("land", land_base);
    let land_strength = num("land_strength", if themed { 1.0 } else { 0.0 }).clamp(0.0, 1.0);
    // Lines and names are read against both: the darker/lighter of the two
    let ground = if themed { mix(ocean, land, 0.5) } else { ocean };
    let ink = if dark { Color::WHITE } else { Color::BLACK };
    let coast_base = if themed { legible(accent, ground, ink, 2.2).with_alpha(0.8) } else { pick("teal", "#94e2d5").with_alpha(0.75) };
    let glow = over2(["glow", "rim"], if themed { accent } else { pick("teal", "#94e2d5") });
    let text = |key: &str, base: Color| over(key, if themed { legible(base, ground, ink, 4.0) } else { base });

    let cloud = over("clouds", if themed { text1 } else { Color::srgb_u8(205, 214, 244) });
    let cold = list("weather", vec![pick("blue", "#89b4fa"), pick("green", "#a6e3a1"), pick("yellow", "#f9e2af"), pick("red", "#f38ba8")]);
    let lights = list(
        "lights",
        ["blue", "teal", "green", "yellow", "orange", "red", "pink", "textPrimary"]
            .iter()
            .zip(["#89b4fa", "#94e2d5", "#a6e3a1", "#f9e2af", "#fab387", "#f38ba8", "#f5c2e7", "#cdd6f4"])
            .map(|(k, f)| pick(k, f))
            .collect(),
    );
    Palette {
        fill: ocean,
        land,
        land_strength,
        coast: over("coast", coast_base),
        border: over("borders", if themed { text2.with_alpha(0.4) } else { pick("lavender", "#b4befe").with_alpha(0.5) }),
        region: over("regions", muted.with_alpha(if themed { 0.45 } else { 0.6 })),
        grid: over("grid", muted.with_alpha(if themed { 0.22 } else { 0.28 })),
        rim: glow,
        glow_strength: num("glow_strength", if themed { 0.1 } else { 0.07 }).clamp(0.0, 1.0),
        night: num("night", if themed && !dark { 0.15 } else { 0.3 }).clamp(0.0, 1.0),
        home: over("home", if themed { th.get("accent2").map_or_else(|| pick("pink", "#f5c2e7"), |_| pick("accent2", "#f5c2e7")) } else { pick("pink", "#f5c2e7") }),
        air: [
            over("aircraft_low", pick("green", "#a6e3a1")),
            over("aircraft_mid", pick("yellow", "#f9e2af")),
            over("aircraft_high", pick("orange", "#fab387")),
            over("aircraft_cruise", pick("blue", "#89b4fa")),
        ],
        text: [text("countries", text1), text("region_names", text1), text("cities", text2), text("capitals", text1)],
        airport: over("airports", pick("blue", "#89b4fa")),
        drives: over("drives", pick("red", "#f38ba8")),
        terminator: over("terminator", text2),
        dusk_warm: over("dusk_warm", pick("orange", "#fab387")),
        dusk_cool: over("dusk_cool", blue),
        weather_lut: weather_lut(cloud, &cold),
        lp_lut: lp_lut(&lights, ocean),
        font: t.font_family(),
    }
}

/// 256 x 1 RGBA (sRGB) palette for the cloud-top coldness index: grey cloud
/// in the cloud colour, cold tops stepping through the four colours
/// (globeserver.py's colorize, in the theme's inks).
pub fn weather_lut(cloud: Color, cold: &[Color]) -> Vec<u8> {
    let mut out = Vec::with_capacity(256 * 4);
    let bands = [(0.6, 0.72), (0.72, 0.84), (0.84, 0.93), (0.93, 1.01)];
    for i in 0..256 {
        let v = i as f32 / 255.0;
        let mut c = cloud;
        let mut a = ((v - 0.33) / 0.2).clamp(0.0, 1.0) * 0.65;
        for (b, (lo, hi)) in bands.iter().enumerate() {
            if v >= *lo && v < *hi {
                c = cold.get(b).copied().unwrap_or(cloud);
                a = 0.9;
            }
        }
        let s = c.to_srgba();
        out.extend([(s.red * 255.0) as u8, (s.green * 255.0) as u8, (s.blue * 255.0) as u8, (a * 255.0) as u8]);
    }
    out
}

/// 256 x 1 RGBA (sRGB) palette for the light pollution zones (globeserver.py's
/// lp_colorize): a hue per zone 1-7 and one for 7b; sub-zone a pulled towards
/// the ocean, alpha rising with the zone, zone 0 clear.
pub fn lp_lut(pal: &[Color], tint: Color) -> Vec<u8> {
    let alphas = [0.0, 0.18, 0.28, 0.36, 0.44, 0.50, 0.56, 0.60, 0.64, 0.68, 0.72, 0.76, 0.80, 0.84, 0.88];
    let mut out = vec![0u8; 256 * 4];
    for idx in 1..15usize {
        let zone = (idx + 1) / 2;
        let mut c = if idx == 14 { pal[7] } else { pal[zone - 1] };
        if idx % 2 == 1 {
            c = mix(tint, c, 0.62);
        }
        let s = c.to_srgba();
        out[idx * 4..idx * 4 + 4].copy_from_slice(&[(s.red * 255.0) as u8, (s.green * 255.0) as u8, (s.blue * 255.0) as u8, (alphas[idx] * 255.0) as u8]);
    }
    out
}

/// The font file fontconfig picks for a family.
pub fn font_file(family: &str) -> Option<Vec<u8>> {
    let out = std::process::Command::new("fc-match").args(["-f", "%{file}", family]).output().ok()?;
    let path = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if path.is_empty() {
        return None;
    }
    std::fs::read(path).ok()
}
