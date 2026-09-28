#!/usr/bin/env python3
"""Local data service for the Bevy globe dashboard widget (bevy/apps/globe).

Everything the widget shows comes through here, so it only ever talks to
127.0.0.1 and nothing in QML or Rust holds a credential. The service fetches
and caches:

  weather   the global layer is NOAA's GMGSI, NESDIS's hourly mosaic of every
            geostationary infrared imager (8 km, open data on AWS, read with
            h5dump from the hdf5 package); the inset around home is the
            10-minute imagery of the satellites that see it (GOES and Himawari
            via NASA GIBS, Meteosat via EUMETView), blended by viewing angle
  lp        artificial sky brightness from David Lorenz's light pollution atlas
  aircraft  a global OpenSky snapshot (dead-reckoned between polls) merged with
            the live adsb.lol feed around home

and serves them as equirectangular textures the globe samples by lat/lon,
plus JSON. Endpoints (127.0.0.1:38471):

  GET /health
  GET /geo.json?location=&label=     home position (IP geolocation unless given)
  GET /weather.json                  {"frames": [unix times, hourly], "latest": t}
  GET /weather/{t}.png               cloud layer for frame t: 4096x2048 equirectangular
                                     LA PNG, L = cloud-top coldness index, A = coverage
  GET /weather/{t}/inset.png?z=&x0=&y0=&n=
                                     the same for an n x n tile Mercator window (z <= 6)
  GET /weather/lut.png               256x1 RGBA palette for the coldness index
  GET /lp.png                        light pollution zone index (0-14), 8192x4096 L PNG
  GET /lp/inset.png?z=&x0=&y0=&n=    the same for a Mercator window (z <= 8)
  GET /lp/lut.png?pal=&tint=         256x1 RGBA palette for the zones, in the given
                                     eight hex colours and tint
  GET /adsb.json                     {"rows": [[hex, flight, lat, lon, track, alt_ft, gs_kt]...], "ts", "total"}
  GET /aircraft/{hex}.json           one aircraft: state, type, reg, "route" (origin,
                                     destination, airline from adsbdb.com) and "trail"
                                     (OpenSky's track of the flight plus positions seen here)
  GET /vectors.bin                   coastlines and borders at two scales plus
                                     country, region and place labels (Natural
                                     Earth, public domain), see vectors_build()
  GET /tle.json?groups=stations,visual,weather,gnss&catnr=25544&names=HUBBLE
                                     two-line elements from CelesTrak for those
                                     groups (also starlink, science), single
                                     objects by NORAD number and name searches;
                                     12 h cache

Caches live in ~/.cache/quickshell/globe. An OpenSky client id/secret in
~/.config/quickshell/secrets.env (OPENSKY_CLIENT_ID / OPENSKY_CLIENT_SECRET)
raises the global refresh from every 15 minutes to every minute.
Prints "ready" on stdout once it accepts requests (DashboardConfig waits for
that); exits when the shell that started it is gone.
"""
import concurrent.futures
import http.client
import http.server
import io
import json
import math
import os
import queue
import calendar
import re
import shutil
import signal
import struct
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mapkit  # noqa: E402

PORT = 38471
CACHE = os.path.expanduser("~/.cache/quickshell/globe")
mapkit.CACHE = CACHE
UA = "quickshell-globe/1.0"
EQ_W, EQ_H = 4096, 2048      # global weather texture (equirectangular)
LP_W, LP_H = 8192, 4096      # global light pollution texture (from Mercator zoom 6)
LP_GLOBAL_Z = 6
INSET_MAX_N = 16             # inset windows: up to 16 x 16 tiles, Mercator, at the source's best zoom

def log(msg):
    print(msg, file=sys.stderr, flush=True)


_local = threading.local()


GIBS = "gibs.earthdata.nasa.gov"


GIBS_BASE = "/wmts/epsg3857/best"


EUMET = "view.eumetsat.int"


EUMET_WMS = "/geoserver/wms"


SATS = [  # (kind, layer, sub-satellite longitude)
    ("gibs", "GOES-West_ABI_Band13_Clean_Infrared", -137.2),
    ("gibs", "GOES-East_ABI_Band13_Clean_Infrared", -75.2),
    ("gibs", "Himawari_AHI_Band13_Clean_Infrared", 140.7),
    ("wms", "mtg_fd:ir105_hrfi", 0.0),
    ("wms", "msg_iodc:ir108", 45.5),
]


WX_MAX_Z = 6


WX_FRAMES = 12


STEP_S = 600


TILE_PX = 256


_wx = {"ts": 0, "latest": {}, "times": []}


_wx_lock = threading.Lock()


CLOUD_WHITE = (205, 214, 244)


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def gibs_get(path):
    """(status, bytes). 200 with the tile, 404 where GIBS has nothing, or the
    last status (0 for a connection failure) after three attempts; a busy
    server is retried with a short pause."""
    status = 0
    for attempt in range(3):
        try:
            c = getattr(_local, "gibs", None)
            if c is None:
                c = http.client.HTTPSConnection(GIBS, timeout=30)
                _local.gibs = c
            c.request("GET", path, headers={"User-Agent": UA})
            r = c.getresponse()
            data = r.read()
            status = r.status
            if status == 200:
                return status, data
            if status == 404:
                return status, b""
        except (http.client.HTTPException, OSError):
            _local.gibs = None
            status = 0
        time.sleep(0.5 * (attempt + 1))
    return status, b""


def eumet_get(path):
    for attempt in range(2):
        try:
            c = getattr(_local, "eumet", None)
            if c is None:
                c = http.client.HTTPSConnection(EUMET, timeout=30)
                _local.eumet = c
            c.request("GET", path, headers={"User-Agent": UA})
            r = c.getresponse()
            data = r.read()
            return data if r.status == 200 else b""
        except (http.client.HTTPException, OSError):
            _local.eumet = None
    return b""


_cadence = {}


def wx_refresh():
    """Latest available time per satellite: GIBS and EUMETView capabilities."""
    import calendar
    import re
    latest = {}
    _, doc = gibs_get(f"{GIBS_BASE}/wmts.cgi?SERVICE=WMTS&REQUEST=GetCapabilities")
    doc = doc.decode(errors="replace")
    for kind, layer, _ in SATS:
        if kind != "gibs":
            continue
        m = re.search(r"<ows:Identifier>" + re.escape(layer) + r"</ows:Identifier>.*?<Default>([^<]+)</Default>", doc, re.S)
        if m:
            latest[layer] = calendar.timegm(time.strptime(m.group(1), "%Y-%m-%dT%H:%M:%SZ"))
    try:
        doc = eumet_get(f"{EUMET_WMS}?service=WMS&version=1.3.0&request=GetCapabilities").decode(errors="replace")
        for kind, layer, _ in SATS:
            if kind != "wms":
                continue
            m = re.search(r"<Name>" + re.escape(layer) + r"</Name>.*?<Dimension[^>]*name=\"time\"[^>]*>([^<]*)</Dimension>", doc, re.S)
            if not m:
                continue
            ext = m.group(1).strip().split(",")[-1].split("/")   # start/end/period
            if len(ext) == 3:
                latest[layer] = calendar.timegm(time.strptime(ext[1][:19], "%Y-%m-%dT%H:%M:%S"))
                pm = re.match(r"PT(?:(\d+)H)?(?:(\d+)M)?", ext[2])
                _cadence[layer] = (int(pm.group(1) or 0) * 3600 + int(pm.group(2) or 0) * 60) or 900
    except Exception as e:  # noqa: BLE001
        log(f"eumetview capabilities: {e}")
    if not latest:
        raise RuntimeError("no satellite layers available")
    common = min(latest.values()) // STEP_S * STEP_S
    times = [common - k * STEP_S for k in range(WX_FRAMES - 1, -1, -1)]
    with _wx_lock:
        _wx.update(ts=time.time(), latest=latest, times=times)


def tile_bbox_3857(z, x, y):
    n = 2 ** z
    half = 20037508.342789244
    size = 2 * half / n
    return (-half + x * size, half - (y + 1) * size, -half + (x + 1) * size, half - y * size)


