//! The card's preset `options` for the globe. Everything has a default, so
//! `{}` is a valid configuration; the README documents the schema.
use std::collections::HashMap;

use bevy::prelude::*;
use serde::Deserialize;

#[derive(Resource, Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct Options {
    /// the shell's colours, added by the widget
    pub theme: HashMap<String, String>,
    /// layers to start on, out of weather, lp, air, sats (default weather and sats)
    pub layers: Option<Vec<String>>,
    pub satellites: SatConfig,
    pub view: Option<ViewOption>,
    pub server: Option<String>,
    /// device pixel ratio of the screen, added by the widget
    pub scale: Option<f32>,
    /// home instead of geolocating: [lat, lon], a place name, or {location, label}
    pub home: Option<HomeConfig>,
    pub weather: WeatherOptions,
    pub lights: LightsOptions,
    pub aircraft: AircraftOptions,
    pub labels: LabelOptions,
    pub graticule: GridOptions,
    /// palette overrides: coast, borders, regions, grid, rim, home, fill,
    /// countries, region_names, cities, capitals, aircraft_low, aircraft_mid,
    /// aircraft_high, aircraft_cruise; values are theme names or hex
    pub colors: HashMap<String, String>,
    /// what the user changed in the card's settings panel last time (the
    /// widget adds it; the same ids as the panel's controls)
    pub settings: HashMap<String, String>,
}

/// What a changed setting affects, so the app refreshes just that.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Change {
    Layers,
    Material,
    Grid,
    Satellites,
    /// satellites, and the elements have to be fetched again
    SatelliteSet,
    Labels,
    Aircraft,
}

fn list(v: &str) -> Vec<String> {
    v.split(',').map(str::trim).filter(|x| !x.is_empty()).map(String::from).collect()
}

fn num(v: &str) -> Option<f32> {
    v.trim().parse::<f32>().ok()
}

impl Options {
    /// Apply one setting (a panel control's id and event value); None when
    /// the id is not a setting or the value does not parse.
    pub fn apply(&mut self, id: &str, value: &str) -> Option<Change> {
        let on = || matches!(value.trim(), "true" | "1" | "on");
        Some(match id {
            "weather" | "lp" | "air" | "sats" => {
                let mut layers = self.layers.clone().unwrap_or_else(|| ["weather", "sats"].map(String::from).to_vec());
                layers.retain(|l| l != id);
                if on() {
                    layers.push(id.to_string());
                }
                self.layers = Some(layers);
                Change::Layers
            }
            "weather.opacity" => {
                self.weather.opacity = num(value)?.clamp(0.0, 1.0);
                Change::Material
            }
            "weather.saturation" => {
                self.weather.saturation = num(value)?.clamp(0.0, 1.0);
                Change::Material
            }
            "lights.opacity" => {
                self.lights.opacity = num(value)?.clamp(0.0, 1.0);
                Change::Material
            }
            "lights.day" => {
                self.lights.day = num(value)?.clamp(0.0, 1.0);
                Change::Material
            }
            "graticule.show" => {
                self.graticule.show = on();
                Change::Grid
            }
            "graticule.step" => {
                self.graticule.step = num(value)?.clamp(1.0, 90.0);
                Change::Grid
            }
            "aircraft.min_altitude" => {
                self.aircraft.min_altitude = num(value)?.max(0.0);
                Change::Aircraft
            }
            "aircraft.min_speed" => {
                self.aircraft.min_speed = num(value)?.max(0.0);
                Change::Aircraft
            }
            "aircraft.size" => {
                self.aircraft.size = num(value)?.clamp(0.2, 4.0);
                Change::Aircraft
            }
            "aircraft.declutter" => {
                self.aircraft.declutter = on();
                Change::Aircraft
            }
            "aircraft.tails" => {
                self.aircraft.tails = on();
                Change::Aircraft
            }
            "aircraft.labels" => {
                self.aircraft.labels = on();
                Change::Aircraft
            }
            "labels.countries" => {
                self.labels.countries = on();
                Change::Labels
            }
            "labels.regions" => {
                self.labels.regions = on();
                Change::Labels
            }
            "labels.cities" => {
                self.labels.cities = on();
                Change::Labels
            }
            "labels.airports" => {
                self.labels.airports = on();
                Change::Labels
            }
            "labels.min_population" => {
                self.labels.min_population = num(value)?.max(0.0);
                Change::Labels
            }
            "labels.size" => {
                self.labels.size = num(value)?.clamp(0.5, 2.0);
                Change::Labels
            }
            _ if id.starts_with("satellites.") => {
                let mut so = self.sats();
                let change = match &id["satellites.".len()..] {
                    "groups" => {
                        so.groups = list(value);
                        Change::SatelliteSet
                    }
                    "extra" => {
                        so.extra = list(value).into_iter().map(|x| x.parse::<u32>().map(Extra::Norad).unwrap_or(Extra::Name(x))).collect();
                        Change::SatelliteSet
                    }
                    "show" => {
                        let l = list(value);
                        so.show = if l.is_empty() { None } else { Some(l) };
                        Change::Satellites
                    }
                    "hide" => {
                        so.hide = list(value);
                        Change::Satellites
                    }
                    "tracks" => {
                        so.tracks = list(value);
                        Change::Satellites
                    }
                    "track_groups" => {
                        so.track_groups = list(value);
                        Change::Satellites
                    }
                    "labels" => {
                        let l = list(value);
                        so.labels = if l.is_empty() { None } else { Some(l) };
                        Change::Satellites
                    }
                    "track.orbits" => {
                        so.track.orbits = num(value)?.clamp(0.05, 4.0);
                        Change::Satellites
                    }
                    "size" => {
                        so.size = num(value)?.clamp(0.2, 4.0);
                        Change::Satellites
                    }
                    _ => return None,
                };
                self.satellites = SatConfig::Full(so);
                change
            }
            _ => return None,
        })
    }
}



