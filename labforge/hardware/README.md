# Hardware

Parametric, 3D-printable mechanics for a LabForge rig. All models are OpenSCAD
so you can change a syringe diameter or rod spacing and re-export.

## Parts

| File | What it is |
|------|------------|
| `scad/common.scad` | Shared helpers (screw holes, NEMA 17 pattern, clamps) |
| `scad/syringe_pump.scad` | Leadscrew syringe pump (motor end / carriage / syringe end) |
| `scad/peristaltic_pump.scad` | 3-roller peristaltic pump for the drain line |
| `scad/vial_rack.scad` | Gridded reagent/vessel rack |

## Exporting STLs

Install [OpenSCAD](https://openscad.org/), then export each part by setting the
`part` variable:

```bash
cd hardware/scad
openscad -D 'part="motor"'    -o motor_end.stl    syringe_pump.scad
openscad -D 'part="carriage"' -o carriage.stl     syringe_pump.scad
openscad -D 'part="syringe"'  -o syringe_end.stl  syringe_pump.scad
openscad -D 'part="housing"'  -o perist_housing.stl peristaltic_pump.scad
openscad -D 'part="rotor"'    -o perist_rotor.stl   peristaltic_pump.scad
openscad -D 'rows=3' -D 'cols=4' -o rack.stl vial_rack.scad
```

Open a `.scad` file with no `-D` (or `part="all"`) to preview all sub-parts laid
out side by side.

## Printing notes

- **Material:** PETG is a good default for structural parts (stiffer, more
  solvent-resistant than PLA). **Nothing printed here should contact reagents** —
  only tubing and syringes are wetted. Choose tubing rated for your solvents.
- **Strength:** ≥ 40% infill and 4 perimeters for the pump blocks and carriage;
  they take the plunger thrust.
- **Tolerances:** rod/leadscrew bores include clearance, but printers vary —
  print a `common.scad` test hole first and adjust `M3_CLEAR` / bore fits.

## Bill of materials & wiring

See [`bom.md`](bom.md) and [`wiring.md`](wiring.md).

## Provenance

These are clean-room parametric designs, not copies, but they follow the
well-trodden pattern of open syringe/peristaltic pumps (Poseidon, FINDUS,
open-source peristaltic pumps). Treat them as a **starting reference** to adapt
to your parts, and verify fit before a long unattended run. See
[`../docs/prior-art.md`](../docs/prior-art.md).