def sat_image(kind, layer, tt, z, x, y):
    """Raw imagery for one satellite over one tile: RGBA array or None."""
    if kind == "gibs":
        _, data = gibs_get(f"{GIBS_BASE}/{layer}/default/{iso(tt)}/GoogleMapsCompatible_Level{WX_MAX_Z}/{z}/{y}/{x}.png")
    else:
        step = _cadence.get(layer, 900)
        tt = tt // step * step
        minx, miny, maxx, maxy = tile_bbox_3857(z, x, y)
        data = eumet_get(f"{EUMET_WMS}?service=WMS&version=1.3.0&request=GetMap&layers={layer}&styles=&crs=EPSG:3857"
                         f"&bbox={minx},{miny},{maxx},{maxy}&width={TILE_PX}&height={TILE_PX}&format=image/png&transparent=true"
                         f"&time={iso(tt)[:-1]}.000Z")
    if not data:
        return None
    try:
        return np.asarray(Image.open(io.BytesIO(data)).convert("RGBA"))
    except Exception:  # noqa: BLE001
        return None


def wx_times():
    """(times, latest-per-satellite); refreshes every 10 min, in the background once warm."""
    with _wx_lock:
        stale = time.time() - _wx["ts"] > 600
        have = bool(_wx["times"])
    if stale:
        if have:
            threading.Thread(target=wx_refresh, daemon=True).start()
        else:
            wx_refresh()
    with _wx_lock:
        return list(_wx["times"]), dict(_wx["latest"])


def tile_lon_range(z, x):
    n = 2 ** z
    return x / n * 360 - 180, (x + 1) / n * 360 - 180


def lon_overlap(lo, hi, centre, half):
    for shift in (-360, 0, 360):
        if lo < centre + shift + half and hi > centre + shift - half:
            return True
    return False


def ir_index(arr, kind="gibs"):
    """Decode an IR tile to a cloud-top coldness index in [0, 1] (0 warm
    surface … 1 coldest tops) plus a data mask. GIBS colour enhancement: grey
    levels map to 0–0.6 by luminance, enhancement colours to bands above.
    EUMETView grayscale: luminance mapped onto the same scale."""
    rgb = arr[..., :3].astype(np.float32) / 255.0
    mask = arr[..., 3].astype(np.float32) / 255.0
    if kind == "wms":
        # EUMETView grayscale sits darker than the GIBS greys (surface ~0.1,
        # thick cloud ~0.6, coldest tops ~0.85); stretch it onto the GIBS
        # scale, where 0.6 marks the first enhancement band.
        lum = 0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2]
        g = np.clip((lum - 0.08) / 0.62, 0, 1)        # 0.08…0.70 -> 0…1 (grey range)
        idx = np.where(lum <= 0.70, g * 0.6, 0.6 + np.clip((lum - 0.70) / 0.2, 0, 1) * 0.4)
        return idx.astype(np.float32), mask
    mx = rgb.max(-1)
    mn = rgb.min(-1)
    satn = (mx - mn) / (mx + 1e-6)
    lum = 0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2]
    d = (mx - mn) + 1e-6
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    hue = np.where(mx == r, (g - b) / d % 6, np.where(mx == g, (b - r) / d + 2, (r - g) / d + 4)) * 60.0
    idx = lum * 0.6
    enh = satn >= 0.25
    idx = np.where(enh & (hue >= 180) & (hue < 270), 0.66, idx)   # blue / cyan
    idx = np.where(enh & (hue >= 70) & (hue < 180), 0.78, idx)    # green
    idx = np.where(enh & (hue >= 35) & (hue < 70), 0.88, idx)     # yellow
    idx = np.where(enh & ((hue < 35) | (hue >= 270)), 0.97, idx)  # red / magenta
    return idx.astype(np.float32), mask


def colorize(idx, cover):
    """Coldness index -> themed cloud overlay (RGBA uint8). Grey cloud is
    translucent white; cold tops step through blue, green, yellow, red."""
    out = np.zeros(idx.shape + (4,), dtype=np.float32)
    out[..., 0], out[..., 1], out[..., 2] = CLOUD_WHITE
    out[..., 3] = np.clip((idx - 0.33) / 0.2, 0, 1) * 0.65
    for lo, hi, col in ((0.6, 0.72, (137, 180, 250)), (0.72, 0.84, (166, 227, 161)),
                        (0.84, 0.93, (249, 226, 175)), (0.93, 1.01, (243, 139, 168))):
        sel = (idx >= lo) & (idx < hi)
        out[sel, 0], out[sel, 1], out[sel, 2] = col
        out[sel, 3] = 0.9
    out[..., 3] *= cover
    return (out * np.array([1, 1, 1, 255], dtype=np.float32)).astype(np.uint8)


def write_atomic(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.{threading.get_ident()}.tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)


_fetch_pool = concurrent.futures.ThreadPoolExecutor(max_workers=16)


def wx_purge():
    """Drop cached weather tiles older than 4 h."""
    import shutil
    now = time.time()
    for kind in ("raw",):
        d = os.path.join(CACHE, "wx", kind)
        if not os.path.isdir(d):
            continue
        for layer in os.listdir(d):
            ld = os.path.join(d, layer)
            for name in os.listdir(ld) if os.path.isdir(ld) else []:
                p = os.path.join(ld, name)
                try:
                    if now - os.stat(p).st_mtime > 4 * 3600:
                        shutil.rmtree(p, ignore_errors=True)
                except OSError:
                    pass


_comp_locks = {}


_comp_locks_guard = threading.Lock()


def comp_lock(key):
    with _comp_locks_guard:
        return _comp_locks.setdefault(key, threading.Lock())


def window_lonlat(z, x0, y0, n):
    """Per-pixel longitude (row vector) and latitude (column vector) of a window."""
    N = 2 ** z
    size = n * TILE_PX
    px = (np.arange(size, dtype=np.float32) + 0.5) / TILE_PX
    lon = ((x0 + px) / N) * 360.0 - 180.0
    lat = np.degrees(np.arctan(np.sinh(np.pi * (1 - 2 * (y0 + px) / N))))
    return lon, lat


def zenith_weight_ll(lat, lon, centre):
    """cos²(satellite zenith angle) over a lat (column) × lon (row) grid."""
    cosd = np.cos(np.radians(lat))[:, None] * np.cos(np.radians(lon - centre))[None, :]
    rho = 6371.0 / 42164.0
    cosz = (cosd - rho) / np.sqrt(1 + rho * rho - 2 * rho * cosd)
    return np.clip(cosz, 0, 1).astype(np.float32) ** 2


def gibs_tile_raw(layer, tt, z, x, y):
    """Raw GIBS tile bytes, disk-cached (b"" where the satellite has nothing)."""
    path = os.path.join(CACHE, "wx", "raw", layer, str(tt), str(z), str(x), f"{y}.png")
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError:
        pass
    status, data = gibs_get(f"{GIBS_BASE}/{layer}/default/{iso(tt)}/GoogleMapsCompatible_Level{WX_MAX_Z}/{z}/{y}/{x}.png")
    if status in (200, 404):
        write_atomic(path, data)  # a 404 is remembered as empty; a failed fetch is retried next build
    return data


def gibs_window(layer, tt, z, x0, y0, n):
    N = 2 ** z
    size = n * TILE_PX
    cells = [(i, j) for j in range(n) for i in range(n) if 0 <= y0 + j < N]
    datas = list(_fetch_pool.map(lambda c: gibs_tile_raw(layer, tt, z, (x0 + c[0]) % N, y0 + c[1]), cells))
    arr = np.zeros((size, size, 4), dtype=np.uint8)
    for (i, j), data in zip(cells, datas):
        if not data:
            continue
        try:
            img = Image.open(io.BytesIO(data)).convert("RGBA")
        except Exception:  # noqa: BLE001
            continue
        if img.size != (TILE_PX, TILE_PX):
            img = img.resize((TILE_PX, TILE_PX))
        arr[j * TILE_PX:(j + 1) * TILE_PX, i * TILE_PX:(i + 1) * TILE_PX] = np.asarray(img)
    return arr