impl Options {
    pub fn parse(json: &str) -> Options {
        match serde_json::from_str::<Options>(json) {
            Ok(o) => o,
            Err(e) => {
                eprintln!("globe: options: {e}; using defaults");
                serde_json::from_str::<ThemeOnly>(json).map(|t| Options { theme: t.theme, scale: t.scale, ..Default::default() }).unwrap_or_default()
            }
        }
    }

    pub fn layer_on(&self, name: &str, default: bool) -> bool {
        self.layers.as_ref().map(|l| l.iter().any(|x| x == name)).unwrap_or(default)
    }

    pub fn sats(&self) -> SatOptions {
        match &self.satellites {
            SatConfig::Groups(g) => SatOptions { groups: g.clone(), ..Default::default() },
            SatConfig::Full(s) => s.clone(),
        }
    }

    /// Query string for the service's /geo.json.
    pub fn geo_query(&self) -> String {
        let enc = |s: &str| s.bytes().map(|b| if b.is_ascii_alphanumeric() || b == b'-' || b == b'.' || b == b'_' { (b as char).to_string() } else { format!("%{:02X}", b) }).collect::<String>();
        match &self.home {
            None => String::new(),
            Some(HomeConfig::Coords([lat, lon])) => format!("location={lat},{lon}"),
            Some(HomeConfig::Place(p)) => format!("location={}", enc(p)),
            Some(HomeConfig::Detailed { location, label }) => {
                format!("location={}&label={}", enc(location), enc(label.as_deref().unwrap_or("")))
            }
        }
    }
}

/// Just enough to keep the theme when the rest of the options are malformed
#[derive(Deserialize, Default)]
#[serde(default)]
struct ThemeOnly {
    theme: HashMap<String, String>,
    scale: Option<f32>,
}

