#!/usr/bin/env python3
"""Bakes the Yale Bright Star Catalogue (5th rev., Hoffleit & Warren 1991) into ../src/stars.bin.

Usage (the catalogue is untrusted data: keep it in its own directory, run with -I):
    python3 -I gen_stars.py /path/to/bsc5.dat.gz /path/to/stars.bin [max_vmag]

Source: http://tdc-www.harvard.edu/catalogs/bsc5.html  (CDS/VizieR V/50, NASA ADC). The BSC is a
published catalogue of facts (positions, magnitudes) with no licence restriction; credit
D. Hoffleit & W. H. Warren Jr., "The Bright Star Catalogue", 5th Revised Ed., 1991.

Record (little endian, 14 bytes), after the 8-byte header b"SBST" + u32 count:
    f32 ra   radians, J2000 equator and equinox, moved by proper motion to epoch 2025.0
    f32 dec  radians (same)
    i16 vmag * 100
    i16 B-V * 100   (i16::MIN when the catalogue has none)
    u16 HR number
"""
import gzip
import math
import struct
import sys

EPOCH_YEARS = 25.0  # 2000.0 -> 2025.0: proper motion applied once here; precession is done at run time


def num(s):
    s = s.strip()
    return float(s) if s else None


def main():
    src, dst = sys.argv[1], sys.argv[2]
    max_v = float(sys.argv[3]) if len(sys.argv) > 3 else 6.8
    rows = []
    skipped = 0
    for line in gzip.open(src, "rt", encoding="latin-1").read().split("\n"):
        if len(line) < 115:
            continue
        hr = int(line[0:4])
        rah, ram, ras = num(line[75:77]), num(line[77:79]), num(line[79:83])
        ded, dem, des = num(line[83:86]), num(line[86:88]), num(line[88:90])
        v = num(line[102:107])
        if None in (rah, ram, ras, ded, dem, des) or v is None or v > max_v:
            skipped += 1  # novae/extragalactic entries without data, or too faint
            continue
        sign = -1.0 if line[83] == "-" else 1.0
        ra = (rah + ram / 60.0 + ras / 3600.0) * 15.0
        dec = sign * (abs(ded) + dem / 60.0 + des / 3600.0)
        bv = num(line[109:114])
        pmra = num(line[148:154]) or 0.0  # arcsec/yr, already * cos(dec)
        pmde = num(line[154:160]) or 0.0
        dec += pmde * EPOCH_YEARS / 3600.0
        ra += pmra * EPOCH_YEARS / 3600.0 / max(math.cos(math.radians(dec)), 0.02)
        rows.append((hr, math.radians(ra % 360.0), math.radians(dec), v, bv))
    rows.sort(key=lambda r: r[3])
    with open(dst, "wb") as f:
        f.write(b"SBST" + struct.pack("<I", len(rows)))
        for hr, ra, dec, v, bv in rows:
            f.write(struct.pack("<ffhhH", ra, dec, round(v * 100), -32768 if bv is None else round(bv * 100), hr))
    print(f"{len(rows)} stars (skipped {skipped}), brightest V={rows[0][3]}, faintest V={rows[-1][3]}, {8 + 14 * len(rows)} bytes")


main()