def wms_window(layer, tt, z, x0, y0, n):
    """One EUMETView GetMap for the whole window (instead of n² tiles)."""
    N = 2 ** z
    size = n * TILE_PX
    step = _cadence.get(layer, 900)
    tt = tt // step * step
    minx, miny, _, _ = tile_bbox_3857(z, x0 % N, y0 + n - 1)
    _, _, maxx, maxy = tile_bbox_3857(z, x0 % N + n - 1, y0)
    if x0 % N + n > N:   # window crosses the dateline: fall back to per-tile fetches
        arr = np.zeros((size, size, 4), dtype=np.uint8)
        for j in range(n):
            for i in range(n):
                if 0 <= y0 + j < N:
                    t1 = sat_image("wms", layer, tt, z, (x0 + i) % N, y0 + j)
                    if t1 is not None:
                        arr[j * TILE_PX:(j + 1) * TILE_PX, i * TILE_PX:(i + 1) * TILE_PX] = t1
        return arr
    data = eumet_get(f"{EUMET_WMS}?service=WMS&version=1.3.0&request=GetMap&layers={layer}&styles=&crs=EPSG:3857"
                     f"&bbox={minx},{miny},{maxx},{maxy}&width={size}&height={size}&format=image/png&transparent=true"
                     f"&time={iso(tt)[:-1]}.000Z")
    if not data:
        return None
    try:
        return np.asarray(Image.open(io.BytesIO(data)).convert("RGBA"))
    except Exception:  # noqa: BLE001
        return None


def wx_window(key, z, x0, y0, n):
    """Observed weather window as an RGBA array: every satellite that sees it,
    blended per pixel by viewing-zenith weight in index space, colourised once."""
    t = int(key.split("/")[1])
    N = 2 ** z
    size = n * TILE_PX
    _, latest = wx_times()
    lo, hi = tile_lon_range(z, x0 % N)[0], tile_lon_range(z, (x0 % N) + n - 1)[1]
    lon, lat = window_lonlat(z, x0 % N, y0, n)
    num = np.zeros((size, size), dtype=np.float32)
    den = np.zeros((size, size), dtype=np.float32)
    jobs = []
    for kind, layer, centre in SATS:
        if not lon_overlap(lo, hi, centre, 82) or layer not in latest:
            continue
        w = zenith_weight_ll(lat, lon, centre)
        w = np.where(w < 0.15, 0, w)        # drop the smeared limb (zenith > ~67°) entirely
        if w.max() <= 0:
            continue
        tt = min(t, latest[layer])
        jobs.append((kind, layer, w, tt))
    def fetch(job):
        kind, layer, w, tt = job
        return gibs_window(layer, tt, z, x0, y0, n) if kind == "gibs" else wms_window(layer, tt, z, x0, y0, n)
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, len(jobs))) as pool:
        arrs = list(pool.map(fetch, jobs))
    for (kind, layer, w, tt), arr in zip(jobs, arrs):
        if arr is None:
            continue
        idx, mask = ir_index(arr, kind)
        num += w * mask * idx
        den += w * mask
    cover = np.clip((den - 0.05) / 0.1, 0, 1)
    idx = np.where(den > 0.05, num / np.maximum(den, 1e-6), 0)
    return idx.astype(np.float32), cover.astype(np.float32)


def la_png(l, a):
    buf = io.BytesIO()
    Image.fromarray(np.ascontiguousarray(np.dstack([l, a])), "LA").save(buf, format="PNG", compress_level=1)
    return buf.getvalue()


def l_png(l):
    buf = io.BytesIO()
    Image.fromarray(np.ascontiguousarray(l), "L").save(buf, format="PNG", compress_level=1)
    return buf.getvalue()


def lut_png(lut):
    """A (256, 4) uint8 table as a 256 x 1 RGBA PNG."""
    buf = io.BytesIO()
    Image.fromarray(np.ascontiguousarray(lut[None, :, :]), "RGBA").save(buf, format="PNG")
    return buf.getvalue()


LP_YEAR = "2025"


LP_URL = "https://djlorenz.github.io/astronomy/image_tiles/tiles{year}/tile_{z}_{x}_{y}.png"


LP_MAX_Z = 6


LP_NODATA = 255


LP_ZONE_RGB = [(0, 0, 0), (34, 34, 34), (66, 66, 66), (20, 47, 114), (33, 84, 216), (15, 87, 20), (31, 161, 42),
               (110, 100, 30), (184, 166, 37), (191, 100, 30), (253, 150, 80), (251, 90, 73), (251, 153, 138),
               (160, 160, 160), (242, 242, 242)]


LP_ZONE_NAMES = ["0", "1a", "1b", "2a", "2b", "3a", "3b", "4a", "4b", "5a", "5b", "6a", "6b", "7a", "7b"]


LP_DEFAULT_PAL = ["89b4fa", "94e2d5", "a6e3a1", "f9e2af", "fab387", "f38ba8", "f5c2e7", "cdd6f4"]


_lp_tiles = {}


_lp_tiles_lock = threading.Lock()


def lp_tile(z, x, y):
    """One atlas tile as zone indices (uint8, LP_NODATA where the atlas has
    nothing), from disk after the first fetch; None where there is no tile."""
    N = 2 ** z
    if not (0 <= y < N):
        return None
    x %= N
    with _lp_tiles_lock:
        if (z, x, y) in _lp_tiles:
            return _lp_tiles[(z, x, y)]
    path = os.path.join(CACHE, "lp", LP_YEAR, str(z), f"{x}_{y}.png")
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        try:
            data = mapkit.fetch(LP_URL.format(year=LP_YEAR, z=z, x=x, y=y), timeout=20)
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise
            data = b""
        write_atomic(path, data)
    out = None
    if data:
        arr = np.asarray(Image.open(io.BytesIO(data)).convert("RGB"), dtype=np.int16)
        out = np.full(arr.shape[:2], LP_NODATA, dtype=np.uint8)
        for i, (r, g, b) in enumerate(LP_ZONE_RGB):
            out[(np.abs(arr[..., 0] - r) < 6) & (np.abs(arr[..., 1] - g) < 6) & (np.abs(arr[..., 2] - b) < 6)] = i
    with _lp_tiles_lock:
        if len(_lp_tiles) > 48:
            _lp_tiles.clear()
        _lp_tiles[(z, x, y)] = out
    return out


