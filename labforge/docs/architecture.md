# Architecture

LabForge is a pipeline from a hardware-independent chemistry description down to
stepper pulses, with a hard safety/validation boundary in the middle.

```
  XDL file (.xdl)                     hardware graph (.json)
        │                                     │
        ▼                                     │
  ┌───────────────┐                           │
  │ protocol/      │  parse_xdl()             │
  │  xdl_parser    │───────────► Protocol     │
  │  steps, model  │             (Step[])     │
  └───────────────┘                           │
        │                                     ▼
        │                             ┌────────────────┐
        └────────────────────────────► graph/          │
                                      │  HardwareGraph  │
                                      └────────────────┘
                                              │
                                              ▼
                                     ┌──────────────────┐
                                     │ executor/compiler │  compile_protocol()
                                     │  - resolve wiring │
                                     │  - volume model   │  ► CompiledRun (Operation[])
                                     │  - safety checks  │
                                     └──────────────────┘
                                              │
                                              ▼
                                     ┌──────────────────┐
                                     │ executor/runtime  │  execute()
                                     └──────────────────┘
                                              │
                     ┌────────────────────────┼────────────────────────┐
                     ▼                         ▼                         ▼
             devices/simulator        devices/esp32 (serial)   devices/esp32 (mqtt)
                     │                         │                         │
                     └───────── transport/protocol (line protocol) ──────┘
                                              │
                                              ▼
                                      ESP32 firmware
                                  (pumps / stir / heat / temp)
```

## Layers

| Layer | Package | Responsibility |
|-------|---------|----------------|
| Protocol | `labforge.protocol` | Parse XDL into typed `Step` objects (incl. `flow_rate`); keep unsupported steps explicit. |
| Chemistry | `labforge.chemistry` | Optional RDKit-backed molar mass / stoichiometry. Degrades gracefully. |
| Synthesis | `labforge.synthesis` | Batch-vs-flow method profiles + residence-time maths. |
| Retro | `labforge.retro` | Curated retrosynthesis trees, route enumeration, route → XDL export. |
| Graph | `labforge.graph` | Declarative wiring: pumps (source→dest), stirrers, heaters, vessels. |
| Compiler | `labforge.executor.compiler` | Resolve each step to `Operation`s; run a dry volume model; reject unsafe/unmappable procedures. |
| Runtime | `labforge.executor.runtime` | Execute operations; track live volumes; emergency-stop on any error. |
| Transport | `labforge.transport` | The ASCII line protocol (host ⇄ controller). |
| Devices | `labforge.devices` | Actuator wrappers + transports (simulator / serial / MQTT). |
| Firmware | `firmware/esp32` | Same protocol on the metal: steppers, PWM stir/heat, thermistor. |
| Hardware | `hardware/` | Parametric OpenSCAD parts + BOM + wiring. |

## Design principles

1. **The compiler is the safety boundary.** Anything it can't map to a safe
   device action — an unsupported XDL step, a missing pump route, an overflow —
   is a hard error, never a silent skip. If it compiles, every step has a home.
2. **Simulation is first-class.** The same code path runs against
   `SimulatedTransport`, so a procedure is fully validated before hardware.
3. **Hardware independence, both ends.** XDL keeps procedures portable across
   rigs; the hardware graph keeps the code portable across wiring. Neither the
   procedure nor the executor hard-codes pins.
4. **Zero required dependencies for the core.** Serial, MQTT and RDKit are
   optional extras so the suite installs and simulates anywhere.
