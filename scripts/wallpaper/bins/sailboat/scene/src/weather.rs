//! Live weather: the cached `key=value` file written by fetch_weather.sh, the
//! fetcher run as a detached child at most every few minutes, and the preview
//! overrides (SAILBOAT_* env vars or the shot tool's flags).
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};

const FETCH_SCRIPT: &str = include_str!("fetch_weather.sh");
/// Fetch again once the cache is this old (s).
const REFRESH: f64 = 600.0;
/// After a failed fetch, wait this long before the next try (s).
const RETRY: f64 = 120.0;
/// Data older than this counts as no data (calm defaults) (s).
const STALE: f64 = 6.0 * 3600.0;
/// How often the cache file is stat()ed (s).
const CHECK: f64 = 30.0;

/// What the scene takes from the weather. Units: knots, degrees (the
/// direction the wind/waves come FROM, clockwise from north), 0..1 fractions,
/// mm/h, metres, seconds.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Weather {
    pub wind_kt: f64,
    pub gust_kt: f64,
    pub wind_from: f64,
    pub cloud_low: f64,
    pub cloud_high: f64,
    pub cloud_total: f64,
    pub rain_mm: f64,
    pub code: u32,
    pub visibility_m: f64,
    pub wave_m: f64,
    pub wave_from: f64,
    pub wave_period: f64,
    pub swell_m: f64,
    pub swell_from: f64,
    pub swell_period: f64,
}

impl Weather {
    /// A light sea breeze under a few fair-weather clouds: what's shown with
    /// no data.
    pub const CALM: Weather = Weather {
        wind_kt: 6.0,
        gust_kt: 8.0,
        wind_from: 110.0,
        cloud_low: 0.3,
        cloud_high: 0.15,
        cloud_total: 0.35,
        rain_mm: 0.0,
        code: 1,
        visibility_m: 25_000.0,
        wave_m: 0.5,
        wave_from: 100.0,
        wave_period: 6.0,
        swell_m: 0.3,
        swell_from: 90.0,
        swell_period: 9.0,
    };

    pub fn thunder(&self) -> bool {
        matches!(self.code, 95..=99)
    }
}

/// Preview overrides; `None` = live value.
#[derive(Clone, Debug, Default)]
pub struct Overrides {
    /// Unix seconds for the sky (sun, moon, stars).
    pub time: Option<f64>,
    pub wind_kt: Option<f64>,
    pub gust_kt: Option<f64>,
    pub wind_from: Option<f64>,
    pub cloud: Option<f64>,
    pub rain_mm: Option<f64>,
    pub storm: Option<bool>,
    pub wave_m: Option<f64>,
    pub offline: bool,
}

impl Overrides {
    /// SAILBOAT_TIME (HH:MM local, or unix seconds), SAILBOAT_DATE
    /// (YYYY-MM-DD, local), SAILBOAT_WIND, SAILBOAT_GUST, SAILBOAT_WIND_DIR,
    /// SAILBOAT_CLOUD (0-100), SAILBOAT_RAIN (mm/h), SAILBOAT_STORM (1/0),
    /// SAILBOAT_WAVE (m), SAILBOAT_OFFLINE=1.
    pub fn from_env() -> Self {
        let var = |k: &str| std::env::var(k).ok().filter(|v| !v.trim().is_empty());
        let num = |k: &str| var(k).and_then(|v| v.trim().parse::<f64>().ok());
        let mut o = Overrides {
            wind_kt: num("SAILBOAT_WIND"),
            gust_kt: num("SAILBOAT_GUST"),
            wind_from: num("SAILBOAT_WIND_DIR"),
            cloud: num("SAILBOAT_CLOUD").map(|c| c / 100.0),
            rain_mm: num("SAILBOAT_RAIN"),
            storm: var("SAILBOAT_STORM").map(|v| v != "0"),
            wave_m: num("SAILBOAT_WAVE"),
            offline: var("SAILBOAT_OFFLINE").is_some_and(|v| v != "0"),
            time: None,
        };
        o.time = parse_time(var("SAILBOAT_TIME").as_deref(), var("SAILBOAT_DATE").as_deref());
        o
    }