def lp_window(z, x0, y0, n):
    """Zone indices for n×n Web Mercator tiles from (x0, y0) at zoom z."""
    N = 2 ** z
    size = n * TILE_PX
    out = np.full((size, size), LP_NODATA, dtype=np.uint8)
    az = z - 2
    if not (0 <= az <= LP_MAX_Z):
        return out
    cells = [(i, j) for j in range(n) for i in range(n) if 0 <= y0 + j < N]
    keys = sorted({((x0 + i) % N // 4, (y0 + j) // 4) for i, j in cells})
    tiles = dict(zip(keys, _fetch_pool.map(lambda k: lp_tile(az, k[0], k[1]), keys)))
    for i, j in cells:
        X, Y = (x0 + i) % N, y0 + j
        t = tiles.get((X // 4, Y // 4))
        if t is None:
            continue
        sx, sy = (X % 4) * TILE_PX, (Y % 4) * TILE_PX
        out[j * TILE_PX:(j + 1) * TILE_PX, i * TILE_PX:(i + 1) * TILE_PX] = t[sy:sy + TILE_PX, sx:sx + TILE_PX]
    return out


def lp_colorize(zones, pal, tint):
    """Zone indices → themed RGBA. `pal` is eight colours: one hue per zone 1-7
    plus the colour of 7b; sub-zone a is the hue pulled toward the panel tint,
    b the hue itself; alpha rises with the zone and zone 0 stays clear."""
    cols = [tuple(int(h[k:k + 2], 16) for k in (0, 2, 4)) for h in pal]
    bg = tuple(int(tint[k:k + 2], 16) for k in (0, 2, 4))
    alphas = [0, .18, .28, .36, .44, .50, .56, .60, .64, .68, .72, .76, .80, .84, .88]
    lut = np.zeros((256, 4), dtype=np.uint8)
    for idx in range(1, 15):
        zone = (idx + 1) // 2
        c = cols[7] if idx == 14 else cols[zone - 1]
        if idx % 2 == 1:                       # sub-zone a
            c = tuple(int(0.62 * c[k] + 0.38 * bg[k]) for k in range(3))
        lut[idx] = (*c, int(alphas[idx] * 255))
    return lut[zones]


def lp_pal(q):
    pal = q.get("pal", "").split(",")
    ok = len(pal) == 8 and all(len(c) == 6 and all(ch in "0123456789abcdefABCDEF" for ch in c) for c in pal)
    return [c.lower() for c in pal] if ok else LP_DEFAULT_PAL


def alt_band(alt):
    alt = alt or 0
    return 0 if alt < 5000 else 1 if alt < 15000 else 2 if alt < 30000 else 3


OPENSKY_ALL = "https://opensky-network.org/api/states/all"


OPENSKY_TOKEN = "https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token"


_global = {"ac": {}, "ts": 0, "interval": 900, "next": 0}


_global_lock = threading.Lock()


GLOBAL_FILE = os.path.join(CACHE, "opensky.json")


def global_load():
    """Reuse the last snapshot after a restart (every shell reload restarts us):
    it costs OpenSky credits to refetch and dead reckoning covers the gap."""
    try:
        with open(GLOBAL_FILE) as f:
            d = json.load(f)
        if time.time() - d["ts"] < 900:
            with _global_lock:
                _global["ac"] = d["ac"]
                _global["ts"] = d["ts"]
            log(f"opensky: reused snapshot from {round(time.time() - d['ts'])} s ago ({len(d['ac'])} aircraft)")
            return d["ts"]
    except (OSError, ValueError, KeyError):
        pass
    return 0


def load_secrets():
    """Optional ~/.config/quickshell/secrets.env (KEY=value lines) into the environment."""
    path = os.path.expanduser("~/.config/quickshell/secrets.env")
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip('"'))
    except OSError:
        pass


def opensky_token():
    cid, sec = os.environ.get("OPENSKY_CLIENT_ID"), os.environ.get("OPENSKY_CLIENT_SECRET")
    if not cid or not sec:
        return None
    if _osky_auth["token"] and time.time() < _osky_auth["exp"] - 60:
        return _osky_auth["token"]
    body = urllib.parse.urlencode({"grant_type": "client_credentials", "client_id": cid, "client_secret": sec}).encode()
    req = urllib.request.Request(OPENSKY_TOKEN, data=body, headers={"User-Agent": UA, "Content-Type": "application/x-www-form-urlencoded"})
    with urllib.request.urlopen(req, timeout=15) as r:
        d = json.loads(r.read().decode())
    _osky_auth.update(token=d["access_token"], exp=time.time() + int(d.get("expires_in", 1800)))
    return _osky_auth["token"]


def global_poll_once():
    headers = {"User-Agent": UA}
    tok = None
    try:
        tok = opensky_token()
    except Exception as e:  # noqa: BLE001
        log(f"opensky auth: {e}")
    if tok:
        headers["Authorization"] = f"Bearer {tok}"
    req = urllib.request.Request(OPENSKY_ALL, headers=headers)
    with urllib.request.urlopen(req, timeout=60) as r:
        remaining = r.headers.get("X-Rate-Limit-Remaining")
        d = json.loads(r.read().decode())
    now = time.time()
    ac = {}
    for st in d.get("states") or []:
        # [icao24, callsign, country, time_position, last_contact, lon, lat, baro_alt(m), on_ground, velocity(m/s), true_track, ...]
        if st[5] is None or st[6] is None:
            continue
        ac[st[0]] = {
            "hex": st[0], "flight": (st[1] or "").strip(), "type": "", "reg": "",
            "lat": st[6], "lon": st[5], "track": st[10] or 0.0,
            "alt": 0 if st[8] else round((st[7] or 0) * 3.28084),
            "gs": round((st[9] or 0) * 1.94384, 1),
            "seen": float(st[3] or st[4] or now), "src": "opensky",
        }
    with _global_lock:
        _global["ac"] = ac
        _global["ts"] = now
        # Anonymous: 4 credits per call from a 400/day budget → 15 min. Authenticated: 60 s.
        _global["interval"] = 60 if tok else 900
    write_atomic(GLOBAL_FILE, json.dumps({"ts": now, "ac": ac}).encode())
    log(f"opensky: {len(ac)} aircraft ({'auth' if tok else 'anonymous'}; credits left {remaining})")


def global_worker():
    last = global_load()
    if last:
        time.sleep(max(0, 900 - (time.time() - last)) if not (os.environ.get("OPENSKY_CLIENT_ID")) else 0)
    while True:
        try:
            global_poll_once()
        except urllib.error.HTTPError as e:
            log(f"opensky: HTTP {e.code}; retrying in 15 min")
            with _global_lock:
                _global["interval"] = max(_global["interval"], 900)
        except Exception as e:  # noqa: BLE001
            log(f"opensky: {e}")
        with _global_lock:
            wait = _global["interval"]
        time.sleep(wait)


def dead_reckon(a, now):
    """Advance a position along its track by ground speed for the time since it was seen."""
    dt = now - a.get("seen", now)
    if dt <= 0 or dt > 3600 or not a.get("gs"):
        return a
    d_km = a["gs"] * 1.852 * dt / 3600
    br = math.radians(a["track"] or 0)
    lat1, lon1 = math.radians(a["lat"]), math.radians(a["lon"])
    ad = d_km / 6371.0
    lat2 = math.asin(math.sin(lat1) * math.cos(ad) + math.cos(lat1) * math.sin(ad) * math.cos(br))
    lon2 = lon1 + math.atan2(math.sin(br) * math.sin(ad) * math.cos(lat1), math.cos(ad) - math.sin(lat1) * math.sin(lat2))
    b = dict(a)
    b["lat"], b["lon"] = math.degrees(lat2), (math.degrees(lon2) + 540) % 360 - 180
    b["age"] = round(dt)
    return b


def merged_aircraft(now):
    """Regional (fresh, live) entries over the global snapshot."""
    with _global_lock:
        out = dict(_global["ac"])
    with _region_lock:
        for h, a in _region.items():
            if now - a["seen"] <= 180:
                out[h] = dict(a, src="adsb.lol")
    return out


_watch = {}


_watch_order = []


_region = {}


_region_lock = threading.Lock()


_region_wake = threading.Event()


_region_interval = {"s": 30}


def watch_add(name, lat, lon):
    with _region_lock:
        if name in _watch:
            return
        _watch[name] = (lat, lon)
        if name != "home":
            _watch_order.append(name)
            while len(_watch_order) > 3:
                _watch.pop(_watch_order.pop(0), None)
    _region_wake.set()


def region_worker():
    while True:
        try:
            region_poll_once()
        except Exception as e:  # noqa: BLE001
            log(f"region poll: {e}")
        _region_wake.wait(_region_interval["s"])
        _region_wake.clear()


def adsb_trim(raw, limit=None):
    ac = []
    for a in raw.get("ac", []):
        if not isinstance(a.get("lat"), (int, float)) or not isinstance(a.get("lon"), (int, float)):
            continue
        track = a.get("track") if isinstance(a.get("track"), (int, float)) else a.get("true_heading", 0)
        ac.append({
            "hex": a.get("hex", ""), "flight": (a.get("flight") or "").strip(),
            "type": a.get("t", ""), "reg": a.get("r", ""),
            "lat": a["lat"], "lon": a["lon"], "track": track or 0,
            "alt": a.get("alt_baro") if isinstance(a.get("alt_baro"), (int, float)) else 0,
            "gs": a.get("gs", 0) or 0,
        })
        if limit and len(ac) >= limit:
            break
    return ac


_frame_lock = threading.Lock()


_frame = {"id": 0, "ts": 0.0, "ac": []}


FRAME_TTL = 3.0


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def handle_error(self, request, client_address):
        exc = sys.exc_info()[1]
        if isinstance(exc, (BrokenPipeError, ConnectionResetError)):
            return
        super().handle_error(request, client_address)


def watch_parent():
    """Exit when the shell that started us is gone. An orphan is reparented to
    the nearest subreaper (systemd --user in a login session), not always to
    pid 1, so any change of parent counts."""
    parent = os.getppid()
    while True:
        if os.getppid() != parent:
            os._exit(0)
        time.sleep(5)


def stop_others():
    """Newest instance wins: stop any other globeserver of ours, one an earlier
    shell or a QML reload left running (it would hold the port and keep
    polling every feed). Returns how many were signalled."""
    me = os.getpid()
    n = 0
    for d in os.listdir("/proc"):
        if not d.isdigit() or int(d) == me:
            continue
        try:
            if os.stat(f"/proc/{d}").st_uid != os.getuid():
                continue
            with open(f"/proc/{d}/cmdline", "rb") as f:
                argv = f.read().split(b"\0")
        except OSError:
            continue
        if any(a.endswith(b"/globeserver.py") or a == b"globeserver.py" for a in argv[1:3]):
            try:
                os.kill(int(d), signal.SIGTERM)
                n += 1
            except OSError:
                pass
    return n


def healthy():
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/health", timeout=2) as r:
            return r.read() == b"ok"
    except Exception:  # noqa: BLE001
        return False


# ---------------------------------------------------------------- equirectangular outputs
def mercator_world_to_equirect(arr, out_w=EQ_W, out_h=EQ_H):
    """Resample a whole-world Web Mercator raster (zoom 4 window: 4096 px,
    +-85°) onto an equirectangular grid; rows beyond the Mercator extent are
    left as the raster's zero (transparent)."""
    size = arr.shape[0]
    lat = 90.0 - (np.arange(out_h, dtype=np.float64) + 0.5) / out_h * 180.0
    merc = (1.0 - np.log(np.tan(np.radians(lat) / 2 + np.pi / 4)) / np.pi) / 2 * size
    valid = (merc >= 0) & (merc < size)
    rows = np.clip(merc.astype(np.int64), 0, size - 1)
    cols = ((np.arange(out_w, dtype=np.float64) + 0.5) / out_w * size).astype(np.int64)
    out = arr[rows][:, cols].copy()
    out[~valid] = 0
    return out


def cached(path, build):
    """Bytes from `path`, or built once (other threads wait) and stored there."""
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError:
        pass
    with comp_lock(path):
        if os.path.exists(path):
            with open(path, "rb") as f:
                return f.read()
        data = build()
        write_atomic(path, data)
        return data


# ---------------------------------------------------------------- global weather (NOAA GMGSI)
GMGSI = "https://noaa-gmgsi-pds.s3.amazonaws.com"
GMGSI_PRODUCT = "GMGSI_LW"      # long-wave infrared mosaic, hourly, about 40 min behind
GMGSI_FRAMES = 12
GMGSI_LO, GMGSI_HI = 40.0, 255.0  # its 0-255 counts (higher = colder) onto our coldness index
_gmgsi = {"ts": 0.0, "frames": []}
_gmgsi_lock = threading.Lock()


def gmgsi_list():
    """The last hourly composites as [(unix start time, key)], newest last;
    the bucket is listed every 5 minutes and the last list kept on failure."""
    with _gmgsi_lock:
        if time.time() - _gmgsi["ts"] < 300 and _gmgsi["frames"]:
            return list(_gmgsi["frames"])
    frames, now = [], time.time()
    for day in (now - 86400, now):
        prefix = time.strftime(f"{GMGSI_PRODUCT}/%Y/%m/%d/", time.gmtime(day))
        try:
            xml = mapkit.fetch(f"{GMGSI}/?list-type=2&prefix={prefix}&max-keys=200", timeout=30).decode(errors="replace")
        except Exception as e:  # noqa: BLE001
            log(f"gmgsi: list {prefix}: {e}")
            continue
        for key in re.findall(r"<Key>([^<]+)</Key>", xml):
            m = re.search(r"_s(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})", key)
            if m:
                frames.append((calendar.timegm((int(m[1]), int(m[2]), int(m[3]), int(m[4]), int(m[5]), 0)), key))
    frames = sorted(set(frames))[-GMGSI_FRAMES:]
    with _gmgsi_lock:
        if frames:
            _gmgsi.update(ts=time.time(), frames=frames)
        else:
            frames = list(_gmgsi["frames"])
    return frames


def gmgsi_grid(key):
    """(coldness index, coverage) as uint8 on our equirectangular grid from
    one GMGSI file. The file is NetCDF4/HDF5; h5dump extracts the arrays."""
    if not shutil.which("h5dump"):
        raise RuntimeError("h5dump not found: install the hdf5 package for the global weather layer")
    nc = os.path.join(CACHE, "gmgsi", key.rsplit("/", 1)[-1])
    if not os.path.exists(nc):
        write_atomic(nc, mapkit.fetch(f"{GMGSI}/{key}", timeout=180))
    head = subprocess.run(["h5dump", "-H", "-d", "/data", nc], capture_output=True, text=True).stdout
    m = re.search(r"\(\s*1,\s*(\d+),\s*(\d+)\s*\)", head)
    if not m:
        raise RuntimeError("gmgsi: unexpected /data shape")
    rows, cols = int(m[1]), int(m[2])

    def dump(ds):
        out = f"{nc}.{ds.strip('/')}.bin"
        r = subprocess.run(["h5dump", "-d", ds, "-b", "LE", "-o", out, nc], capture_output=True, text=True)
        if r.returncode != 0 or not os.path.exists(out):
            raise RuntimeError(f"h5dump {ds}: {(r.stderr or 'failed').strip()[:160]}")
        return out

    try:
        data = np.fromfile(dump("/data"), dtype="<f4").reshape(rows, cols)
        lat = np.fromfile(dump("/lat"), dtype="<f4").reshape(rows, cols)[:, 0]
    finally:
        for ds in ("data", "lat"):
            try:
                os.remove(f"{nc}.{ds}.bin")
            except OSError:
                pass
    # rows are spaced in Mercator (finer towards the poles): place each output
    # latitude by the file's own latitude column; columns are linear in longitude
    # from -180 (the first column is the wrap at 180)
    out_lat = 90.0 - (np.arange(EQ_H, dtype=np.float64) + 0.5) / EQ_H * 180.0
    ri = np.clip(np.rint(np.interp(out_lat, lat[::-1], np.arange(rows)[::-1])).astype(np.int64), 0, rows - 1)
    in_range = (out_lat <= lat[0]) & (out_lat >= lat[-1])
    out_lon = -180.0 + (np.arange(EQ_W, dtype=np.float64) + 0.5) / EQ_W * 360.0
    ci = ((out_lon + 180.0) / 360.0 * cols).astype(np.int64) % cols
    grid = data[ri][:, ci]
    ok = (grid > -9998) & in_range[:, None]
    idx = np.clip((grid - GMGSI_LO) / (GMGSI_HI - GMGSI_LO), 0.0, 1.0)
    idx8 = (idx * 255 + 0.5).astype(np.uint8)
    idx8[~ok] = 0
    # the mosaic stops short of the poles: fade its coverage out over the last few degrees
    edge = np.clip((np.minimum(lat[0] - out_lat, out_lat - lat[-1])) / 4.0, 0.0, 1.0)
    cov = np.where(ok, (edge[:, None] * 255 + 0.5), 0).astype(np.uint8)
    return idx8, cov


def gmgsi_purge(max_age=8 * 3600):
    d = os.path.join(CACHE, "gmgsi")
    if not os.path.isdir(d):
        return
    now = time.time()
    for name in os.listdir(d):
        p = os.path.join(d, name)
        try:
            if now - os.stat(p).st_mtime > max_age:
                os.remove(p)
        except OSError:
            pass


def weather_frame_png(t):
    """The global cloud layer for hourly frame `t`, equirectangular."""
    def build():
        key = dict(gmgsi_list()).get(t)
        if key is None:
            raise ValueError("no such frame")
        idx, cov = gmgsi_grid(key)
        return la_png(idx, cov)
    return cached(os.path.join(CACHE, "eq2", "wx", f"{t}.png"), build)


def inset_window(q, max_z):
    """Validated (z, x0, y0, n) of an inset request."""
    z, x0, y0, n = (int(q.get(k, -1)) for k in ("z", "x0", "y0", "n"))
    N = 2 ** max(z, 0)
    if not (0 <= z <= max_z and 1 <= n <= INSET_MAX_N and 0 <= y0 and y0 + n <= N and 0 <= x0 < N):
        raise ValueError("bad inset window")
    return z, x0, y0, n


def weather_inset_png(t, z, x0, y0, n):
    """Cloud index and coverage for a Mercator tile window, at that zoom."""
    def build():
        idx, cov = wx_window(f"obs/{t}", z, x0, y0, n)
        return la_png((idx * 255 + 0.5).astype(np.uint8), (cov * 255 + 0.5).astype(np.uint8))
    return cached(os.path.join(CACHE, "eq2", "wxi", f"{t}_{z}_{x0}_{y0}_{n}.png"), build)


def weather_lut_png():
    idx = np.linspace(0.0, 1.0, 256, dtype=np.float32)
    return lut_png(colorize(idx, np.ones(256, dtype=np.float32)))


def eq2_purge(max_age=6 * 3600):
    """Drop built weather textures older than a few hours."""
    now = time.time()
    for sub in ("wx", "wxi"):
        d = os.path.join(CACHE, "eq2", sub)
        if not os.path.isdir(d):
            continue
        for name in os.listdir(d):
            p = os.path.join(d, name)
            try:
                if now - os.stat(p).st_mtime > max_age:
                    os.remove(p)
            except OSError:
                pass


def weather_json():
    frames = [t for t, _ in gmgsi_list()]
    return {"frames": frames, "latest": frames[-1] if frames else None}


def weather_warm():
    """Keep the newest global frame built ahead of the poll and drop stale files."""
    while True:
        try:
            frames = gmgsi_list()
            if frames:
                weather_frame_png(frames[-1][0])
            wx_purge()
            eq2_purge()
            gmgsi_purge()
        except Exception as e:  # noqa: BLE001
            log(f"weather warm: {e}")
        time.sleep(300)


def lp_png():
    """Global light pollution zone index, equirectangular (nodata as zone 0)."""
    def build():
        zones = lp_window(LP_GLOBAL_Z, 0, 0, 2 ** LP_GLOBAL_Z)
        zones[zones == LP_NODATA] = 0
        return l_png(mercator_world_to_equirect(zones, LP_W, LP_H))
    return cached(os.path.join(CACHE, "eq2", f"lp_{LP_YEAR}_{LP_W}.png"), build)


def lp_inset_png(z, x0, y0, n):
    def build():
        zones = lp_window(z, x0, y0, n)
        zones[zones == LP_NODATA] = 0
        return l_png(zones)
    return cached(os.path.join(CACHE, "eq2", "lpi", f"{LP_YEAR}_{z}_{x0}_{y0}_{n}.png"), build)


def lp_lut_png(pal, tint):
    return lut_png(lp_colorize(np.arange(256, dtype=np.uint8), pal, tint))


# ---------------------------------------------------------------- vectors (Natural Earth)
NE_BASE = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/"
NE_LINES = [  # bundle layer, Natural Earth file, Douglas-Peucker tolerance in degrees
    ("coast50", "ne_50m_coastline", 0.01),
    ("admin0_50", "ne_50m_admin_0_boundary_lines_land", 0.01),
    ("coast10", "ne_10m_coastline", 0.002),
    ("admin0_10", "ne_10m_admin_0_boundary_lines_land", 0.002),
    ("admin1_10", "ne_10m_admin_1_states_provinces_lines", 0.002),
]
VECTORS_VERSION = 4


def ne_geojson(name):
    """A Natural Earth GeoJSON file, downloaded once into the cache."""
    path = os.path.join(CACHE, "ne", f"{name}.geojson")
    try:
        with open(path, "rb") as f:
            return json.loads(f.read())
    except OSError:
        pass
    data = mapkit.fetch(NE_BASE + name + ".geojson", timeout=180)
    write_atomic(path, data)
    return json.loads(data)


def simplify(pts, tol):
    """Douglas-Peucker on an (n, 2) array of lon/lat degrees."""
    n = len(pts)
    if n < 3 or tol <= 0:
        return pts
    keep = np.zeros(n, dtype=bool)
    keep[0] = keep[-1] = True
    stack = [(0, n - 1)]
    while stack:
        a, b = stack.pop()
        if b - a < 2:
            continue
        seg = pts[a + 1:b]
        p, q = pts[a], pts[b]
        d = q - p
        l2 = float(d @ d)
        if l2 == 0.0:
            dist = np.hypot(*(seg - p).T)
        else:
            t = np.clip(((seg - p) @ d) / l2, 0.0, 1.0)
            dist = np.hypot(*(seg - (p + t[:, None] * d)).T)
        i = int(np.argmax(dist))
        if dist[i] > tol:
            keep[a + 1 + i] = True
            stack.append((a, a + 1 + i))
            stack.append((a + 1 + i, b))
    return pts[keep]


def vectors_build():
    """The vector bundle, little-endian:

      "GLV3", u32 layers, per layer: u8 len + name, u32 lines, per line: u32 n, n x (f32 lat, f32 lon)
      u32 label sets, per set: u8 len + name, u32 labels, per label: u16 len + utf8, f32 lat, f32 lon,
      f32 rank (the web-map zoom the label is meant for; lower = more important), u8 kind
      (0 country, 1 region, 2 place, 3 capital, 4 airport), f32 population (0 where unknown)"""
    out = bytearray(b"GLV3")
    out += struct.pack("<I", len(NE_LINES))
    for layer, name, tol in NE_LINES:
        lines = []
        for f in ne_geojson(name)["features"]:
            g = f.get("geometry") or {}
            if g.get("type") == "LineString":
                parts = [g["coordinates"]]
            elif g.get("type") == "MultiLineString":
                parts = g["coordinates"]
            else:
                continue
            for part in parts:
                arr = np.asarray(part, dtype=np.float64)[:, :2]
                if len(arr) >= 2:
                    arr = simplify(arr, tol)
                    lines.append(np.ascontiguousarray(arr[:, ::-1]).astype("<f4"))  # lat, lon
        out += struct.pack("<B", len(layer)) + layer.encode() + struct.pack("<I", len(lines))
        for arr in lines:
            out += struct.pack("<I", len(arr)) + arr.tobytes()
        log(f"vectors: {layer}: {len(lines)} lines, {sum(len(a) for a in lines)} points")

    countries = []
    for f in ne_geojson("ne_50m_admin_0_countries")["features"]:
        p = f["properties"]
        name = p.get("NAME") or p.get("NAME_EN") or ""  # NAME is the short form ("China")
        x, y = p.get("LABEL_X"), p.get("LABEL_Y")
        if name and x is not None and y is not None:
            countries.append((name, float(y), float(x), float(p.get("MIN_LABEL") or 3.0), 0, float(p.get("POP_EST") or 0)))
    regions = {}
    for f in ne_geojson("ne_10m_admin_1_label_points")["features"]:
        p = f["properties"]
        name = p.get("name") or ""
        c = (f.get("geometry") or {}).get("coordinates")
        if not name or not c:
            continue
        key = (name, p.get("admin"))
        rank = float(p.get("scalerank") or 8)
        if key not in regions or rank < regions[key][3]:
            regions[key] = (name, float(c[1]), float(c[0]), rank, 1, 0.0)
    places = []
    for f in ne_geojson("ne_10m_populated_places_simple")["features"]:
        p = f["properties"]
        name = p.get("name") or ""
        c = (f.get("geometry") or {}).get("coordinates")
        if not name or not c:
            continue
        kind = 3 if str(p.get("featurecla") or "").startswith("Admin-0 capital") else 2
        rank = p.get("min_zoom")
        rank = float(rank if rank is not None else p.get("scalerank") or 8)
        places.append((name, float(c[1]), float(c[0]), rank, kind, float(p.get("pop_max") or 0)))
    airports = []
    for f in ne_geojson("ne_10m_airports")["features"]:
        p = f["properties"]
        code = (p.get("iata_code") or p.get("abbrev") or "").strip()
        c = (f.get("geometry") or {}).get("coordinates")
        if not code or not c:
            continue
        airports.append((code, float(c[1]), float(c[0]), float(p.get("scalerank") or 9), 4, 0.0))
    sets = [("countries", countries), ("regions", list(regions.values())), ("places", places), ("airports", airports)]
    out += struct.pack("<I", len(sets))
    for name, labels in sets:
        out += struct.pack("<B", len(name)) + name.encode() + struct.pack("<I", len(labels))
        for text, lat, lon, rank, kind, pop in labels:
            b = text.encode()[:255]
            out += struct.pack("<H", len(b)) + b + struct.pack("<fffBf", lat, lon, rank, kind, pop)
        log(f"vectors: {name}: {len(labels)} labels")
    return bytes(out)


def vectors_bin():
    path = os.path.join(CACHE, "vectors", f"v{VECTORS_VERSION}.bin")
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError:
        pass
    with comp_lock(path):
        if os.path.exists(path):
            with open(path, "rb") as f:
                return f.read()
        t0 = time.time()
        data = vectors_build()
        write_atomic(path, data)
        log(f"vectors: bundle {len(data) // 1024} KB built in {time.time() - t0:.1f} s")
        return data


def vectors_warm():
    try:
        vectors_bin()
    except Exception as e:  # noqa: BLE001
        log(f"vectors: {e}")


# ---------------------------------------------------------------- satellites (CelesTrak TLEs)
CELESTRAK = "https://celestrak.org/NORAD/elements/gp.php?GROUP={group}&FORMAT=tle"
TLE_GROUPS = {  # what the widget may ask for -> CelesTrak groups
    "stations": ["stations"],
    "visual": ["visual"],
    "weather": ["weather"],
    "gnss": ["gps-ops", "galileo", "glo-ops", "beidou"],
    "science": ["science"],
    "starlink": ["starlink"],
}
TLE_MAX_AGE = 12 * 3600


CELESTRAK_QUERY = "https://celestrak.org/NORAD/elements/gp.php?{query}&FORMAT=tle"


def tle_text(query, key):
    """TLE text for one CelesTrak query, refreshed every 12 hours (the last
    copy is kept when CelesTrak is unreachable)."""
    path = os.path.join(CACHE, "tle", f"{key}.txt")
    try:
        st = os.stat(path)
        if time.time() - st.st_mtime < TLE_MAX_AGE:
            with open(path, "rb") as f:
                return f.read().decode(errors="replace")
    except OSError:
        pass
    with comp_lock(path):
        try:
            data = mapkit.fetch(CELESTRAK_QUERY.format(query=query), timeout=60)
            if b"\n2 " in data or data.startswith(b"No GP data"):
                write_atomic(path, data)
                return data.decode(errors="replace")
            log(f"tle {key}: unexpected reply")
        except Exception as e:  # noqa: BLE001
            log(f"tle {key}: {e}")
        try:
            with open(path, "rb") as f:
                return f.read().decode(errors="replace")
        except OSError:
            return ""


def tle_parse(text, group, sats, seen):
    lines = [l.rstrip() for l in text.splitlines() if l.strip()]
    for i in range(0, len(lines) - 2, 3):
        title, l1, l2 = lines[i], lines[i + 1], lines[i + 2]
        if not (l1.startswith("1 ") and l2.startswith("2 ")):
            continue
        try:
            norad = int(l1[2:7])
        except ValueError:
            continue
        if norad in seen:
            continue
        seen.add(norad)
        sats.append({"name": title.strip(), "norad": norad, "l1": l1, "l2": l2, "group": group})


def tle_json(groups, catnrs, names):
    """Groups, then single objects by NORAD number and CelesTrak name searches
    (group "extra"), without duplicates."""
    sats, seen = [], set()
    for name in groups:
        for group in TLE_GROUPS.get(name, []):
            tle_parse(tle_text(f"GROUP={group}", group), name, sats, seen)
    for n in catnrs:
        tle_parse(tle_text(f"CATNR={n}", f"catnr_{n}"), "extra", sats, seen)
    for q in names:
        safe = "".join(c if c.isalnum() else "_" for c in q)[:40]
        tle_parse(tle_text(f"NAME={urllib.parse.quote(q)}", f"name_{safe}"), "extra", sats, seen)
    return {"sats": sats, "ts": time.time()}


# ---------------------------------------------------------------- routes and trails (for a clicked aircraft)
ROUTE_RE = __import__("re").compile(r"^[A-Z]{3}\d{1,4}[A-Z]?$")
ROUTES_FILE = os.path.join(CACHE, "routes.json")
_routes = {}
_routes_lock = threading.Lock()
_route_q = queue.PriorityQueue(maxsize=6000)
_route_pending = set()
_route_seq = [0]
_routes_dirty = [False]


def routes_load():
    try:
        with open(ROUTES_FILE) as f:
            d = json.load(f)
        now = time.time()
        with _routes_lock:
            for cs, e in d.items():
                if now - e["ts"] < (86400 if e["data"] else 3600):
                    _routes[cs] = e
        log(f"routes: {len(_routes)} cached")
    except (OSError, ValueError):
        pass


def routes_save():
    with _routes_lock:
        if not _routes_dirty[0]:
            return
        snap = json.dumps(_routes)
        _routes_dirty[0] = False
    write_atomic(ROUTES_FILE, snap.encode())


def routes_saver():
    while True:
        time.sleep(30)
        try:
            routes_save()
        except Exception as e:  # noqa: BLE001
            log(f"routes save: {e}")


RETRY = object()   # transient failure: don't cache, look up again later
ADSBDB = "api.adsbdb.com"


def adsbdb_get(path):
    """GET on a per-thread keep-alive connection (adsbdb throttles fresh TLS handshakes)."""
    for attempt in range(2):
        try:
            c = getattr(_local, "adsbdb", None)
            if c is None:
                c = http.client.HTTPSConnection(ADSBDB, timeout=12)
                _local.adsbdb = c
            c.request("GET", path, headers={"User-Agent": UA, "Accept": "application/json"})
            r = c.getresponse()
            data = r.read()
            return r.status, data
        except (http.client.HTTPException, OSError) as e:
            _local.adsbdb = None
            last = e
    raise last


def route_lookup(callsign):
    """One route from adsbdb.com: dict, None when unknown, RETRY on transient failure."""
    try:
        status, data = adsbdb_get(f"/v0/callsign/{urllib.parse.quote(callsign)}")
    except Exception as e:  # noqa: BLE001
        log(f"route {callsign}: {e}")
        return RETRY
    if status == 404:
        return None
    if status != 200:
        log(f"route {callsign}: HTTP {status}")
        return RETRY
    try:
        fr = json.loads(data.decode()).get("response", {}).get("flightroute")
    except ValueError:
        return RETRY
    if not fr:
        return None
    def ap(x):
        if not x:
            return None
        return {"icao": x.get("icao_code", ""), "iata": x.get("iata_code", ""), "name": x.get("name", ""),
                "city": x.get("municipality", ""), "lat": x.get("latitude"), "lon": x.get("longitude")}
    return {"origin": ap(fr.get("origin")), "destination": ap(fr.get("destination")),
            "airline": (fr.get("airline") or {}).get("name", "")}


def route_get(callsign, prio=2):
    """Cached route or None; queues a lookup (at `prio`) when unseen."""
    if not callsign or not ROUTE_RE.match(callsign):
        return None
    with _routes_lock:
        e = _routes.get(callsign)
        if e and time.time() - e["ts"] < (86400 if e["data"] else 3600):
            return e["data"]
        if callsign in _route_pending:
            return None
        _route_pending.add(callsign)
        _route_seq[0] += 1
        item = (prio, _route_seq[0], callsign)
    try:
        _route_q.put_nowait(item)
    except queue.Full:
        with _routes_lock:
            _route_pending.discard(callsign)
    return None


def route_resolve_now(callsign):
    """Synchronous variant for airport queries (waits for the lookup)."""
    if not callsign or not ROUTE_RE.match(callsign):
        return None
    with _routes_lock:
        e = _routes.get(callsign)
        if e and time.time() - e["ts"] < (86400 if e["data"] else 3600):
            return e["data"]
    data = route_lookup(callsign)
    with _routes_lock:
        _route_pending.discard(callsign)
        if data is RETRY:
            return None
        _routes[callsign] = {"data": data, "ts": time.time()}
        _routes_dirty[0] = True
    return data


def route_worker():
    while True:
        prio, seq, cs = _route_q.get()
        with _routes_lock:
            e = _routes.get(cs)
            if e and time.time() - e["ts"] < (86400 if e["data"] else 3600):
                _route_pending.discard(cs)
                continue
        data = route_lookup(cs)
        if data is RETRY:
            time.sleep(3)
            try:
                _route_q.put_nowait((prio, seq, cs))   # keep its place in line
            except queue.Full:
                with _routes_lock:
                    _route_pending.discard(cs)
            continue
        with _routes_lock:
            _routes[cs] = {"data": data, "ts": time.time()}
            _route_pending.discard(cs)
            _routes_dirty[0] = True
        time.sleep(0.05)


# ---------------------------------------------------------------- trails (positions seen this session)
_trails = {}          # hex -> [(t, lat, lon, alt), ...]
_trails_lock = threading.Lock()
TRAIL_MAX = 180


def trail_add(ac, now):
    with _trails_lock:
        for a in ac:
            tr = _trails.setdefault(a["hex"], [])
            if tr and tr[-1][1] == a["lat"] and tr[-1][2] == a["lon"]:
                continue
            tr.append((now, a["lat"], a["lon"], a["alt"]))
            if len(tr) > TRAIL_MAX:
                del tr[:len(tr) - TRAIL_MAX]
        if len(_trails) > 3000:
            cutoff = now - 1800
            for h in [h for h, tr in _trails.items() if tr[-1][0] < cutoff]:
                del _trails[h]


_osky = {}
_osky_lock = threading.Lock()


def opensky_track(hexid):
    """Waypoints of the current flight from OpenSky (free, ~1 min cache)."""
    with _osky_lock:
        e = _osky.get(hexid)
        if e and time.time() - e["ts"] < 60:
            return e["data"]
    data = None
    try:
        req = urllib.request.Request(f"https://opensky-network.org/api/tracks/all?icao24={hexid}&time=0", headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=15) as r:
            d = json.loads(r.read().decode())
        data = [{"t": p[0], "lat": p[1], "lon": p[2], "alt": (p[3] or 0) * 3.28084} for p in d.get("path", []) if p[1] is not None]
    except urllib.error.HTTPError as e:
        if e.code != 404:
            log(f"opensky {hexid}: {e}")
    except Exception as e:  # noqa: BLE001
        log(f"opensky {hexid}: {e}")
    with _osky_lock:
        _osky[hexid] = {"data": data, "ts": time.time()}
    return data


def trail_get(hexid):
    """OpenSky track from takeoff, extended by positions seen here since its last waypoint."""
    pts = opensky_track(hexid) or []
    last = pts[-1]["t"] if pts else 0
    with _trails_lock:
        local = [{"t": t, "lat": la, "lon": lo, "alt": al} for t, la, lo, al in _trails.get(hexid, []) if t > last]
    return {"points": pts + local, "source": "opensky" if pts else "local"}


def aircraft_get(hex_):
    """One aircraft in full for the widget: state, type, registration, its
    route (adsbdb, looked up now if unseen) and its path (OpenSky's track of
    the current flight plus positions seen here)."""
    now = time.time()
    a = merged_aircraft(now).get(hex_)
    if not a:
        return {"error": "unknown"}
    a = dead_reckon(a, now)
    return dict(a, route=route_resolve_now(a.get("flight") or ""), trail=trail_get(hex_))


# ---------------------------------------------------------------- aircraft
def region_poll_once():
    """Live aircraft within 250 nm of every watched point (home)."""
    with _region_lock:
        points = list(_watch.items())
    now = time.time()
    for name, (lat, lon) in points:
        try:
            req = urllib.request.Request(f"https://api.adsb.lol/v2/lat/{lat}/lon/{lon}/dist/250", headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=10) as r:
                ac = adsb_trim(json.loads(r.read().decode()))
        except urllib.error.HTTPError as e:
            if e.code in (420, 429):
                _region_interval["s"] = min(300, _region_interval["s"] * 2)
                log(f"region {name}: rate limited; polling every {_region_interval['s']} s")
            else:
                log(f"region {name}: {e}")
            continue
        except Exception as e:  # noqa: BLE001
            log(f"region {name}: {e}")
            continue
        _region_interval["s"] = max(30, _region_interval["s"] // 2) if _region_interval["s"] > 30 else 30
        trail_add(ac, now)
        with _region_lock:
            for a in ac:
                a["seen"] = now
                _region[a["hex"]] = a
        for a in ac:
            route_get(a["flight"], 1)
    with _region_lock:
        for h in [h for h, a in _region.items() if now - a["seen"] > 180]:
            del _region[h]


def frame_json():
    """Every aircraft, dead-reckoned to one instant, at most every FRAME_TTL s."""
    with _frame_lock:
        now = time.time()
        if not _frame["ac"] or now - _frame["ts"] >= FRAME_TTL:
            ac = [dead_reckon(a, now) for a in merged_aircraft(now).values()]
            _frame.update(id=_frame["id"] + 1, ts=now, ac=ac)
        fr = dict(_frame)
    with _global_lock:
        gts = _global["ts"]
    rows = [[a["hex"], a["flight"], round(a["lat"], 4), round(a["lon"], 4), round(a.get("track") or 0), round(a.get("alt") or 0), round(a.get("gs") or 0)]
            for a in fr["ac"]]
    return {"rows": rows, "total": len(rows), "ts": fr["ts"], "global_age": round(fr["ts"] - gts) if gts else None}


# ---------------------------------------------------------------- http
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # quiet
        pass

    def send(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        try:
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def send_json(self, obj, code=200):
        self.send(code, "application/json", json.dumps(obj).encode())

    def do_GET(self):  # noqa: N802
        u = urllib.parse.urlsplit(self.path)
        q = dict(urllib.parse.parse_qsl(u.query))
        parts = u.path.strip("/").split("/")
        try:
            if u.path == "/health":
                return self.send(200, "text/plain", b"ok")
            if u.path == "/geo.json":
                geo = mapkit.geolocate(q.get("location", ""), q.get("label", ""))
                watch_add("home", geo["lat"], geo["lon"])
                return self.send_json(geo)
            if u.path == "/weather.json":
                return self.send_json(weather_json())
            if u.path == "/weather/lut.png":
                return self.send(200, "image/png", weather_lut_png())
            if parts[0] == "weather" and len(parts) in (2, 3):
                t = int(parts[1].split(".")[0])
                if t not in weather_json()["frames"]:
                    return self.send(404, "text/plain", b"no such frame")
                if len(parts) == 3:
                    return self.send(200, "image/png", weather_inset_png(t, *inset_window(q, WX_MAX_Z)))
                return self.send(200, "image/png", weather_frame_png(t))
            if u.path == "/lp.png":
                return self.send(200, "image/png", lp_png())
            if u.path == "/lp/inset.png":
                return self.send(200, "image/png", lp_inset_png(*inset_window(q, LP_MAX_Z + 2)))
            if u.path == "/lp/lut.png":
                tint = q.get("tint", "181825")
                if len(tint) != 6:
                    return self.send(400, "text/plain", b"bad tint")
                return self.send(200, "image/png", lp_lut_png(lp_pal(q), tint))
            if u.path == "/adsb.json":
                return self.send_json(frame_json())
            if parts[0] == "aircraft" and len(parts) == 2:
                return self.send_json(aircraft_get(parts[1].split(".")[0].lower()))
            if u.path == "/vectors.bin":
                return self.send(200, "application/octet-stream", vectors_bin())
            if u.path == "/tle.json":
                groups = [g for g in q.get("groups", "").split(",") if g in TLE_GROUPS]
                catnrs = [c for c in q.get("catnr", "").split(",") if c.isdigit()][:50]
                names = [n.strip() for n in q.get("names", "").split(",") if n.strip()][:20]
                return self.send_json(tle_json(groups, catnrs, names))
            return self.send(404, "text/plain", b"not found")
        except Exception as e:  # noqa: BLE001
            log(f"{self.path}: {e}")
            return self.send_json({"error": str(e)}, 500)


def main():
    os.makedirs(CACHE, exist_ok=True)
    signal.signal(signal.SIGTERM, lambda *a: os._exit(0))
    threading.Thread(target=watch_parent, daemon=True).start()
    if stop_others():
        log("stopped an older instance")
    announced = False
    while True:
        try:
            srv = Server(("127.0.0.1", PORT), Handler)
            break
        except OSError:
            # Something else holds the port (an older instance on its way out,
            # say): stand in for it while it's healthy and take over once it's
            # gone. The feeds only start once this one serves, so a stand-in
            # never polls anything twice.
            if healthy():
                if not announced:
                    print("ready", flush=True)
                    announced = True
                time.sleep(0.25)
            else:
                time.sleep(0.1)
    load_secrets()
    threading.Thread(target=global_worker, daemon=True).start()
    threading.Thread(target=region_worker, daemon=True).start()
    threading.Thread(target=weather_warm, daemon=True).start()
    threading.Thread(target=vectors_warm, daemon=True).start()
    routes_load()
    threading.Thread(target=route_worker, daemon=True).start()
    threading.Thread(target=routes_saver, daemon=True).start()
    if not announced:
        print("ready", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
