#!/usr/bin/env python3
# Music spectrum feed for the Quickshell bar visualizer (quickshell/MusicLevels.qml).
# Records the default sink monitor with pw-record (16 kHz mono) and prints one line
# of N space-separated levels (0..1, log-spaced bands 60 Hz - 7 kHz) every 50 ms.
# Several band counts ("6,32") print one group per count on the same line, " | "-separated
# (the bar's small visualizer and the dashboard music tab share one capture).
# Stand-in for cava (not installed). pw-record dies with this process (PDEATHSIG).
import ctypes, os, signal, subprocess, sys
import numpy as np

COUNTS = [int(n) for n in (sys.argv[1] if len(sys.argv) > 1 else "6").split(",")]
RATE, HOP, WIN = 16000, 800, 1024  # 20 updates/s: redraw cost in quickshell scales with this

def die_with_parent():
    ctypes.CDLL("libc.so.6").prctl(1, signal.SIGKILL)  # PR_SET_PDEATHSIG

rec = subprocess.Popen(["pw-record", "-P", "{ stream.capture.sink = true node.name = qs-music-levels }",
                        "--format", "s16", "--rate", str(RATE), "--channels", "1", "--latency", "50ms", "-"],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, preexec_fn=die_with_parent)
signal.signal(signal.SIGTERM, lambda *a: (rec.kill(), os._exit(0)))

freqs = np.fft.rfftfreq(WIN, 1 / RATE)


class Bands:
    def __init__(self, n):
        # Many bands start higher: below ~110 Hz they get narrower than an FFT bin (15.6 Hz)
        # and neighbouring bars would just repeat each other.
        edges = np.geomspace(60 if n <= 8 else 110, 7000, n + 1)
        self.bands = []
        for lo, hi in zip(edges[:-1], edges[1:]):
            a = int(np.searchsorted(freqs, lo))
            self.bands.append((a, max(int(np.searchsorted(freqs, hi)), a + 1)))
        self.tilt = np.sqrt(np.arange(1, n + 1))  # lift the treble bands a bit
        self.lvl = np.zeros(n)
        self.peak = 1e-3

    def step(self, mag):
        e = np.array([mag[a:b].mean() for a, b in self.bands]) * self.tilt
        self.peak = max(self.peak * 0.998, e.max(), 1e-3)  # slow auto-gain so quiet tracks still move
        v = np.clip(e / self.peak, 0, 1) ** 0.6
        self.lvl = np.where(v > self.lvl, v, self.lvl * 0.6 + v * 0.4)  # fast attack, soft decay
        return " ".join("%.2f" % x for x in self.lvl)


groups = [Bands(n) for n in COUNTS]
window = np.hanning(WIN).astype(np.float32)
buf = np.zeros(WIN, np.float32)
try:
    while True:
        d = rec.stdout.read(HOP * 2)
        if len(d) < HOP * 2:
            break
        buf = np.roll(buf, -HOP)
        buf[-HOP:] = np.frombuffer(d, "<i2") / 32768.0
        # silence gate (below -80 dBFS): the auto-gain would otherwise blow the noise floor up into bars
        if np.abs(buf).max() < 1e-4:
            mag = np.zeros(len(freqs))
        else:
            mag = np.abs(np.fft.rfft(buf * window))
        sys.stdout.write(" | ".join(g.step(mag) for g in groups) + "\n")
        sys.stdout.flush()
except (BrokenPipeError, KeyboardInterrupt):
    pass
finally:
    rec.kill()
