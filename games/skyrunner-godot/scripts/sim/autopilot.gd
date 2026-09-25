class_name Autopilot
extends RefCounted
## Simple two-axis autopilot: heading hold (through bank) and altitude hold.
##
## Cascade: altitude error -> target vertical speed -> target flight-path angle
## -> target pitch (integrator learns the trim pitch) -> elevator (PD + I).
## Heading error -> target bank -> aileron (PD). It exists so a solo pilot can
## leave the controls and go aft to kick bales.

var engaged := false
var alt_target := 0.0  ## m MSL
var hdg_target := 0.0
var pitch_base := 2.0  ## learned trim pitch, deg
var elev_i := 0.0
var min_ias_kts := 0.0  ## below this, give up altitude to keep flying speed


func engage(s: FlightModel.FlightState, elevator_now := 0.0) -> void:
	engaged = true
	alt_target = s.alt
	hdg_target = s.heading
	pitch_base = s.pitch
	elev_i = elevator_now


func disengage() -> void:
	engaged = false


func update(dt: float, s: FlightModel.FlightState, c: FlightModel.Controls) -> FlightModel.Controls:
	if not engaged or s.on_ground:
		return c
	# lateral
	var bank_t := Py.clamp(Py.wrap180(hdg_target - s.heading) * 1.2, -18.0, 18.0)
	c.aileron = Py.clamp(0.04 * (bank_t - s.roll) - 0.012 * s.p_dps, -0.6, 0.6)
	c.rudder = 0.0
	# vertical
	var vs_t := Py.clamp((alt_target - s.alt) * 18.0, -600.0, 600.0)  # fpm
	var tas := maxf(20.0, s.ias_kts * 0.514444)
	var gamma_t := Py.degrees(atan2(vs_t * 0.00508, tas))
	pitch_base = Py.clamp(pitch_base + (vs_t - s.vs_fpm) * 0.0006 * dt, -6.0, 12.0)
	var pitch_t := Py.clamp(pitch_base + gamma_t, -8.0, 14.0)
	if s.ias_kts < min_ias_kts:
		pitch_t = minf(pitch_t, s.pitch - (min_ias_kts - s.ias_kts) * 0.6)
		pitch_base = minf(pitch_base, pitch_t)
	var err := pitch_t - s.pitch
	elev_i = Py.clamp(elev_i - err * 0.02 * dt, -0.6, 0.6)
	c.elevator = Py.clamp(-0.07 * err + 0.03 * s.q_dps + elev_i, -0.8, 0.8)
	return c