    /// Nothing forced: the live sky and weather (the only state worth sharing).
    pub fn is_live(&self) -> bool {
        self.time.is_none()
            && self.wind_kt.is_none()
            && self.gust_kt.is_none()
            && self.wind_from.is_none()
            && self.cloud.is_none()
            && self.rain_mm.is_none()
            && self.storm.is_none()
            && self.wave_m.is_none()
            && !self.offline
    }

    /// Fills in what a forced state implies, so `--storm` alone looks like a
    /// storm (wind, cloud, rain, sea) and `--wind 30` brings its sea.
    pub fn apply(&self, w: &mut Weather) {
        if let Some(s) = self.storm {
            if s {
                w.code = 95;
                w.wind_kt = w.wind_kt.max(26.0);
                w.gust_kt = w.gust_kt.max(42.0);
                w.cloud_low = w.cloud_low.max(0.95);
                w.cloud_total = w.cloud_total.max(0.98);
                w.cloud_high = w.cloud_high.max(0.6);
                w.rain_mm = w.rain_mm.max(8.0);
                w.visibility_m = w.visibility_m.min(4000.0);
                w.wave_m = w.wave_m.max(2.8);
                w.swell_m = w.swell_m.max(1.4);
            } else if w.thunder() {
                w.code = 3;
            }
        }
        if let Some(v) = self.wind_kt {
            w.wind_kt = v;
            w.gust_kt = self.gust_kt.unwrap_or(v * 1.3);
            if self.wave_m.is_none() {
                // About a fully developed sea for that wind, capped.
                let ms = v * 0.514;
                w.wave_m = (0.0246 * ms * ms).clamp(0.08, 5.0);
                w.swell_m = (w.wave_m * 0.4).min(1.5);
            }
        }
        if let Some(v) = self.gust_kt {
            w.gust_kt = v;
        }
        if let Some(v) = self.wind_from {
            w.wind_from = v;
            w.wave_from = v;
        }
        if let Some(c) = self.cloud {
            w.cloud_low = c;
            w.cloud_total = c;
            w.cloud_high = (c * 0.7).min(1.0);
        }
        if let Some(r) = self.rain_mm {
            w.rain_mm = r;
            if r > 0.0 {
                w.visibility_m = w.visibility_m.min(20_000.0 / (1.0 + r));
            }
        }
        if let Some(v) = self.wave_m {
            w.wave_m = v;
            w.swell_m = (v * 0.5).min(2.0);
        }
    }
}

/// "21:30" (local, today or SAILBOAT_DATE) or plain unix seconds.
pub fn parse_time(time: Option<&str>, date: Option<&str>) -> Option<f64> {
    let now = crate::unix_secs(std::time::SystemTime::now());
    let date = date.and_then(|d| {
        let mut it = d.trim().split('-').map(|p| p.parse::<i64>().ok());
        Some((it.next()??, it.next()??, it.next()??))
    });
    match time {
        Some(t) if t.contains(':') => {
            let mut it = t.trim().split(':').map(|p| p.parse::<f64>().ok());
            let h = it.next()??;
            let m = it.next().flatten().unwrap_or(0.0);
            let (y, mo, d) = date.unwrap_or_else(|| crate::astro::eastern_date(now));
            Some(crate::astro::eastern_to_unix(y, mo, d, h * 3600.0 + m * 60.0))
        }
        Some(t) => t.trim().parse().ok(),
        None => {
            // A date alone keeps the current local time of day.
            let (y, mo, d) = date?;
            let off = crate::astro::eastern_offset_hours(now) * 3600.0;
            let sod = (now + off).rem_euclid(86_400.0);
            Some(crate::astro::eastern_to_unix(y, mo, d, sod))
        }
    }
}

pub struct Feed {
    path: PathBuf,
    lat: f64,
    lon: f64,
    marine: (f64, f64),
    child: Option<Child>,
    last_check: f64,
    last_spawn: f64,
    mtime: Option<std::time::SystemTime>,
    pub live: Option<(Weather, f64)>,
    offline: bool,
}

