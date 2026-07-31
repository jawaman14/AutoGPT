// LabForge ESP32 controller firmware.
//
// Implements the LabForge line protocol over USB-serial. One command per line,
// space-separated; every command gets exactly one "OK[...]" or "ERR ..." reply.
//
//   PING                          -> OK PONG
//   INFO                          -> OK labforge-esp32 <version>
//   PUMP <ch> <steps> <rate_pps>  -> OK          (signed steps; + = dispense)
//   STIR <ch> <rpm>               -> OK          (rpm 0 stops)
//   HEAT <ch> <temp_c|OFF>        -> OK
//   TEMP <ch>                     -> OK <celsius>
//   HOME <ch>                     -> OK | ERR no endstop
//   STOP                          -> OK          (halt everything)
//
// This mirrors software/labforge/transport/protocol.py exactly.
//
// NOTE on ESP32 Arduino core: the LEDC PWM calls below use the 2.x API
// (ledcSetup/ledcAttachPin/ledcWrite). If you build against core 3.x, switch to
// ledcAttach()/ledcWrite(pin,...). See README.md.

#include <Arduino.h>
#include <AccelStepper.h>
#include <math.h>

#include "config.h"

#ifndef LABFORGE_FW_VERSION
#define LABFORGE_FW_VERSION "0.0.0"
#endif

// --------------------------------------------------------------- actuators
static AccelStepper *pumps[NUM_PUMPS];

// LEDC PWM: stirrers on channels 0..NUM_STIRRERS-1.
static const int PWM_FREQ = 20000;   // 20 kHz: inaudible
static const int PWM_RES  = 8;       // 8-bit duty (0..255)

// Heater control state.
static bool  heaterOn[NUM_HEATERS];
static float heaterSetpoint[NUM_HEATERS];

// ------------------------------------------------------------------ serial
static String lineBuf;

// ----------------------------------------------------------------- helpers
static void reply(const String &msg) { Serial.println(msg); }
static void replyOk() { Serial.println("OK"); }
static void replyErr(const String &why) { Serial.println("ERR " + why); }

static bool estopEngaged() {
  if (ESTOP_PIN < 0) return false;
  return digitalRead(ESTOP_PIN) == LOW;  // active-low
}

static void allStop() {
  for (int i = 0; i < NUM_PUMPS; i++) {
    pumps[i]->stop();
    pumps[i]->setCurrentPosition(pumps[i]->currentPosition());
  }
  for (int i = 0; i < NUM_STIRRERS; i++) ledcWrite(i, 0);
  for (int i = 0; i < NUM_HEATERS; i++) {
    heaterOn[i] = false;
    heaterSetpoint[i] = NAN;
    digitalWrite(HEATER_PINS[i], LOW);
  }
}

// Convert a raw NTC-thermistor ADC read to degrees Celsius (beta model).
static float readThermistorC(int idx) {
  int adc = analogRead(THERMISTOR_PINS[idx]);
  if (adc <= 0) return -273.15f;
  float r = THERM_SERIES_R / ((ADC_MAX / (float)adc) - 1.0f);
  float steinhart = r / THERM_NOMINAL_R;
  steinhart = log(steinhart);
  steinhart /= THERM_BETA;
  steinhart += 1.0f / (THERM_NOMINAL_C + 273.15f);
  steinhart = 1.0f / steinhart;
  return steinhart - 273.15f;
}

// Blocking pump move that still honours the hardware e-stop.
static bool movePump(int idx, long steps, float ratePps) {
  AccelStepper *m = pumps[idx];
  float rate = constrain(ratePps, 1.0f, PUMP_MAX_SPS);
  m->setMaxSpeed(rate);
  m->move(steps);
  while (m->distanceToGo() != 0) {
    if (estopEngaged()) {
      m->stop();
      allStop();
      return false;
    }
    m->run();
  }
  return true;
}

static bool homePump(int idx) {
  int endstop = PUMP_ENDSTOP_PINS[idx];
  if (endstop < 0) return false;
  AccelStepper *m = pumps[idx];
  m->setMaxSpeed(PUMP_MAX_SPS * 0.25f);
  // Back off toward the endstop (negative direction) until triggered.
  while (digitalRead(endstop) == HIGH) {
    if (estopEngaged()) { allStop(); return false; }
    m->move(-1);
    m->run();
  }
  m->setCurrentPosition(0);
  return true;
}

// ------------------------------------------------------------- command parse
static int nextToken(const String &s, int from, String &out) {
  while (from < (int)s.length() && s[from] == ' ') from++;
  int end = from;
  while (end < (int)s.length() && s[end] != ' ') end++;
  out = s.substring(from, end);
  return end;
}

