# Safety

**LabForge is an experimental, hobbyist/educational tool. It is not a certified
laboratory instrument, and the example procedures are illustrations, not
validated methods.** Read this before running anything on hardware.

## The core reality

Automating a reaction does not make the chemistry safer — it removes the human
who would notice something going wrong. Every hazard of the underlying
chemistry (toxicity, flammability, corrosivity, exotherms, gas evolution,
pressure) is still present, now potentially unattended.

You are responsible for:

- **Only running chemistry you are trained and authorised to run.** If you don't
  understand the reaction, its byproducts, and its failure modes, don't automate
  it.
- **Materials compatibility.** Many solvents attack PLA/PETG, silicone tubing,
  and adhesives. Confirm every wetted material against your reagents. Printed
  parts in this repo are *not* meant to contact reagents — only tubing and
  syringes are.
- **Ventilation & containment.** Fume extraction, secondary containment, and
  compatible PPE appropriate to the reagents.
- **Thermal & electrical safety.** The heater module is the highest-risk part.
  Use an **independent thermal cutoff** (thermal fuse / over-temp switch) in
  addition to the firmware limit. Treat mains-powered heating with appropriate
  respect and isolation.
- **Never leave a hazardous run unattended.**

## What the software does (and does not) guarantee

Guardrails present in LabForge:

- The compiler refuses to run a procedure containing XDL steps it cannot map to
  a safe device action (no silent skipping of chemistry).
- A dry volume model rejects vessel overflow and drawing from an empty vessel
  *before* any liquid moves.
- Heater setpoints are checked against a per-heater maximum at compile time,
  again in the device layer, and clamped in the firmware control loop.
- `labforge run` refuses to drive hardware without an explicit `--i-understand`
  acknowledgement.
- The firmware supports a hardware e-stop input and halts all actuators on any
  runtime error (`STOP`).

These are **backstops, not guarantees.** They cannot know your reagents are
compatible, your tubing is rated, your fume hood is on, or your reaction is
safe. Software cannot make an unsafe experiment safe.

## Before every hardware run — checklist

- [ ] I understand this reaction and its hazards, and I am authorised to run it.
- [ ] Reagents, concentrations and volumes in the XDL match what's physically loaded.
- [ ] Tubing, fittings and any wetted parts are compatible with these reagents.
- [ ] Fume extraction / ventilation is on; PPE is on; spill containment is ready.
- [ ] The heater (if used) has an independent over-temp cutoff.
- [ ] The e-stop is reachable and tested.
- [ ] I ran `labforge simulate` and reviewed the compiled operations.
- [ ] I will stay with the run.

## Scope

LabForge is intended for education, hobby, and low-hazard demonstration
chemistry. It is not designed or validated for hazardous synthesis, scale-up,
clinical, food, or any regulated use. Comply with all local laws and
institutional policies.
