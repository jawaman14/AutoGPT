# Bill of Materials

Approximate, per-module. Prices are rough (2026, hobby quantities) to set
expectations, not a quote. Quantities scale with how many pumps you build.

## Controller (one per rig)

| Item | Qty | Notes |
|------|-----|-------|
| ESP32 DevKit v1 (or WROOM-32) | 1 | The controller board |
| A4988 or DRV8825 stepper driver | 1 per pump | Set current limit before use |
| Buck converter (12→5 V, 3 A) | 1 | If powering logic from the 12 V rail |
| 12 V / 5 A power supply | 1 | Size up if driving a heater |
| Protoboard / CNC-shield clone | 1 | CNC shields map neatly to the pin plan |
| Dupont wire, screw terminals | — | |
| **Optional** e-stop button (NC) | 1 | Wired to `ESTOP_PIN`, active-low |

## Syringe pump (per channel)

| Item | Qty | Notes |
|------|-----|-------|
| Printed motor-end, syringe-end, carriage | 1 each | `scad/syringe_pump.scad` |
| NEMA 17 stepper (e.g. 17HS4401) | 1 | |
| T8 leadscrew + brass flange nut | 1 | 8 mm, 2 mm pitch typical |
| 8 mm smooth guide rod | 2 | Length ≈ barrel travel + 60 mm |
| LM8UU linear bearing (optional) | 2 | Or print-in-place rod bores |
| Luer-lock syringe (10 mL) | 1 | BD-style; match `syringe_barrel_d` |
| M3 screws / nuts assortment | — | |
| Silicone / PTFE tubing + Luer fittings | — | **Check solvent compatibility** |

## Peristaltic pump (drain / recirculation)

| Item | Qty | Notes |
|------|-----|-------|
| Printed housing, rotor, lid | 1 each | `scad/peristaltic_pump.scad` |
| NEMA 17 stepper | 1 | |
| 623ZZ bearing | 3 | Rollers |
| M3 shoulder screw / pin | 3 | Roller axles |
| Silicone tubing 3×5 mm | — | The only wetted part |

## Stirrer

| Item | Qty | Notes |
|------|-----|-------|
| Small DC motor or 40 mm fan | 1 | Spins magnets under the vessel |
| Neodymium magnets | 2 | On the motor; PTFE stir bar in vessel |
| Logic-level MOSFET (e.g. IRLZ44N) | 1 | Driven from a stirrer PWM pin |
| Flyback diode | 1 | Across an inductive load |

## Heater (optional, **highest-risk module**)

| Item | Qty | Notes |
|------|-----|-------|
| PTC heating element or heater cartridge | 1 | Rated for your enclosure |
| Logic-level MOSFET or solid-state relay | 1 | On a heater PWM pin |
| 100 kΩ NTC thermistor (or DS18B20) | 1 | Feedback; match `config.h` |
| 100 kΩ series resistor | 1 | For the NTC divider |
| Thermal fuse | 1 | **Independent** over-temp cutoff |

> Do not build the heater module until you have read
> [`../docs/safety.md`](../docs/safety.md). Always include an independent
> thermal cutoff; firmware limits are not sufficient on their own.
