#!/usr/bin/env python3
"""Make the lock screen's depth masks for still wallpapers, locally (no uploads).

  masks.py [--model birefnet-general] [--force] [--width 2560] [STEM ...]

For each wallpaper folder (all stills when no STEM is given) this writes
wallpapers/<stem>/lock/fg-mask.png: an 8-bit greyscale mask, same aspect as the
image, white = the subject. lock.toml's [depth] foreground points at it, and
text with depth = "behind" is drawn under the subject (see README.md).

Segmentation is BiRefNet through rembg (open source, CPU, runs offline once the
model is cached in ~/.rembg). rembg is not a dependency of the lock itself; this
script re-runs itself with the venv in ~/.local/share/lockmask when the current
Python lacks it. Set that venv up once with:

  uv venv --python 3.12 ~/.local/share/lockmask/.venv
  uv pip install --python ~/.local/share/lockmask/.venv/bin/python "rembg[cpu]"

Background masks (lock/bg-mask.png, white = the far plane, i.e. the sky) suit
silhouettes against a bright sky, where a subject model finds nothing:
`--sky STEM` marks, per column, everything above the first dark run (skyline,
treeline, a tree) as sky. `--dark 0.22` sets the luminance cut (0-1). `--invert
STEM` instead writes the inverse of STEM's subject mask.
"""
import argparse
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
WALLPAPERS = HERE.parent.parent / "wallpapers"
VENV_PY = Path.home() / ".local/share/lockmask/.venv/bin/python"
STILLS = {".png", ".jpg", ".jpeg", ".webp"}

try:
    from PIL import Image, ImageFilter, ImageOps
    import rembg  # noqa: F401
except ImportError:
    if VENV_PY.is_file() and Path(sys.executable).resolve() != VENV_PY.resolve():
        os.execv(str(VENV_PY), [str(VENV_PY), __file__, *sys.argv[1:]])
    sys.exit(f"masks.py: needs rembg + Pillow (see the docstring for the venv at {VENV_PY.parent.parent})")

Image.MAX_IMAGE_PIXELS = None


def image_of(folder):
    for p in sorted(folder.iterdir()):
        if p.suffix.lower() in STILLS and p.stem == folder.name:
            return p
    return None


def subject_mask(session, src, width):
    from rembg import remove
    im = Image.open(src).convert("RGB")
    w = min(width, im.width)
    h = round(im.height * w / im.width)
    small = im.resize((w, h), Image.LANCZOS)
    m = remove(small, session=session, only_mask=True)
    m = m.convert("L")
    # Clean up: drop faint haze the model half-selects, keep soft edges.
    m = m.point(lambda v: 0 if v < 24 else 255 if v > 232 else v)
    return m.filter(ImageFilter.GaussianBlur(0.6))


def sky_mask(src, width, dark):
    """White above the first dark run of each column (a silhouette's top edge)."""
    import numpy as np
    im = Image.open(src).convert("L")
    w = min(width, im.width)
    h = round(im.height * w / im.width)
    work = im.resize((w // 2, h // 2), Image.LANCZOS).filter(ImageFilter.GaussianBlur(1.5))
    lum = np.asarray(work, dtype=np.float32) / 255
    land = lum < dark
    # a run of 6 dark rows (at half size) is land; stray dark specks are not
    run = land.copy()
    for k in range(1, 6):
        run[:-k] &= land[k:]
        run[-k:] = False
    first = np.where(run.any(axis=0), run.argmax(axis=0), land.shape[0])
    rows = np.arange(land.shape[0])[:, None]
    m = Image.fromarray(((rows < first[None, :]) * 255).astype(np.uint8))
    return m.resize((w, h), Image.BILINEAR).filter(ImageFilter.GaussianBlur(1.2))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("stems", nargs="*")
    ap.add_argument("--model", default="birefnet-general")
    ap.add_argument("--width", type=int, default=2560, help="mask width (px), height follows the image")
    ap.add_argument("--force", action="store_true", help="remake masks that exist")
    ap.add_argument("--invert", action="store_true", help="write lock/bg-mask.png = inverse of fg-mask.png")
    ap.add_argument("--sky", action="store_true", help="write lock/bg-mask.png from the skyline (no model)")
    ap.add_argument("--dark", type=float, default=0.22, help="--sky: luminance below this is land (0-1)")
    a = ap.parse_args()

    folders = [WALLPAPERS / s for s in a.stems] if a.stems else sorted(
        p for p in WALLPAPERS.iterdir() if p.is_dir() and not p.name.startswith("_"))
    if a.invert:
        for f in folders:
            fg = f / "lock/fg-mask.png"
            if fg.is_file():
                ImageOps.invert(Image.open(fg).convert("L")).save(f / "lock/bg-mask.png", optimize=True)
                print(f"{f.name}: lock/bg-mask.png")
        return

    if a.sky:
        for f in folders:
            src = image_of(f)
            if src:
                (f / "lock").mkdir(exist_ok=True)
                sky_mask(src, a.width, a.dark).save(f / "lock/bg-mask.png", optimize=True)
                print(f"{f.name}: lock/bg-mask.png")
        return

    from rembg import new_session
    session = new_session(a.model)
    for f in folders:
        src = image_of(f)
        out = f / "lock/fg-mask.png"
        if not src:
            print(f"{f.name}: no still, skipped")
            continue
        if out.is_file() and not a.force:
            print(f"{f.name}: exists")
            continue
        out.parent.mkdir(exist_ok=True)
        subject_mask(session, src, a.width).save(out, optimize=True)
        print(f"{f.name}: {out.relative_to(WALLPAPERS)} ({out.stat().st_size // 1024} KiB)", flush=True)


if __name__ == "__main__":
    main()
