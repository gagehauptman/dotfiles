//! Background polling of the globe service. Three threads (textures,
//! vectors, aircraft) push messages into a channel the app drains every
//! frame; all stop when the `Feed` resource is dropped with the widget.
use std::io::Read;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use bevy::prelude::Resource;

use crate::sats::Sat;
use crate::sphere;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Weather,
    WeatherInset,
    Lp,
    LpInset,
    WeatherLut,
    LpLut,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TexFormat {
    R8,
    Rg8,
    Rgba8,
}

/// Inset windows: Mercator tiles around home at the sources' best zoom
const WX_INSET_Z: u32 = 6;
const LP_INSET_Z: u32 = 8;
const INSET_N: u32 = 16;

#[derive(Clone, Debug, Default)]
pub struct Aircraft {
    pub hex: String,
    pub flight: String,
    pub lat: f32,
    pub lon: f32,
    pub track: f32,
    /// feet
    pub alt: f32,
    /// knots
    pub gs: f32,
}

#[derive(Clone, Debug, Default)]
pub struct Airport {
    pub code: String,
    pub lat: f32,
    pub lon: f32,
}

/// Everything the service knows about one aircraft (`/aircraft/{hex}.json`).
#[derive(Clone, Debug, Default)]
pub struct Detail {
    pub hex: String,
    pub known: bool,
    pub flight: String,
    pub typ: String,
    pub reg: String,
    pub alt: f32,
    pub gs: f32,
    pub origin: Option<Airport>,
    pub destination: Option<Airport>,
    /// (lat, lon, alt ft) from take-off to the latest position seen
    pub trail: Vec<(f32, f32, f32)>,
}

/// What the app asks the network threads for.
pub enum Cmd {
    /// Follow this aircraft (details now and every 10 s), or none
    Select(Option<String>),
    /// Fetch the elements for this /tle.json query (empty: none)
    Sats(String),
}

/// One line layer of the vector bundle, ready for a LineList mesh.
pub struct LineLayer {
    pub name: String,
    pub positions: Vec<[f32; 3]>,
    pub indices: Vec<u32>,
}

/// A place name on the globe. `rank` is the web-map zoom it is meant for
/// (lower = more important); `kind`: 0 country, 1 region, 2 place, 3 capital;
/// `pop` the population where known (places and countries).
pub struct Label {
    pub text: String,
    pub pos: [f32; 3],
    pub rank: f32,
    pub kind: u8,
    pub pop: f32,
}

pub struct Vectors {
    pub layers: Vec<LineLayer>,
    pub labels: Vec<Label>,
}

pub enum Msg {
    Geo { lat: f32, lon: f32, city: String },
    /// `stamp`: the frame's unix time (weather), 0 otherwise. `window`: for an
    /// inset, its (west edge rad, lon span rad, Mercator y of the north edge,
    /// y span); zeros for a global layer.
    Texture { kind: Kind, width: u32, height: u32, data: Vec<u8>, format: TexFormat, stamp: i64, window: [f32; 4] },
    Air { rows: Vec<Aircraft>, ts: f64 },
    Vectors(Box<Vectors>),
    Detail(Box<Detail>),
    Sats(Vec<Sat>),
}

#[derive(Clone)]
pub struct Config {
    pub base: String,
    /// query string for /lp.png (palette and tint)
    pub lp_query: String,
    /// query string for /geo.json (a home override), or empty
    pub geo_query: String,
    /// radius the line layers are placed at
    pub line_radius: f32,
    /// query string for /tle.json (empty: no satellites)
    pub sat_query: String,
}

struct Cur<'a> {
    b: &'a [u8],
    i: usize,
}