#[derive(Deserialize, Clone, Debug)]
#[serde(untagged)]
pub enum HomeConfig {
    Coords([f32; 2]),
    Place(String),
    Detailed { location: String, #[serde(default)] label: Option<String> },
}

#[derive(Deserialize, Clone, Debug)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum ViewOption {
    Focus { lat: f32, lon: f32, #[serde(default)] dist: Option<f32> },
    Chase { satellite: String, #[serde(default)] target: Option<[f32; 2]>, #[serde(default)] standoff: Option<f32> },
}

// ---------------------------------------------------------------- satellites

/// `"satellites": ["stations", "visual"]` or the full object
#[derive(Deserialize, Clone, Debug)]
#[serde(untagged)]
pub enum SatConfig {
    Groups(Vec<String>),
    Full(SatOptions),
}

impl Default for SatConfig {
    fn default() -> Self {
        SatConfig::Full(SatOptions::default())
    }
}

#[derive(Resource, Deserialize, Clone, Debug)]
#[serde(default)]
pub struct SatOptions {
    /// CelesTrak groups to load: stations, visual, weather, gnss, science, starlink
    pub groups: Vec<String>,
    /// single satellites on top of the groups: NORAD numbers or CelesTrak name searches
    pub extra: Vec<Extra>,
    /// only these are drawn (patterns; default all loaded)
    pub show: Option<Vec<String>>,
    /// never drawn (patterns)
    pub hide: Vec<String>,
    /// single satellites that get an orbit line on top of `track_groups` (patterns; default none)
    pub tracks: Vec<String>,
    /// whole groups that get orbit lines (the panel's "Orbit lines")
    pub track_groups: Vec<String>,
    /// which get their name drawn (patterns; default the ISS, Tiangong and Hubble)
    pub labels: Option<Vec<String>>,
    pub track: TrackOptions,
    /// per-satellite looks, first match wins
    pub style: Vec<StyleRule>,
    /// marker size multiplier
    pub size: f32,
}

impl Default for SatOptions {
    fn default() -> Self {
        SatOptions {
            groups: ["stations", "visual", "weather", "gnss"].map(String::from).to_vec(),
            extra: Vec::new(),
            show: None,
            hide: Vec::new(),
            tracks: Vec::new(),
            track_groups: Vec::new(),
            labels: Some(["ISS (ZARYA)", "CSS (TIANHE)", "HST"].map(String::from).to_vec()),
            track: TrackOptions::default(),
            style: Vec::new(),
            size: 1.0,
        }
    }
}

#[derive(Deserialize, Clone, Debug)]
#[serde(untagged)]
pub enum Extra {
    Norad(u32),
    Name(String),
}

#[derive(Deserialize, Clone, Debug)]
#[serde(default)]
pub struct TrackOptions {
    /// how much of an orbit to draw, centred on now (1 = one revolution)
    pub orbits: f32,
    pub points: usize,
    pub alpha: f32,
}

impl Default for TrackOptions {
    fn default() -> Self {
        TrackOptions { orbits: 1.0, points: 128, alpha: 0.45 }
    }
}

/// `{ "match": "GPS*", "color": "blue", "size": 4, "track_color": "blue", "track_alpha": 0.6 }`
#[derive(Deserialize, Clone, Debug, Default)]
#[serde(default)]
pub struct StyleRule {
    #[serde(rename = "match")]
    pub patterns: Patterns,
    pub color: Option<String>,
    pub size: Option<f32>,
    pub track_color: Option<String>,
    pub track_alpha: Option<f32>,
}

#[derive(Deserialize, Clone, Debug)]
#[serde(untagged)]
pub enum Patterns {
    One(String),
    Many(Vec<String>),
}

impl Default for Patterns {
    fn default() -> Self {
        Patterns::Many(Vec::new())
    }
}

impl Patterns {
    fn any(&self, name: &str, norad: u32, group: &str) -> bool {
        match self {
            Patterns::One(p) => matches(p, name, norad, group),
            Patterns::Many(v) => v.iter().any(|p| matches(p, name, norad, group)),
        }
    }
}

/// A pattern is a NORAD number, `group:NAME`, or a case-insensitive glob
/// on the name (`*` any run, `?` one character; "ISS" alone matches the
/// name "ISS" or "ISS (ZARYA)").
pub fn matches(pattern: &str, name: &str, norad: u32, group: &str) -> bool {
    let p = pattern.trim();
    if let Some(g) = p.strip_prefix("group:") {
        return g.trim().eq_ignore_ascii_case(group);
    }
    if let Ok(n) = p.parse::<u32>() {
        return n == norad;
    }
    let (p, n) = (p.to_uppercase(), name.trim().to_uppercase());
    if !p.contains('*') && !p.contains('?') {
        return n == p || n.starts_with(&format!("{p} "));
    }
    glob(p.as_bytes(), n.as_bytes())
}

fn glob(p: &[u8], s: &[u8]) -> bool {
    match (p.first(), s.first()) {
        (None, None) => true,
        (Some(b'*'), _) => glob(&p[1..], s) || (!s.is_empty() && glob(p, &s[1..])),
        (Some(b'?'), Some(_)) => glob(&p[1..], &s[1..]),
        (Some(a), Some(b)) if a == b => glob(&p[1..], &s[1..]),
        _ => false,
    }
}

fn list_matches(list: &[String], name: &str, norad: u32, group: &str) -> bool {
    list.iter().any(|p| matches(p, name, norad, group))
}

/// How one satellite is drawn, resolved from the options once its elements arrive.
#[derive(Clone, Debug)]
pub struct SatStyle {
    pub show: bool,
    pub track: bool,
    pub label: bool,
    pub size: f32,
    pub color: Option<Color>,
    pub track_color: Option<Color>,
    pub track_alpha: f32,
}

impl SatOptions {
    /// Query string for the service's /tle.json; empty when nothing is to be loaded.
    pub fn query(&self) -> String {
        if self.groups.is_empty() && self.extra.is_empty() {
            return String::new();
        }
        let mut q = format!("groups={}", self.groups.join(","));
        let nums: Vec<String> = self.extra.iter().filter_map(|e| if let Extra::Norad(n) = e { Some(n.to_string()) } else { None }).collect();
        if !nums.is_empty() {
            q += &format!("&catnr={}", nums.join(","));
        }
        let names: Vec<String> = self
            .extra
            .iter()
            .filter_map(|e| if let Extra::Name(n) = e { Some(n.replace(' ', "%20").replace('&', "%26")) } else { None })
            .collect();
        if !names.is_empty() {
            q += &format!("&names={}", names.join(","));
        }
        q
    }

    pub fn style_for(&self, name: &str, norad: u32, group: &str, theme: &HashMap<String, String>) -> SatStyle {
        let show = self.show.as_ref().map_or(true, |l| list_matches(l, name, norad, group)) && !list_matches(&self.hide, name, norad, group);
        let track = list_matches(&self.tracks, name, norad, group) || self.track_groups.iter().any(|g| g.eq_ignore_ascii_case(group));
        let label = self.labels.as_ref().map_or(false, |l| list_matches(l, name, norad, group));
        let rule = self.style.iter().find(|r| r.patterns.any(name, norad, group));
        SatStyle {
            show,
            track,
            label,
            size: rule.and_then(|r| r.size).unwrap_or(1.0) * self.size,
            color: rule.and_then(|r| r.color.as_deref()).and_then(|c| parse_color(c, theme)),
            track_color: rule.and_then(|r| r.track_color.as_deref()).and_then(|c| parse_color(c, theme)),
            track_alpha: rule.and_then(|r| r.track_alpha).unwrap_or(self.track.alpha),
        }
    }
}

// ---------------------------------------------------------------- other layers

#[derive(Deserialize, Clone, Debug)]
#[serde(default)]
pub struct WeatherOptions {
    pub opacity: f32,
    /// 0 grey clouds, 1 the full cold-top palette
    pub saturation: f32,
}

impl Default for WeatherOptions {
    fn default() -> Self {
        WeatherOptions { opacity: 0.75, saturation: 0.55 }
    }
}

#[derive(Deserialize, Clone, Debug)]
#[serde(default)]
pub struct LightsOptions {
    pub opacity: f32,
    /// how much shows on the day side (1 = as much as at night)
    pub day: f32,
}

impl Default for LightsOptions {
    fn default() -> Self {
        LightsOptions { opacity: 0.8, day: 0.25 }
    }
}

#[derive(Deserialize, Clone, Debug)]
#[serde(default)]
pub struct AircraftOptions {
    /// slower and lower than both is parked or taxiing and left out
    pub min_speed: f32,
    pub min_altitude: f32,
    /// marker size multiplier
    pub size: f32,
    /// altitude bands (feet) for the four colours
    pub bands: [f32; 3],
    /// zoomed out, only higher traffic shows (24 000 ft far out, 12 000 mid, all when close)
    pub declutter: bool,
    /// short tails of recent positions when zoomed in
    pub tails: bool,
    /// callsigns beside the markers when zoomed in
    pub labels: bool,
}

impl Default for AircraftOptions {
    fn default() -> Self {
        AircraftOptions { min_speed: 40.0, min_altitude: 500.0, size: 1.0, bands: [10_000.0, 25_000.0, 36_000.0], declutter: true, tails: true, labels: true }
    }
}

#[derive(Deserialize, Clone, Debug)]
#[serde(default)]
pub struct LabelOptions {
    pub countries: bool,
    pub regions: bool,
    pub cities: bool,
    /// airport diamonds and codes
    pub airports: bool,
    /// cities below this population are left out
    pub min_population: f32,
    /// text size multiplier
    pub size: f32,
}

impl Default for LabelOptions {
    fn default() -> Self {
        LabelOptions { countries: true, regions: true, cities: true, airports: true, min_population: 0.0, size: 1.0 }
    }
}

#[derive(Deserialize, Clone, Debug)]
#[serde(default)]
pub struct GridOptions {
    pub show: bool,
    /// degrees between lines
    pub step: f32,
}

impl Default for GridOptions {
    fn default() -> Self {
        GridOptions { show: true, step: 15.0 }
    }
}

/// A theme colour name ("teal"), `#rrggbb`, `#rrggbbaa` or `rrggbb`.
pub fn parse_color(spec: &str, theme: &HashMap<String, String>) -> Option<Color> {
    let spec = spec.trim();
    if let Some(t) = theme.get(spec) {
        return parse_color(t, &HashMap::new());
    }
    let hex = spec.trim_start_matches('#');
    if !hex.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    match hex.len() {
        6 => u32::from_str_radix(hex, 16).ok().map(|v| Color::srgb_u8((v >> 16) as u8, (v >> 8) as u8, v as u8)),
        8 => u32::from_str_radix(hex, 16).ok().map(|v| Color::srgba_u8((v >> 24) as u8, (v >> 16) as u8, (v >> 8) as u8, v as u8)),
        _ => None,
    }
}

