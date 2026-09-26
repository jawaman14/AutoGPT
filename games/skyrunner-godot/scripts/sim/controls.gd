class_name ControlMapper
extends RefCounted
## Turns digital key presses (and optional analog axes) into smooth control
## surface commands. Keyboard flying is only tolerable with rate limiting and
## auto-centring; the mouse-yoke mode gives proportional control.

const FLAP_NOTCHES := [0.0, 0.33, 0.66, 1.0]


## Everything the front end collected this frame.
class InputFrame:
	var held := {}  ## logical actions currently held (set: action -> true)
	var pressed := {}  ## one-shot actions this frame
	var stick = null  ## [roll, pitch] -1..1, pitch +1 = pull
	var rudder_axis = null
	var throttle_axis = null


var controls := FlightModel.Controls.new()
var flap_index := 0
var roll_authority := 0.65
var pitch_authority := 0.6


static func _approach(cur: float, target: float, rate: float, dt: float) -> float:
	var step := rate * dt
	if absf(target - cur) <= step:
		return target
	return cur + step if target > cur else cur - step


static func _b(d: Dictionary, k: String) -> int:
	return 1 if d.has(k) else 0


func reset(throttle := 0.0) -> void:
	controls = FlightModel.Controls.make({"throttle": throttle})
	flap_index = 0


func update(dt: float, inp: InputFrame) -> FlightModel.Controls:
	var c := controls
	var h := inp.held
	# roll / pitch
	if inp.stick != null:
		c.aileron = inp.stick[0]
		c.elevator = -inp.stick[1]
	else:
		var roll_t: float = (_b(h, "roll_right") - _b(h, "roll_left")) * roll_authority
		var pitch_t: float = (_b(h, "pitch_down") - _b(h, "pitch_up")) * pitch_authority
		c.aileron = _approach(c.aileron, roll_t, 2.5 if roll_t else 4.0, dt)
		c.elevator = _approach(c.elevator, pitch_t, 2.0 if pitch_t else 3.0, dt)
	# rudder
	if inp.rudder_axis != null:
		c.rudder = inp.rudder_axis
	else:
		var rud_t := _b(h, "yaw_right") - _b(h, "yaw_left")
		c.rudder = _approach(c.rudder, float(rud_t), 3.0 if rud_t else 4.0, dt)
	# throttle
	if inp.throttle_axis != null:
		c.throttle = inp.throttle_axis
	else:
		c.throttle += (_b(h, "throttle_up") - _b(h, "throttle_down")) * 0.6 * dt
	if inp.pressed.has("throttle_cut"):
		c.throttle = 0.0
	if inp.pressed.has("throttle_full"):
		c.throttle = 1.0
	c.throttle = minf(1.0, maxf(0.0, c.throttle))
	# trim
	c.pitch_trim += (_b(h, "trim_up") - _b(h, "trim_down")) * -0.35 * dt
	c.pitch_trim = minf(1.0, maxf(-1.0, c.pitch_trim))
	# flaps
	if inp.pressed.has("flaps_down"):
		flap_index = mini(FLAP_NOTCHES.size() - 1, flap_index + 1)
	if inp.pressed.has("flaps_up"):
		flap_index = maxi(0, flap_index - 1)
	c.flaps = FLAP_NOTCHES[flap_index]
	c.brake = 1.0 if h.has("brake") else 0.0
	return c