impl<'a> Cur<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8], String> {
        let s = self.b.get(self.i..self.i + n).ok_or("vectors: truncated")?;
        self.i += n;
        Ok(s)
    }
    fn u8(&mut self) -> Result<u8, String> {
        Ok(self.take(1)?[0])
    }
    fn u16(&mut self) -> Result<u16, String> {
        Ok(u16::from_le_bytes(self.take(2)?.try_into().map_err(|_| "vectors: short")?))
    }
    fn u32(&mut self) -> Result<u32, String> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().map_err(|_| "vectors: short")?))
    }
    fn f32(&mut self) -> Result<f32, String> {
        Ok(f32::from_le_bytes(self.take(4)?.try_into().map_err(|_| "vectors: short")?))
    }
    fn str(&mut self, n: usize) -> Result<String, String> {
        Ok(String::from_utf8_lossy(self.take(n)?).into_owned())
    }
}

/// Parse the service's bundle (format in globeserver.py, vectors_build) into
/// meshes-to-be on a sphere of radius `r`.
pub fn parse_vectors(b: &[u8], r: f32) -> Result<Vectors, String> {
    let mut c = Cur { b, i: 0 };
    if c.take(4)? != b"GLV3" {
        return Err("vectors: not a GLV3 bundle".into());
    }
    let mut layers = Vec::new();
    for _ in 0..c.u32()? {
        let n = c.u8()? as usize;
        let name = c.str(n)?;
        let mut positions = Vec::new();
        let mut indices = Vec::new();
        let mut line = Vec::new();
        for _ in 0..c.u32()? {
            line.clear();
            for _ in 0..c.u32()? {
                let lat = c.f32()?;
                let lon = c.f32()?;
                line.push((lat, lon));
            }
            sphere::surface_polyline(line.iter().copied(), r, &mut positions, &mut indices);
        }
        layers.push(LineLayer { name, positions, indices });
    }
    let mut labels = Vec::new();
    for _ in 0..c.u32()? {
        let n = c.u8()? as usize;
        let _set = c.str(n)?;
        for _ in 0..c.u32()? {
            let n = c.u16()? as usize;
            let text = c.str(n)?;
            let lat = c.f32()?.to_radians();
            let lon = c.f32()?.to_radians();
            let rank = c.f32()?;
            let kind = c.u8()?;
            let pop = c.f32()?;
            labels.push(Label { text, pos: sphere::latlon(lat, lon).to_array(), rank, kind, pop });
        }
    }
    Ok(Vectors { layers, labels })
}

#[derive(Resource)]
pub struct Feed {
    pub rx: Mutex<Receiver<Msg>>,
    pub cmd: Mutex<Sender<Cmd>>,
    stop: Arc<AtomicBool>,
}

impl Feed {
    pub fn send(&self, cmd: Cmd) {
        if let Ok(tx) = self.cmd.lock() {
            let _ = tx.send(cmd);
        }
    }
}

