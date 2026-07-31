# LabForge ESP32 firmware

Firmware for the controller board that drives the pumps, stirrer and heater.
It speaks the [LabForge line protocol](../../software/labforge/transport/protocol.py)
over USB-serial at 115200 baud, so the Python host can run any compiled XDL
procedure against it.

## Build & flash

Install [PlatformIO](https://platformio.org/) (CLI or the VS Code extension),
then:

```bash
cd firmware/esp32
pio run                 # compile
pio run -t upload       # flash over USB
pio device monitor      # watch/serial-debug at 115200 baud
```

You can talk to it by hand from the serial monitor:

```
INFO            -> OK labforge-esp32 0.1.0
PING            -> OK PONG
PUMP 0 1600 800 -> OK          (move pump 0 by +1600 steps at 800 steps/s)
STIR 0 300      -> OK          (stir channel 0 at ~300 RPM)
HEAT 0 40       -> OK          (heat channel 0 to 40 C, closed loop)
TEMP 0          -> OK 24.63
STOP            -> OK          (halt everything)
```

## Wiring

Pin assignments and calibration live in [`include/config.h`](include/config.h).
Edit that file to match your board, then re-flash. The channel numbers there
must line up with the `channel` fields in your hardware-graph JSON. A default
map for an ESP32 DevKit + A4988/DRV8825 stepper drivers + MOSFET outputs is
provided. See [`../../hardware/wiring.md`](../../hardware/wiring.md) for the
full diagram and bill of materials.

## ESP32 Arduino core note

The PWM (stirrer) code uses the **2.x** core LEDC API
(`ledcSetup`/`ledcAttachPin`/`ledcWrite(channel, duty)`), which is what the
pinned `platform = espressif32` toolchain installs. If you upgrade to core
**3.x**, change those three calls to the newer `ledcAttach(pin, freq, res)` /
`ledcWrite(pin, duty)` form.

## Safety

The firmware enforces `HEATER_MAX_C` in the control loop and supports an
optional hardware e-stop input (`ESTOP_PIN`) that halts all actuators. These are
backstops, not a substitute for supervision — see
[`../../docs/safety.md`](../../docs/safety.md).
