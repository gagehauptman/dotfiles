//! Shared simulation state. Every process that draws the scene (the wallpaper
//! renderer, the lock screen's own instance, the selector card) writes its
//! animation state here about once a second and adopts the newest copy when it
//! starts or resumes after a pause, so the waves, clouds, gusts and boat line up
//! with the wallpaper instead of each process counting from its own start. The
//! weather itself is already shared (see weather.rs); this is the part that
//! used to differ between processes: the integrated wave/cloud/ripple phases.
use std::path::PathBuf;

const MAGIC: &str = "sailboat-sync 1";
/// State older than this isn't adopted (s): catching up costs a step per 5 s.
pub const MAX_AGE: f64 = 300.0;
/// How often the state is written (s).
pub const WRITE_EVERY: f64 = 1.0;

/// `SAILBOAT_STATE_FILE`, else `$XDG_RUNTIME_DIR/sailboat/sim.state` (tmpfs).
/// `SAILBOAT_NO_SYNC=1` turns sharing off.
pub fn path() -> Option<PathBuf> {
    if std::env::var("SAILBOAT_NO_SYNC").is_ok_and(|v| !v.is_empty() && v != "0") {
        return None;
    }
    if let Some(p) = std::env::var_os("SAILBOAT_STATE_FILE") {
        return Some(PathBuf::from(p));
    }
    std::env::var_os("XDG_RUNTIME_DIR").map(|d| PathBuf::from(d).join("sailboat").join("sim.state"))
}

/// Atomic write (temp file + rename); failures are ignored, sharing is best effort.
pub fn write(path: &PathBuf, at: f64, vals: &[f64]) {
    use std::fmt::Write;
    let mut s = format!("{MAGIC} {at} {}\n", std::process::id());
    for v in vals {
        let _ = write!(s, "{v} ");
    }
    s.push('\n');
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let tmp = path.with_extension(format!("tmp.{}", std::process::id()));
    if std::fs::write(&tmp, s).is_ok() && std::fs::rename(&tmp, path).is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
}

/// `(unix seconds it describes, values)` if the file is there and well formed.
pub fn read(path: &PathBuf) -> Option<(f64, Vec<f64>)> {
    let text = std::fs::read_to_string(path).ok()?;
    let mut lines = text.lines();
    let head = lines.next()?.strip_prefix(MAGIC)?;
    let at: f64 = head.split_whitespace().next()?.parse().ok()?;
    let vals: Option<Vec<f64>> = lines.next()?.split_whitespace().map(|v| v.parse().ok()).collect();
    Some((at, vals?))
}