static void handleCommand(const String &raw) {
  String line = raw;
  line.trim();
  if (line.length() == 0) return;

  String verb;
  int pos = nextToken(line, 0, verb);
  verb.toUpperCase();

  if (verb == "PING") { reply("OK PONG"); return; }
  if (verb == "INFO") { reply(String("OK labforge-esp32 ") + LABFORGE_FW_VERSION); return; }
  if (verb == "STOP") { allStop(); replyOk(); return; }

  String a1, a2, a3;
  pos = nextToken(line, pos, a1);
  pos = nextToken(line, pos, a2);
  pos = nextToken(line, pos, a3);

  if (verb == "PUMP") {
    int ch = a1.toInt();
    long steps = a2.toInt();
    float rate = a3.toFloat();
    if (ch < 0 || ch >= NUM_PUMPS) { replyErr("bad pump channel"); return; }
    if (rate <= 0) rate = PUMP_MAX_SPS;
    if (!movePump(ch, steps, rate)) { replyErr("estop during move"); return; }
    replyOk();
    return;
  }

  if (verb == "STIR") {
    int ch = a1.toInt();
    float rpm = a2.toFloat();
    if (ch < 0 || ch >= NUM_STIRRERS) { replyErr("bad stir channel"); return; }
    float duty = constrain(rpm / STIR_MAX_RPM, 0.0f, 1.0f) * ((1 << PWM_RES) - 1);
    ledcWrite(ch, (uint32_t)duty);
    replyOk();
    return;
  }

  if (verb == "HEAT") {
    int ch = a1.toInt();
    if (ch < 0 || ch >= NUM_HEATERS) { replyErr("bad heat channel"); return; }
    a2.toUpperCase();
    if (a2 == "OFF") {
      heaterOn[ch] = false;
      heaterSetpoint[ch] = NAN;
      digitalWrite(HEATER_PINS[ch], LOW);
      replyOk();
      return;
    }
    float sp = a2.toFloat();
    if (sp > HEATER_MAX_C) { replyErr("setpoint over max"); return; }
    heaterSetpoint[ch] = sp;
    heaterOn[ch] = true;
    replyOk();
    return;
  }

  if (verb == "TEMP") {
    int ch = a1.toInt();
    if (ch < 0 || ch >= NUM_HEATERS) { replyErr("bad temp channel"); return; }
    reply("OK " + String(readThermistorC(ch), 2));
    return;
  }

  if (verb == "HOME") {
    int ch = a1.toInt();
    if (ch < 0 || ch >= NUM_PUMPS) { replyErr("bad pump channel"); return; }
    if (!homePump(ch)) { replyErr("no endstop"); return; }
    replyOk();
    return;
  }

  replyErr("unknown verb " + verb);
}

// --------------------------------------------------------- heater control loop
static unsigned long lastHeatCtl = 0;
static void heaterControl() {
  if (millis() - lastHeatCtl < 250) return;
  lastHeatCtl = millis();
  for (int i = 0; i < NUM_HEATERS; i++) {
    if (!heaterOn[i] || isnan(heaterSetpoint[i])) {
      digitalWrite(HEATER_PINS[i], LOW);
      continue;
    }
    float t = readThermistorC(i);
    // Bang-bang with hysteresis, hard-clamped to the safety maximum.
    if (t >= HEATER_MAX_C) {
      digitalWrite(HEATER_PINS[i], LOW);
    } else if (t < heaterSetpoint[i] - HEATER_HYSTERESIS_C) {
      digitalWrite(HEATER_PINS[i], HIGH);
    } else if (t > heaterSetpoint[i] + HEATER_HYSTERESIS_C) {
      digitalWrite(HEATER_PINS[i], LOW);
    }
  }
}

// ------------------------------------------------------------------- arduino
void setup() {
  Serial.begin(SERIAL_BAUD);

  for (int i = 0; i < NUM_PUMPS; i++) {
    pumps[i] = new AccelStepper(AccelStepper::DRIVER, PUMP_STEP_PINS[i], PUMP_DIR_PINS[i]);
    pumps[i]->setMaxSpeed(PUMP_MAX_SPS);
    pumps[i]->setAcceleration(PUMP_ACCEL);
    if (PUMP_EN_PINS[i] >= 0) {
      pinMode(PUMP_EN_PINS[i], OUTPUT);
      digitalWrite(PUMP_EN_PINS[i], LOW);  // A4988/DRV8825 enable is active-low
    }
    if (PUMP_ENDSTOP_PINS[i] >= 0) pinMode(PUMP_ENDSTOP_PINS[i], INPUT_PULLUP);
  }

  for (int i = 0; i < NUM_STIRRERS; i++) {
    ledcSetup(i, PWM_FREQ, PWM_RES);
    ledcAttachPin(STIR_PINS[i], i);
    ledcWrite(i, 0);
  }

  for (int i = 0; i < NUM_HEATERS; i++) {
    pinMode(HEATER_PINS[i], OUTPUT);
    digitalWrite(HEATER_PINS[i], LOW);
    heaterOn[i] = false;
    heaterSetpoint[i] = NAN;
  }

  if (ESTOP_PIN >= 0) pinMode(ESTOP_PIN, INPUT_PULLUP);

  analogReadResolution(12);
  Serial.println(String("OK labforge-esp32 ") + LABFORGE_FW_VERSION + " ready");
}

void loop() {
  if (estopEngaged()) allStop();

  while (Serial.available()) {
    char c = (char)Serial.read();
    if (c == '\n' || c == '\r') {
      if (lineBuf.length() > 0) {
        handleCommand(lineBuf);
        lineBuf = "";
      }
    } else if (lineBuf.length() < 128) {
      lineBuf += c;
    }
  }

  heaterControl();
}
