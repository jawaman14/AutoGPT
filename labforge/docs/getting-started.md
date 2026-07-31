# Getting started

## 1. Install (simulation, no hardware)

```bash
cd labforge
pip install -e .          # core, zero required dependencies
```

Optional extras:

```bash
pip install -e ".[serial]"   # real ESP32 over USB (pyserial)
pip install -e ".[mqtt]"     # real ESP32 over WiFi (paho-mqtt)
pip install -e ".[chem]"     # RDKit-backed molar mass / stoichiometry
pip install -e ".[dev]"      # pytest for the test suite
```

## 2. Look at a procedure

```bash
labforge describe examples/protocols/simple_dilution.xdl
```

## 3. Validate it against a rig (still no hardware)

`validate` parses the XDL, compiles it against a hardware graph, and runs the
static safety checks (routing, volume overflow/underflow, heater limits) without
executing anything.

```bash
labforge validate examples/protocols/simple_dilution.xdl \
    --graph examples/graphs/demo_rig.json
```

## 4. Simulate execution

```bash
labforge simulate examples/protocols/simple_dilution.xdl \
    --graph examples/graphs/demo_rig.json --verbose
```

`--verbose` shows the actual line-protocol traffic to the simulated controller.
Or run the bundled script that does both example procedures:

```bash
python examples/run_simulation.py
```

## 5. Describe your own rig

Copy `examples/graphs/demo_rig.json` and edit it to match your hardware — see
[the hardware graph reference](protocol-authoring.md#hardware-graph). List it
back with:

```bash
labforge devices --graph my_rig.json
```

## 6. Run on hardware

1. Build a pump (see [`../hardware/`](../hardware/)) and flash the firmware
   (see [`../firmware/esp32/`](../firmware/esp32/)).
2. Read [`safety.md`](safety.md) and complete the pre-run checklist.
3. Run:

   ```bash
   labforge run my_procedure.xdl --graph my_rig.json \
       --port /dev/ttyUSB0 --i-understand
   ```

   Without `--i-understand`, LabForge prints the plan and refuses to move
   hardware.

## Using it as a library

```python
from labforge import parse_xdl_file, HardwareGraph
from labforge.executor import compile_protocol, execute
from labforge.devices import build_devices

protocol = parse_xdl_file("my_procedure.xdl")
graph = HardwareGraph.load("my_rig.json")
compiled = compile_protocol(protocol, graph)      # validates + plans

bundle = build_devices(graph, simulate=True)       # or simulate=False
result = execute(compiled, bundle, time_scale=0.0, logger=print)
print(result.final_volumes)
```
