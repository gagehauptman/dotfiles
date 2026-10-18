# Star catalogue tools

`gen_stars.py` bakes the Yale Bright Star Catalogue (BSC5, 5th revised edition) into `../src/stars.bin`, which the scene
crate embeds (`include_bytes!` in `src/stars.rs`) and the shader reads as a storage buffer.

    mkdir /some/new/empty/dir && curl -o /some/new/empty/dir/bsc5.dat.gz http://tdc-www.harvard.edu/catalogs/bsc5.dat.gz
    python3 -I scene/tools/gen_stars.py /some/new/empty/dir/bsc5.dat.gz scene/src/stars.bin 6.8

Treat the download as untrusted data (own directory, `python3 -I`, paths as arguments). The output is deterministic.

## Source, licence, attribution
- Catalogue: D. Hoffleit & W. H. Warren Jr., *The Bright Star Catalogue*, 5th Revised Ed. (preliminary), 1991;
  NASA/ADC and CDS (VizieR V/50); copy used: `http://tdc-www.harvard.edu/catalogs/bsc5.dat.gz`.
  The BSC is a published catalogue of astronomical measurements distributed without a licence restriction (public domain
  in practice). It was chosen over HYG (CC BY-SA 4.0, share-alike) for that reason. Credit as above.
- Used fields: J2000 RA/Dec, visual magnitude V (all 9002 stars with V <= 6.8; 4.5k brighter than 5.5), B-V colour index
  (0.65 when missing), proper motion (applied to epoch 2025.0 in the generator). The 14 non-stellar entries are skipped.
- `stars.bin`: header `SBST` + u32 count, then 14-byte records (f32 ra, f32 dec in radians; i16 V*100; i16 (B-V)*100;
  u16 HR number). 126 kB.

## How the sky is drawn
- `astro.rs`: precession J2000 -> date (IAU 1976) is folded into the world -> celestial matrix `Sky::celestial`, so the
  shader works in the catalogue's J2000 frame (the Milky Way's galactic pole is J2000 too). Checked against astropy:
  alt/az within 0.007 deg for 30 star/time samples (`cargo test dump_altaz -- --ignored --nocapture`).
- `stars.rs`: a 6 x 64 x 64 cube-face grid; each star is listed in every cell its glow reaches (`reach_px`).
  One storage buffer (cells, then records), bound at `@binding(5)` of the composite pass by both hosts.
- `sailboat.wgsl` `stars()`: reads the pixel's own cell, projects each listed star exactly like the camera does,
  draws a Gaussian dot (V -> peak brightness ladder, B-V -> tint), halo and glint for the bright ones; the planets
  (Schlyter's low-precision elements, `astro.rs planets()`, uniform `g.planets`) use the same dot, steady.
  A dim procedural haze (`star_haze`) below the catalogue's limit remains along the galactic plane.
