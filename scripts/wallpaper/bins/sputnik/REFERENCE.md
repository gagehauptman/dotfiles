# Sputnik 1: what the model is built from

Notes for the satellite in this scene (the constants under "Showing it" in
`scene/src/lib.rs`, the arms in `frame()`, the ball in `scene/src/sputnik.wgsl`),
so every proportion is traceable. Gathered 2026-10-06 from 18 photographs of
museum replicas and the documentary sources below; the replicas agree with
each other on everything listed.

## Sources

- en.wikipedia.org/wiki/Sputnik_1 (Design): a 585 mm sphere of two
  hemispheres sealed with O-rings and joined by 36 bolts, 2 mm shells under
  a highly polished 1 mm heat shield of AMG6T (Al-Mg-Ti); two pairs of
  antennas, each of two whip-like parts, 2.4 m and 2.9 m; dry nitrogen at
  1.3 atm inside.
- ru.wikipedia.org/wiki/Спутник-1 (Устройство): 58 cm, AMg-6, 2 mm, with
  joining frames (шпангоуты) tied by 36 M8×2.5 studs; the upper half-shell
  of a smaller radius under a 1 mm outer screen; on the upper half-shell two
  crossed V-dipole antennas facing backward, arms of 2.4 m (VHF) and 2.9 m
  (HF), the angle between the arms of a pair 70°, spread to it by a spring
  mechanism after separation; on the front half-shell four antenna sockets
  with hermetic cable fittings and the filling valve's flange; on the rear
  half-shell the heel contact and the test connector's flange.
- russianspaceweb.com/sputnik_design.html (A. Zak): 580 mm, 36 bolts, "the
  top hemisphere carried two antennas with two beams each", deployed "to the
  angle of 35 degrees toward the main axis"; the exploded view shows the
  antenna interface on the top hemisphere.
- Photographs (Wikimedia Commons, by file name): `Sputnik asm.jpg` (NASA,
  the NASM replica); `Sputnik 1 at the National Air and Space Museum, Dec
  2017`; `Sputnik, National Air and Space Museum`; `Sputnik1 a - Smithsonian
  Air and Space Museum - 2012-05-15` (the best close-up of the brackets and
  the strap); `Replica of Sputnik 1, World Museum Liverpool (2)` and `(3)`;
  `Moscow Polytechnical Museum, Sputnik 1`; `Sputnik-1 (model) 01` and `02`
  (the GUM model: strap, stud heads, bracket housing and the valve flange
  close up); `Sputnik-1 full scale model` (the cleanest silhouette:
  ferrules, stepped whips, the valve flange); `SputnikReplica`; `Sputnik,
  Tellus Science Museum` (the whole span of the arms); `Replica of Sputnik 1
  at the Musée de l'air et de l'espace, Le Bourget`; `USSR Sputnik I, 1957,
  1st Man-made Satellite (Replica)`; `Memorial Museum of Space Exploration
  (5585744173)` (the flight-ready one in its fairing); `SputnikTestModel`.
  Plus Vic's own reference, a rendering of it in orbit.

## What they show, and what the scene does

Sizes in ball radii R (290 mm) unless said.

| Real | In the scene |
|---|---|
| A 580 mm sphere, R = 290 mm | `BALL` = 0.058 of the screen height (83 px at 1440) |
| Two hemispheres meeting on the equator; their joining frames show as a narrow raised strap, about 15 mm wide, with a row of stud heads round it | `SEAM` = 0 (the equator); the strap's half-width 0.026 R with a navy keyline each side, 36 stud heads of radius 0.016 R every 10° (shader) |
| HF arms 2.9 m = 10.0 R; VHF arms 2.4 m = 8.28 R | `ANTENNA` = (10.0, 8.28) |
| Each arm 35° off the axis, trailing aft; opposite arms make one dipole, the two dipoles crossed | `ANTENNA_SPLAY` = 35; arms at 45°, 135°, 225°, 315° round the axis, the long pair opposite each other |
| Four hinges 90° apart on the front half-shell, right against the strap | `MOUNT` = 0.10 (5.7° ahead of the equator; the knuckle's edge just clears the strap) |
| Each hinge's bracket: a tapered plate lying on the shell, pointing forward from the hinge, about 100 mm long and 40 mm wide at the hinge end | `BRACKET` = 0.36 rad of arc along the meridian, 0.14 → 0.07 R wide, in the shell's ink |
| The arm: a hinge knuckle, a ferrule tube about 100 mm long and 30 mm across, a collar, then the whip, about 15 mm stepping down to 10 mm and a point | knuckle 0.15 → 0.13 R wide to 0.10 R along; ferrule 0.105 → 0.095 R to 0.44 R; collar to 0.50 R; rod 0.055 → 0.045 R to 46 % of the arm; whip 0.040 → 0.026 R; a pointed tip |
| The filling valve's flange: a round bolted plate about 70 mm across on the front half-shell between two brackets, some 25° ahead of the strap | a disc of angular radius 0.12 at 25° ahead, six bolt heads; the test connector's plate on the rear half-shell, 90° round |
| Finish: mirror-polished, unmarked | printed as the poster prints chrome: flat tone bands, a halftone shade, a hard specular, the beam and the Earth (a cobalt crescent, lower right) mirrored in it, a navy keyline and a red off-register plate. No emblem: the hammer and sickle of the first pass was not on the real satellite |

Not modelled: the outer screen's edge (invisible at this size), the cable
fittings in the sockets, the heel contact.

## Checking it

`SPUTNIK_SEED=7 cargo run --release --example sputnik_shot -- 2560x1440 /tmp/s 0 400 1500`
in `../spinning_globe` writes stills (PPM) to compare against the photographs.
