// LabForge ESP32 controller — pin map and calibration.
//
// Edit this file to match YOUR wiring, then re-flash. Channels here line up
// with the "channel" fields in your LabForge hardware graph JSON:
//   pump channel N  -> PUMP_STEP_PINS[N] / PUMP_DIR_PINS[N]
//   stir channel N  -> STIR_PINS[N]
//   heat channel N  -> HEATER_PINS[N]
//   temp channel N  -> THERMISTOR_PINS[N]
//
// The default map targets a common "ESP32 DevKit + A4988/DRV8825 stepper
// drivers + MOSFET outputs" build. Pins are examples — verify against your
// board before connecting anything to mains or heaters.

#pragma once

// ----------------------------------------------------------------- serial
static const unsigned long SERIAL_BAUD = 115200;

// ------------------------------------------------------------------ pumps
// Stepper-driven syringe / peristaltic pumps via STEP/DIR/EN driver boards.
#define NUM_PUMPS 5

static const int PUMP_STEP_PINS[NUM_PUMPS] = {13, 14, 25, 26, 17};
static const int PUMP_DIR_PINS[NUM_PUMPS]  = {12, 27, 33, 32, 16};
// One shared enable line is common on CNC-shield style wiring; set per-pump
// if yours differ. -1 means "no enable pin".
static const int PUMP_EN_PINS[NUM_PUMPS]   = {4, 4, 4, 4, 4};
// Optional homing endstops (active-low). -1 disables homing for that pump.
static const int PUMP_ENDSTOP_PINS[NUM_PUMPS] = {-1, -1, -1, -1, -1};

// Default motion limits (steps/second). The host also sends a per-move rate.
static const float PUMP_MAX_SPS = 4000.0f;
static const float PUMP_ACCEL   = 2000.0f;

// ---------------------------------------------------------------- stirrers
// PWM outputs to a MOSFET driving a small DC motor / fan under the magnetic
// stirrer plate. RPM is mapped linearly onto PWM duty (approximate).
#define NUM_STIRRERS 1
static const int STIR_PINS[NUM_STIRRERS] = {23};
static const float STIR_MAX_RPM = 1500.0f;   // RPM that corresponds to full duty

// ----------------------------------------------------------------- heaters
// PWM/relay outputs to a heating element, closed-loop against a thermistor.
// SAFETY: keep HEATER_MAX_C conservative for your materials and glassware.
#define NUM_HEATERS 1
static const int HEATER_PINS[NUM_HEATERS]     = {19};
static const int THERMISTOR_PINS[NUM_HEATERS] = {34};  // ADC1 channel
static const float HEATER_MAX_C = 120.0f;
static const float HEATER_HYSTERESIS_C = 1.0f;         // bang-bang deadband

// NTC thermistor (beta model). Defaults: 100k NTC, beta 3950, 100k series
// resistor to 3.3V. Adjust for your part.
static const float THERM_NOMINAL_R   = 100000.0f;  // resistance at 25 C
static const float THERM_NOMINAL_C   = 25.0f;
static const float THERM_BETA        = 3950.0f;
static const float THERM_SERIES_R    = 100000.0f;
static const float ADC_MAX           = 4095.0f;    // 12-bit ADC

// A dedicated hardware STOP/estop input (active-low) that halts everything.
// -1 disables it (software STOP over serial still works).
static const int ESTOP_PIN = -1;
