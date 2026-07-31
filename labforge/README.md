# LabForge

**XDL-native, ESP32-driven, 3D-printable lab automation.**

LabForge is an open-source suite for building and running small-scale
chemistry automation. It glues together three layers that are usually
solved in isolation:

1. **A chemistry protocol layer** built on the open
   [XDL (Chemical Description Language)](https://gitlab.com/croningroup/chemputer/xdl)
   standard — procedures are described in hardware-independent, versionable
   XML, the same idea that drives the "chemputer".
2. **A Python orchestrator** that compiles an XDL procedure against a
   *hardware graph* (which vessel connects to which pump/valve) and executes
   it step-by-step — think of it as a miniature, open "chempiler".
3. **Cheap, 3D-printable, ESP32-controlled hardware** — parametric OpenSCAD
   syringe and peristaltic pumps, a stirrer/heater interface, and firmware
   that speaks a tiny line protocol over USB-serial or WiFi/MQTT.

Everything runs **end-to-end in simulation with zero hardware**, so you can
write and validate a procedure on a laptop before you print a single part.

> LabForge does not fork or vendor the Cronin Group's XDL/Chempiler code. It
> implements an independent, MIT-licensed executor for a documented subset of
> the XDL format, so procedures stay portable to the wider ecosystem.

---

## Why this exists

Commercial liquid handlers cost tens of thousands of dollars. The open-hardware
community has already shown you can build capable liquid handling for a few
hundred dollars (FINDUS, Sidekick, OTTO, Poseidon-style syringe pumps). What's
been missing is a clean, standard **protocol → hardware** bridge that a
hobbyist chemist, a teaching lab, or a citizen-science group can actually run.
LabForge is that bridge.

## Repository layout

```
labforge/
├── software/            # Python suite (installable package: `labforge`)
│   ├── labforge/
│   │   ├── protocol/    # XDL parser + step objects
│   │   ├── chemistry/   # reagents, molar mass, stoichiometry (RDKit optional)
│   │   ├── graph/       # hardware connectivity graph
│   │   ├── devices/     # device drivers: simulator, ESP32 serial/MQTT
│   │   ├── transport/   # the line protocol spoken to the ESP32
│   │   ├── executor/    # compiler (XDL -> commands) + runtime scheduler
│   │   └── cli.py       # `labforge` command-line entrypoint
│   └── tests/           # pytest suite (runs with no hardware)
├── firmware/esp32/      # PlatformIO firmware for the controller board
├── hardware/            # OpenSCAD 3D-printable parts + BOM + wiring
├── examples/            # example XDL protocols + a hardware graph
└── docs/                # architecture, hardware, protocol authoring guides
```

## Quick start (simulation, no hardware)

```bash
cd labforge
pip install -e .                   # core install, zero required deps

# Dry-run a procedure against a simulated rig
labforge simulate examples/protocols/simple_dilution.xdl \
    --graph examples/graphs/demo_rig.json

# Or from Python
python examples/run_simulation.py
```

You'll see each XDL step compiled into low-level device commands and a running
log of simulated pump moves, stir/heat actions, and vessel volumes.

## Running on real hardware

1. Print and assemble a pump from [`hardware/`](hardware/) (start with the
   syringe pump). See [`hardware/bom.md`](hardware/bom.md).
2. Flash the ESP32 with the firmware in [`firmware/esp32/`](firmware/esp32/)
   (`pio run -t upload`).
3. Describe your rig as a hardware graph (see
   [`examples/graphs/demo_rig.json`](examples/graphs/demo_rig.json)).
4. Run:
   ```bash
   pip install -e ".[serial]"
   labforge run examples/protocols/simple_dilution.xdl \
       --graph my_rig.json --port /dev/ttyUSB0
   ```

See [`docs/getting-started.md`](docs/getting-started.md) for the full walkthrough.

## ⚠️ Safety

**LabForge is an experimental hobbyist/educational tool, not a certified
laboratory instrument.** Automating chemistry does not remove the hazards of
chemistry. You are responsible for:

- Only running reactions you understand and are trained/authorized to perform.
- Fume extraction, PPE, spill containment, and compatible materials (many
  solvents attack PLA/PETG and silicone tubing).
- Fire/thermal safety around any heating element, and electrical safety around
  mains-powered components.
- Never leaving an unattended run heating, pressurizing, or mixing incompatible
  reagents.

The software includes guardrails (volume limits, an explicit `--i-understand`
gate for real hardware runs, and hard-coded refusal to compile steps it can't
map to safe device actions), but **guardrails are not a substitute for
judgment.** See [`docs/safety.md`](docs/safety.md).

## Prior art & credits

LabForge stands on a lot of open work. See [`docs/prior-art.md`](docs/prior-art.md)
for the projects and papers it builds on (XDL/Chemputer, Opentrons, FINDUS,
Sidekick, Poseidon, EOS/IvoryOS, RDKit).

## License

MIT — see [LICENSE](LICENSE).