impl Drop for Feed {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

pub fn start(cfg: Config) -> Feed {
    let (tx, rx) = channel();
    let (cmd_tx, cmd_rx) = channel();
    let stop = Arc::new(AtomicBool::new(false));
    {
        let (cfg, tx, stop) = (cfg.clone(), tx.clone(), stop.clone());
        thread::Builder::new().name("globe-textures".into()).spawn(move || textures(cfg, tx, stop)).ok();
    }
    {
        let (cfg, tx, stop) = (cfg.clone(), tx.clone(), stop.clone());
        thread::Builder::new().name("globe-vectors".into()).spawn(move || vectors(cfg, tx, stop)).ok();
    }
    {
        let stop = stop.clone();
        thread::Builder::new().name("globe-aircraft".into()).spawn(move || aircraft(cfg, tx, cmd_rx, stop)).ok();
    }
    Feed { rx: Mutex::new(rx), cmd: Mutex::new(cmd_tx), stop }
}

fn agent(read_secs: u64) -> ureq::Agent {
    ureq::AgentBuilder::new().timeout_connect(Duration::from_secs(5)).timeout_read(Duration::from_secs(read_secs)).build()
}

fn get(agent: &ureq::Agent, url: &str) -> Result<Vec<u8>, String> {
    let resp = agent.get(url).call().map_err(|e| e.to_string())?;
    let mut buf = Vec::new();
    resp.into_reader().read_to_end(&mut buf).map_err(|e| e.to_string())?;
    Ok(buf)
}

/// Sleep in one-second steps; false once the widget is going away.
fn pause(stop: &AtomicBool, secs: u64) -> bool {
    for _ in 0..secs {
        if stop.load(Ordering::Relaxed) {
            return false;
        }
        thread::sleep(Duration::from_secs(1));
    }
    !stop.load(Ordering::Relaxed)
}

fn wait_ready(cfg: &Config, stop: &AtomicBool) -> bool {
    let a = agent(3);
    loop {
        if stop.load(Ordering::Relaxed) {
            return false;
        }
        if get(&a, &format!("{}/health", cfg.base)).map(|b| b == b"ok").unwrap_or(false) {
            return true;
        }
        thread::sleep(Duration::from_secs(1));
    }
}

fn decode_png(bytes: &[u8], format: TexFormat) -> Result<(u32, u32, Vec<u8>), String> {
    let img = image::load_from_memory_with_format(bytes, image::ImageFormat::Png).map_err(|e| e.to_string())?;
    let (w, h) = (img.width(), img.height());
    let data = match format {
        TexFormat::R8 => img.into_luma8().into_raw(),
        TexFormat::Rg8 => img.into_luma_alpha8().into_raw(),
        TexFormat::Rgba8 => img.into_rgba8().into_raw(),
    };
    Ok((w, h, data))
}

/// An n x n tile window at zoom z around a point: its (x0, y0) and the
/// window as the shader wants it (west edge rad, lon span rad, Mercator y of
/// the north edge with 0 at the pole, y span).
fn tile_window(lat: f32, lon: f32, z: u32, n: u32) -> (u32, u32, [f32; 4]) {
    let nt = (1u32 << z) as f32;
    let xf = (lon + 180.0) / 360.0 * nt;
    let latr = lat.to_radians();
    let yf = (1.0 - (latr.tan() + 1.0 / latr.cos()).ln() / std::f32::consts::PI) / 2.0 * nt;
    let x0 = (xf - n as f32 / 2.0).floor().rem_euclid(nt);
    let y0 = (yf - n as f32 / 2.0).floor().clamp(0.0, nt - n as f32);
    let window = [(x0 / nt * 360.0 - 180.0).to_radians(), (n as f32 / nt * 360.0).to_radians(), y0 / nt, n as f32 / nt];
    (x0 as u32, y0 as u32, window)
}

fn textures(cfg: Config, tx: Sender<Msg>, stop: Arc<AtomicBool>) {
    if !wait_ready(&cfg, &stop) {
        return;
    }
    let quick = agent(30);
    let slow = agent(900); // a cold texture is built from many tiles
    let fetch_tex = |kind: Kind, path: String, format: TexFormat, stamp: i64, window: [f32; 4]| -> bool {
        match get(&slow, &format!("{}{}", cfg.base, path)).and_then(|b| decode_png(&b, format)) {
            Ok((width, height, data)) => tx.send(Msg::Texture { kind, width, height, data, format, stamp, window }).is_ok(),
            Err(e) => {
                eprintln!("globe: {path}: {e}");
                false
            }
        }
    };
    let mut geo: Option<(f32, f32)> = None;
    let mut luts_done = false;
    let mut lp_done = false;
    let mut lp_inset_done = false;
    let mut weather_at: i64 = -1;
    let mut weather_inset_at: i64 = -1;
    let mut next_weather_check = 0u64;
    let mut tick = 0u64;
    loop {
        if geo.is_none() {
            if let Ok(b) = get(&quick, &format!("{}/geo.json?{}", cfg.base, cfg.geo_query)) {
                if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&b) {
                    if let (Some(lat), Some(lon)) = (v["lat"].as_f64(), v["lon"].as_f64()) {
                        let city = v["city"].as_str().unwrap_or("").to_string();
                        let _ = tx.send(Msg::Geo { lat: lat as f32, lon: lon as f32, city });
                        geo = Some((lat as f32, lon as f32));
                    }
                }
            }
        }
        if !luts_done {
            luts_done = fetch_tex(Kind::WeatherLut, "/weather/lut.png".into(), TexFormat::Rgba8, 0, [0.0; 4])
                && fetch_tex(Kind::LpLut, format!("/lp/lut.png?{}", cfg.lp_query), TexFormat::Rgba8, 0, [0.0; 4]);
        }
        if !lp_done {
            lp_done = fetch_tex(Kind::Lp, "/lp.png".into(), TexFormat::R8, 0, [0.0; 4]);
        }
        if let (Some((lat, lon)), false) = (geo, lp_inset_done) {
            let (x0, y0, window) = tile_window(lat, lon, LP_INSET_Z, INSET_N);
            lp_inset_done = fetch_tex(Kind::LpInset, format!("/lp/inset.png?z={LP_INSET_Z}&x0={x0}&y0={y0}&n={INSET_N}"), TexFormat::R8, 0, window);
        }
        if tick >= next_weather_check {
            next_weather_check = tick + 120;
            if let Ok(b) = get(&quick, &format!("{}/weather.json", cfg.base)) {
                if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&b) {
                    if let Some(t) = v["latest"].as_i64() {
                        if t != weather_at && fetch_tex(Kind::Weather, format!("/weather/{t}.png"), TexFormat::Rg8, t, [0.0; 4]) {
                            weather_at = t;
                        }
                        if let Some((lat, lon)) = geo {
                            if t != weather_inset_at {
                                let (x0, y0, window) = tile_window(lat, lon, WX_INSET_Z, INSET_N);
                                if fetch_tex(Kind::WeatherInset, format!("/weather/{t}/inset.png?z={WX_INSET_Z}&x0={x0}&y0={y0}&n={INSET_N}"), TexFormat::Rg8, t, window) {
                                    weather_inset_at = t;
                                }
                            }
                        }
                    }
                }
            }
        }
        let settled = geo.is_some() && lp_done && luts_done;
        if !pause(&stop, if settled { 10 } else { 5 }) {
            return;
        }
        tick += if settled { 10 } else { 5 };
    }
}