impl Feed {
    pub fn new(lat: f64, lon: f64, marine: (f64, f64), offline: bool) -> Self {
        let base = std::env::var_os("XDG_CACHE_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".cache")))
            .unwrap_or_else(|| PathBuf::from("/tmp"));
        let path = std::env::var_os("SAILBOAT_WEATHER_FILE")
            .map(PathBuf::from)
            .unwrap_or_else(|| base.join("sailboat").join("weather.env"));
        let mut feed = Feed {
            path,
            lat,
            lon,
            marine,
            child: None,
            last_check: f64::NEG_INFINITY,
            last_spawn: f64::NEG_INFINITY,
            mtime: None,
            live: None,
            offline,
        };
        feed.read();
        feed
    }

    /// The live weather if fresh, else calm defaults.
    pub fn current(&self, now: f64) -> Weather {
        match self.live {
            Some((w, at)) if now - at < STALE => w,
            _ => Weather::CALM,
        }
    }

    /// Cheap unless due: reaps a finished fetch, re-reads the cache when it
    /// changed, and starts a fetch when it's old.
    pub fn poll(&mut self, now: f64) {
        if let Some(child) = &mut self.child {
            if !matches!(child.try_wait(), Ok(None)) {
                self.child = None;
                self.last_check = f64::NEG_INFINITY;
            }
        }
        if now - self.last_check < CHECK {
            return;
        }
        self.last_check = now;
        self.read();
        if self.offline || self.child.is_some() {
            return;
        }
        let age = self.live.map_or(f64::INFINITY, |(_, at)| now - at);
        if age >= REFRESH && now - self.last_spawn >= RETRY {
            self.last_spawn = now;
            let fmt = |v: f64| format!("{v:.4}");
            self.child = Command::new("sh")
                .arg("-c")
                .arg(FETCH_SCRIPT)
                .arg("sailboat-weather")
                .arg(fmt(self.lat))
                .arg(fmt(self.lon))
                .arg(&self.path)
                .arg(fmt(self.marine.0))
                .arg(fmt(self.marine.1))
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .map_err(|e| eprintln!("sailboat: weather fetch failed to start: {e}"))
                .ok();
        }
    }

    fn read(&mut self) {
        let Ok(meta) = std::fs::metadata(&self.path) else { return };
        let mtime = meta.modified().ok();
        if mtime.is_some() && mtime == self.mtime {
            return;
        }
        self.mtime = mtime;
        let Ok(text) = std::fs::read_to_string(&self.path) else { return };
        if let Some(parsed) = parse(&text) {
            self.live = Some(parsed);
        }
    }
}

fn parse(text: &str) -> Option<(Weather, f64)> {
    let mut w = Weather::CALM;
    let mut fetched = None;
    let mut have_wind = false;
    let mut wave_seen = false;
    for line in text.lines() {
        let Some((k, v)) = line.split_once('=') else { continue };
        let Ok(v) = v.trim().parse::<f64>() else { continue };
        match k.trim() {
            "wind_speed_10m" => {
                w.wind_kt = v;
                have_wind = true;
            }
            "wind_gusts_10m" => w.gust_kt = v,
            "wind_direction_10m" => w.wind_from = v,
            "cloud_cover" => w.cloud_total = v / 100.0,
            "cloud_cover_low" => w.cloud_low = v / 100.0,
            "cloud_cover_high" => w.cloud_high = v / 100.0,
            "precipitation" => w.rain_mm = v,
            "weather_code" => w.code = v.max(0.0) as u32,
            "visibility" => w.visibility_m = v,
            "marine_wave_height" => {
                w.wave_m = v;
                wave_seen = true;
            }
            "marine_wave_direction" => w.wave_from = v,
            "marine_wave_period" => w.wave_period = v,
            "marine_swell_wave_height" => w.swell_m = v,
            "marine_swell_wave_direction" => w.swell_from = v,
            "marine_swell_wave_period" => w.swell_period = v,
            "fetched" => fetched = Some(v),
            _ => {}
        }
    }
    if !have_wind {
        return None;
    }
    if !wave_seen {
        let ms = w.wind_kt * 0.514;
        w.wave_m = (0.0246 * ms * ms).clamp(0.1, 4.0);
        w.wave_from = w.wind_from;
    }
    // Mid clouds read as low here: the scene only has a cumulus deck and cirrus.
    w.cloud_low = w.cloud_low.max(w.cloud_total - w.cloud_high * 0.5).clamp(0.0, 1.0);
    w.gust_kt = w.gust_kt.max(w.wind_kt);
    Some((w, fetched?))
}
