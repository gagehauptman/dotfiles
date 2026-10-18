//! A scene that starts late adopts the running one's state and then stays in
//! step with it (waves, clouds, boat), instead of counting from its own start.
use sailboat_scene::{unix_secs, World};
use std::time::SystemTime;

#[test]
fn late_starter_matches_the_running_scene() {
    let dir = std::env::temp_dir().join(format!("sailboat-sync-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let base = unix_secs(SystemTime::now());
    std::fs::write(
        dir.join("weather.env"),
        format!("wind_speed_10m=14.4\nwind_gusts_10m=22.9\nwind_direction_10m=34\ncloud_cover=69\ncloud_cover_low=69\nweather_code=2\nvisibility=28100\nmarine_wave_height=2.0\nmarine_wave_direction=40\nmarine_wave_period=7.05\nmarine_swell_wave_height=0.7\nmarine_swell_wave_direction=48\nmarine_swell_wave_period=9.6\nfetched={base}\n"),
    )
    .unwrap();
    std::env::set_var("SAILBOAT_WEATHER_FILE", dir.join("weather.env"));
    std::env::set_var("SAILBOAT_STATE_FILE", dir.join("sim.state"));

    let mut a = World::new();
    let dt = 1.0 / 30.0;
    let mut t = base;
    for _ in 0..(30 * 60) {
        a.update(t);
        t += dt;
    }
    // B starts 0.37 s after A's last write, at a moment A also reaches.
    let mut b = World::new();
    b.update(t);
    a.update(t);
    let (ga, gb) = (a.globals(2560, 1440), b.globals(2560, 1440));
    for i in 0..2 {
        for j in 0..4 {
            assert!((ga.phase[i][j] - gb.phase[i][j]).abs() < 0.05, "wave phase {i}{j}: {} vs {}", ga.phase[i][j], gb.phase[i][j]);
        }
    }
    for j in 0..4 {
        assert!((ga.cloud_off[j] - gb.cloud_off[j]).abs() < 0.01, "cloud {j}: {} vs {}", ga.cloud_off[j], gb.cloud_off[j]);
    }
    // And they stay together.
    for _ in 0..(30 * 30) {
        t += dt;
        a.update(t);
        b.update(t);
    }
    let (ga, gb) = (a.globals(2560, 1440), b.globals(2560, 1440));
    assert!((ga.phase[0][0] - gb.phase[0][0]).abs() < 0.05);
    assert!((ga.res[2] - gb.res[2]).abs() < 0.01);
    let _ = std::fs::remove_dir_all(&dir);
}
