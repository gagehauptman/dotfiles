#!/usr/bin/env python3
"""Converts Natural Earth's 1:50m coastline (ne_50m_coastline.geojson,
public domain, https://www.naturalearthdata.com/) into the wallpaper's
compact coastline asset, coastline.bin. Offline, run once; standard library
only.

    coastline.py <ne_50m_coastline.geojson> <out coastline.bin>

50m rather than 110m: the Earth is a disc about two screen widths across,
so a degree is ~120 px and 110m's vertices would show as long straight
chords; 10m would be eight times the vertices for detail that's mostly
sub-pixel. The globe wallpaper keeps its own outlines (continents.rs).

coastline.bin, little endian: u32 polyline count; per polyline u32 point
count, then that many (f32 longitude, f32 latitude) in degrees.
"""
import json
import struct
import sys


def main(src, dst):
    lines = []
    for f in json.load(open(src))['features']:
        g = f['geometry']
        parts = [g['coordinates']] if g['type'] == 'LineString' else g['coordinates']
        for part in parts:
            pts = [(float(p[0]), float(p[1])) for p in part]
            # Drop repeated points (zero-length segments).
            pts = [p for i, p in enumerate(pts) if i == 0 or p != pts[i - 1]]
            if len(pts) >= 2:
                lines.append(pts)
    out = bytearray(struct.pack('<I', len(lines)))
    for pts in lines:
        out += struct.pack('<I', len(pts))
        for lon, lat in pts:
            out += struct.pack('<ff', lon, lat)
    open(dst, 'wb').write(out)
    print(f'{len(lines)} polylines, {sum(len(p) for p in lines)} points, {len(out)} bytes')


if __name__ == '__main__':
    main(*sys.argv[1:3])
