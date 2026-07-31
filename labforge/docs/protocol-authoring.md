# Authoring procedures & rigs

A LabForge run needs two files: a **procedure** (XDL) describing *what* to do,
and a **hardware graph** (JSON) describing *what's wired up*. Keeping them
separate is what makes a procedure portable between rigs.

## The procedure: XDL

LabForge reads the common XDL structure:

```xml
<Synthesis name="my_procedure">
  <Hardware>
    <Component id="reactor" type="reactor"/>
  </Hardware>
  <Reagents>
    <Reagent id="water" name="water" smiles="O"/>
  </Reagents>
  <Procedure>
    <Add reagent="water" vessel="reactor" volume="10 mL"/>
    ...
  </Procedure>
</Synthesis>
```

A wrapping `<XDL>` element and `<Prep>/<Reaction>/<Workup>` grouping inside
`<Procedure>` are also accepted.

### Supported steps

| Step | Attributes | Meaning |
|------|-----------|---------|
| `Add` | `reagent`, `vessel`, `volume`, `time?`, `stir?` | Pump a reagent into a vessel. |
| `Transfer` | `from_vessel`, `to_vessel`, `volume` (or `"all"`), `time?` | Move liquid between vessels. |
| `Stir` | `vessel`, `stir_speed?`, `time?` | Stir (for a fixed time, then stop, if `time` given). |
| `StopStir` | `vessel` | Stop stirring. |
| `HeatChill` | `vessel`, `temp`, `time?`, `stir?` | Bring a vessel to a temperature and optionally hold. |
| `Wait` | `time` | Pause. |
| `CleanVessel` | `vessel`, `solvent`, `volume`, `repeats?` | Rinse a vessel to waste. |
| `Comment` | `comment` | Annotation carried into the log. |

Any other XDL tag (e.g. `Filter`, `Evaporate`, `Distill`) parses but is marked
**unsupported**, and compilation fails rather than silently skipping it.

### Units

Values carry human units and are parsed strictly (a missing unit is an error):

- volume: `mL`, `L`, `uL`, `cL`, `dL`
- time: `s`, `min`, `h`, `d`
- temperature: `C` / `°C`, `K`, `F`
- stir speed: `RPM`

## The hardware graph: JSON

```json
{
  "name": "my_rig",
  "controllers": [
    { "id": "esp32-0", "transport": "serial", "port": "/dev/ttyUSB0" }
  ],
  "vessels": [
    { "id": "reactor", "max_volume_ml": 50, "initial_volume_ml": 0 },
    { "id": "waste", "max_volume_ml": 1000 }
  ],
  "reagents": [
    { "id": "water", "source": "stock_water" }
  ],
  "pumps": [
    { "id": "p_water", "kind": "syringe", "controller": "esp32-0", "channel": 0,
      "source": "stock_water", "dest": "reactor",
      "syringe_volume_ml": 25, "steps_per_ml": 1600, "max_rate_ml_s": 1.0 }
  ],
  "stirrers": [
    { "id": "s0", "controller": "esp32-0", "channel": 0, "vessel": "reactor" }
  ],
  "heaters": [
    { "id": "h0", "controller": "esp32-0", "channel": 0, "vessel": "reactor",
      "sensor_channel": 0, "max_temp_c": 120 }
  ]
}
```

Key ideas:

- **A pump is a fixed `source → dest` route.** This mirrors how small rigs are
  actually tubed. `Add water to reactor` resolves to "the pump whose source is
  the water stock and whose dest is the reactor". If no such pump exists,
  compilation fails with a clear message — add the pump (or a route) to the
  graph.
- **`reagents` maps a reagent id to the node its stock lives on.** If omitted,
  the reagent id is used as the source node directly.
- **`channel` numbers must match the firmware** `config.h` pin arrays.
- **`steps_per_ml` is your calibration.** Measure it: dispense a known number of
  steps, weigh/measure the volume, divide.

## Calibrating `steps_per_ml`

For a leadscrew syringe pump:

```
steps_per_ml = (steps_per_rev * microsteps) / (leadscrew_pitch_mm * mm_per_ml)
```

where `mm_per_ml` is how many mm of plunger travel dispenses 1 mL (depends on
the syringe barrel area). Always verify empirically — printer tolerances and
syringe variation dominate.
