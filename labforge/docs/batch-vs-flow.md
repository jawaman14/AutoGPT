# Batch vs flow synthesis in LabForge

LabForge can express a reaction as either a **batch** operation (charge a
vessel, mix, heat, hold) or a **continuous-flow** operation (pump feeds through
a temperature-controlled reactor at set rates). This page explains the model and
how to choose. Print the same comparison from the CLI:

```bash
labforge methods                       # the comparison table
labforge methods --holdup 10 --flow 0.5  # + a residence-time estimate
```

## The trade-offs

| | Batch | Flow |
|---|---|---|
| Heat transfer | surface/volume limited; hot spots at scale | excellent; fast thermal response |
| Mixing | stirring-dependent | fast, reproducible in tees/mixers |
| Residence control | "leave it until done" | **precise**: set by reactor volume ÷ flow |
| Scale-up | bigger vessel changes behaviour | run longer / number-up channels |
| Hazard inventory | whole charge reactive at once | small reactive volume at any instant |
| Solids/slurries | easy | clogging risk |

**Rules of thumb:** batch for slow reactions, solids/precipitations, and
one-pot exploration; flow for fast/exothermic steps, hazardous intermediates,
tight residence/temperature control, and packed-bed immobilised
catalysts/enzymes or continuous hydrogenation.

## How flow is modelled

A flow reactor is declared in the hardware graph as a **pass-through** vessel:

```json
{ "id": "flow_reactor", "kind": "flow_reactor", "max_volume_ml": 10,
  "passthrough": true, "outlet": "product" }
```

- `max_volume_ml` is the reactor's **internal holdup** — used for residence
  time, not accumulation.
- `passthrough: true` means it does **not** accumulate liquid; whatever is
  pumped in is forwarded to `outlet` for volume accounting (so overflow is
  checked at the *collection* vessel, where it physically matters).

Feeds are ordinary `Add`/`Transfer` steps carrying a `flow_rate`:

```xml
<HeatChill vessel="flow_reactor" temp="45 C"/>
<Add reagent="serine_feed" vessel="flow_reactor" volume="10 mL" flow_rate="0.25 mL/min"/>
<Add reagent="hydroxyindole_feed" vessel="flow_reactor" volume="10 mL" flow_rate="0.25 mL/min"/>
```

`flow_rate` sets the pump's delivery rate (and the derived delivery time =
volume ÷ flow rate). When a feed targets a flow reactor, the compiler emits a
**residence-time note**:

```
NOTE: Add serine_feed->flow_reactor: flow through 'flow_reactor' at
      0.25 mL/min, holdup 10 mL => residence ~40.0 min
```

## Residence time

```
residence_time = reactor holdup volume / total volumetric flow rate
```

The note above is computed **per feed stream**. When two feeds run concurrently
(as they do physically in a flow rig), the *total* flow is their sum, so the
real residence time is correspondingly shorter — e.g. two 0.25 mL/min feeds into
a 10 mL reactor give 10 mL ÷ 0.5 mL/min = **20 min**. Use `labforge methods
--holdup 10 --flow 0.5` for the combined figure, and size your target residence
by adjusting flow rate or reactor volume (`flow_rate_for_residence` in
`labforge.synthesis.methods`).

## Limits of the model

LabForge is a planning/'control aid, not a kinetics or CFD simulator. It tracks
volumes, rates, residence time, and temperature setpoints — it does **not**
predict conversion, selectivity, mixing efficiency, or pressure drop. Treat its
output as a plan to validate on the bench, under supervision, per
[`safety.md`](safety.md).