/// Coastlines, borders and names: one fetch, retried until it lands (the
/// first build on a machine downloads Natural Earth and takes a while).
fn vectors(cfg: Config, tx: Sender<Msg>, stop: Arc<AtomicBool>) {
    if !wait_ready(&cfg, &stop) {
        return;
    }
    let slow = agent(900);
    loop {
        match get(&slow, &format!("{}/vectors.bin", cfg.base)).and_then(|b| parse_vectors(&b, cfg.line_radius)) {
            Ok(v) => {
                let _ = tx.send(Msg::Vectors(Box::new(v)));
                break;
            }
            Err(e) => eprintln!("globe: {e}"),
        }
        if !pause(&stop, 30) {
            return;
        }
    }
}

fn parse_detail(hex: &str, b: &[u8]) -> Detail {
    let v: serde_json::Value = match serde_json::from_slice(b) {
        Ok(v) => v,
        Err(_) => return Detail { hex: hex.into(), ..Default::default() },
    };
    if v.get("error").is_some() {
        return Detail { hex: hex.into(), ..Default::default() };
    }
    let text = |x: &serde_json::Value| x.as_str().unwrap_or("").trim().to_string();
    let num = |x: &serde_json::Value| x.as_f64().unwrap_or(0.0) as f32;
    let airport = |x: &serde_json::Value| -> Option<Airport> {
        let (lat, lon) = (x.get("lat")?.as_f64()?, x.get("lon")?.as_f64()?);
        let iata = text(&x["iata"]);
        Some(Airport { code: if iata.is_empty() { text(&x["icao"]) } else { iata }, lat: lat as f32, lon: lon as f32 })
    };
    let route = &v["route"];
    let trail = v["trail"]["points"]
        .as_array()
        .map(|pts| pts.iter().map(|p| (num(&p["lat"]), num(&p["lon"]), num(&p["alt"]))).filter(|p| p.0 != 0.0 || p.1 != 0.0).collect())
        .unwrap_or_default();
    Detail {
        hex: hex.into(),
        known: true,
        flight: text(&v["flight"]),
        typ: text(&v["type"]),
        reg: text(&v["reg"]),
        alt: num(&v["alt"]),
        gs: num(&v["gs"]),
        origin: airport(&route["origin"]),
        destination: airport(&route["destination"]),
        trail,
    }
}

