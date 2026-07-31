# Wiring

The default pin map in [`../firmware/esp32/include/config.h`](../firmware/esp32/include/config.h)
targets an ESP32 DevKit with step/dir stepper drivers and MOSFET outputs. Edit
`config.h` if you deviate, and keep the **channel numbers** consistent with the
`channel` fields in your hardware-graph JSON.

## Block diagram

```
                         +---------------------+
   USB (serial) <------> |      ESP32 DevKit   |
                         |                     |
   STEP/DIR x5  -------> | GPIO -> A4988/DRV8825 -> NEMA 17 (pump 0..4)
   STIR PWM     -------> | GPIO23 -> MOSFET ------> stirrer motor
   HEAT PWM     -------> | GPIO19 -> MOSFET/SSR ---> heating element
   TEMP ADC     <------- | GPIO34 <- NTC divider <- thermistor
   ESTOP (opt)  <------- | GPIO?? <- NC button (active-low)
                         +---------------------+
```

## Default pin assignments

| Function | Channel | ESP32 GPIO | Driver / part |
|----------|:------:|:----------:|---------------|
| Pump STEP | 0 | 13 | A4988/DRV8825 |
| Pump DIR  | 0 | 12 | |
| Pump STEP | 1 | 14 | |
| Pump DIR  | 1 | 27 | |
| Pump STEP | 2 | 25 | |
| Pump DIR  | 2 | 33 | |
| Pump STEP | 3 | 26 | |
| Pump DIR  | 3 | 32 | |
| Pump STEP | 4 | 17 | |
| Pump DIR  | 4 | 16 | |
| Pump ENABLE (shared) | — | 4 | active-low |
| Stirrer PWM | 0 | 23 | logic-level MOSFET |
| Heater output | 0 | 19 | MOSFET or SSR |
| Thermistor ADC | 0 | 34 | 100 kΩ NTC + 100 kΩ series to 3.3 V |

Notes:

- GPIO34/35/36/39 are **input-only** — good for the ADC/thermistor, not for
  outputs.
- Give the steppers their own 12 V supply; don't run motor current through the
  ESP32's 5 V regulator.
- Set the A4988/DRV8825 current limit (Vref) **before** attaching a motor.
- Common-ground everything (ESP32 GND ↔ driver GND ↔ PSU GND).

## Thermistor divider

```
3.3V ── 100kΩ ──┬── GPIO34 (ADC)
                │
             NTC 100kΩ
                │
               GND
```

The beta-model constants in `config.h` (`THERM_*`) must match your thermistor.
Calibrate against a reference thermometer before trusting the readout for any
reaction that cares about temperature.
