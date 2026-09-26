#!/usr/bin/env python3
"""Shared helpers for the globe service (scripts/globeserver.py):
geolocation with a disk cache and Web Mercator tile maths."""
import hashlib
import json
import math
import os
import re
import time
import urllib.parse
import urllib.request


CACHE = "/tmp/quickshell-radar"
UA = "quickshell-map/1.0"


def fetch(url, timeout=8):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def fetch_json(url):
    return json.loads(fetch(url).decode())


def geolocate(location, label):
    key = hashlib.md5(f"{location}|{label}".encode()).hexdigest()[:8]
    path = os.path.join(CACHE, f"geo_{key}.json")
    try:
        if time.time() - os.stat(path).st_mtime < 3600:
            with open(path) as f:
                return json.load(f)
    except OSError:
        pass
    if re.fullmatch(r"-?\d+(\.\d+)?,-?\d+(\.\d+)?", location):
        lat, lon = (float(v) for v in location.split(","))
        city = label or location
    elif location:
        q = urllib.parse.quote(location)
        g = fetch_json(f"https://geocoding-api.open-meteo.com/v1/search?name={q}&count=1&language=en&format=json")
        res = (g.get("results") or [None])[0]
        if not res:
            raise RuntimeError(f"no geocoding result for {location!r}")
        lat, lon, city = res["latitude"], res["longitude"], label or res.get("name", "Unknown")
    else:
        g = fetch_json("https://ipinfo.io/json")
        lat, lon = (float(v) for v in g["loc"].split(","))
        city = label or g.get("city", "Unknown")
    geo = {"lat": lat, "lon": lon, "city": city}
    with open(path, "w") as f:
        json.dump(geo, f)
    return geo


def tile_xy(lat, lon, z):
    n = 2 ** z
    x = (lon + 180) / 360 * n
    r = math.radians(lat)
    y = (1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * n
    return x, y