/// The aircraft frame every 20 s, the details of a selected aircraft
/// straight away and every 10 s while it stays selected, and the satellites'
/// elements (on start, whenever the set changes, and every six hours).
fn aircraft(cfg: Config, tx: Sender<Msg>, cmds: Receiver<Cmd>, stop: Arc<AtomicBool>) {
    if !wait_ready(&cfg, &stop) {
        return;
    }
    let a = agent(30);
    let slow = agent(300);
    let mut selected: Option<String> = None;
    let mut sat_query = cfg.sat_query.clone();
    let mut next_frame = Instant::now();
    let mut next_detail = Instant::now();
    let mut next_sats = Instant::now();
    loop {
        while let Ok(cmd) = cmds.try_recv() {
            match cmd {
                Cmd::Select(hex) => {
                    selected = hex;
                    next_detail = Instant::now();
                }
                Cmd::Sats(q) => {
                    sat_query = q;
                    next_sats = Instant::now();
                }
            }
        }
        let now = Instant::now();
        if now >= next_sats {
            next_sats = now + Duration::from_secs(6 * 3600);
            if sat_query.is_empty() {
                let _ = tx.send(Msg::Sats(Vec::new()));
            } else {
                match get(&slow, &format!("{}/tle.json?{}", cfg.base, sat_query)) {
                    Ok(b) => {
                        let sats = crate::sats::parse(&b);
                        if sats.is_empty() {
                            next_sats = now + Duration::from_secs(300);
                        }
                        let _ = tx.send(Msg::Sats(sats));
                    }
                    Err(e) => {
                        eprintln!("globe: tle: {e}");
                        next_sats = now + Duration::from_secs(60);
                    }
                }
            }
        }
        if now >= next_frame {
            next_frame = now + Duration::from_secs(20);
            if let Ok(b) = get(&a, &format!("{}/adsb.json", cfg.base)) {
                if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&b) {
                    let rows = v["rows"]
                        .as_array()
                        .map(|rows| {
                            rows.iter()
                                .filter_map(|r| {
                                    let f = |i: usize| r.get(i).and_then(|x| x.as_f64()).unwrap_or(0.0) as f32;
                                    let t = |i: usize| r.get(i).and_then(|x| x.as_str()).unwrap_or("").trim().to_string();
                                    let (lat, lon) = (f(2), f(3));
                                    (lat != 0.0 || lon != 0.0).then(|| Aircraft { hex: t(0), flight: t(1), lat, lon, track: f(4), alt: f(5), gs: f(6) })
                                })
                                .collect::<Vec<_>>()
                        })
                        .unwrap_or_default();
                    let _ = tx.send(Msg::Air { rows, ts: v["ts"].as_f64().unwrap_or(0.0) });
                }
            }
        }
        if let Some(hex) = selected.clone() {
            if now >= next_detail {
                next_detail = now + Duration::from_secs(10);
                match get(&a, &format!("{}/aircraft/{}.json", cfg.base, hex)) {
                    Ok(b) => {
                        let _ = tx.send(Msg::Detail(Box::new(parse_detail(&hex, &b))));
                    }
                    Err(e) => eprintln!("globe: aircraft {hex}: {e}"),
                }
            }
        }
        if stop.load(Ordering::Relaxed) {
            return;
        }
        thread::sleep(Duration::from_millis(250));
    }
}
