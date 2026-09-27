class_name FlightAxes
extends RefCounted
## Analogue flight controls mapped from any joypad axis on any device: a yoke
## or stick, a throttle quadrant, rudder pedals and toe brakes are often three
## different USB devices, which a gamepad-minded remapper doesn't cover.
##
## Each control is bound to (device name, axis) with invert, deadzone and expo.
## A device is matched by its name, so the binding survives replugging and a
## change of order; "" means the first joypad connected. Unbound controls fall
## back to the keys. With nothing configured it's the gamepad layout the game
## always had: left stick = yoke, right stick X = rudder, triggers = throttle
## (those are key-style actions in ControlsConfig).
##
## Reading goes through `reader` and `pads` Callables, so tests can feed axes
## without hardware.

## control -> "centred" (-1..1) or "lever" (0..1, from an axis that rests at -1)
const CONTROLS := {"roll": "centred", "pitch": "centred", "yaw": "centred", "throttle": "lever", "brake_left": "lever", "brake_right": "lever"}
const LABELS := {"roll": "Roll (ailerons)", "pitch": "Pitch (elevator)", "yaw": "Rudder pedals", "throttle": "Throttle lever",
	"brake_left": "Left toe brake", "brake_right": "Right toe brake"}
## Godot's names for the first axes (SDL's gamepad layout); a joystick's raw axes are just numbers
const AXIS_NAMES := ["left stick X", "left stick Y", "right stick X", "right stick Y", "left trigger", "right trigger"]
const CAPTURE_DELTA := 0.5  ## how far an axis must move to be picked
const BRAKE_ON := 0.3

class Binding:
	var device := ""  ## joypad name; "" = the first connected
	var axis := -1  ## -1 = unbound
	var invert := false
	var deadzone := 0.06
	var expo := 0.0  ## 0 linear .. 1 mostly cubic: finer control near the centre

	func to_dict() -> Dictionary:
		return {"device": device, "axis": axis, "invert": invert, "deadzone": deadzone, "expo": expo}

	static func make(d: Dictionary) -> Binding:
		var b := Binding.new()
		b.device = str(d.get("device", ""))
		b.axis = int(d.get("axis", -1))
		b.invert = bool(d.get("invert", false))
		b.deadzone = clampf(float(d.get("deadzone", 0.06)), 0.0, 0.5)
		b.expo = clampf(float(d.get("expo", 0.0)), 0.0, 1.0)
		return b

var bindings := {}
var reader := func(dev: int, axis: int) -> float: return Input.get_joy_axis(dev, axis)
## [[index, name], ...] of the connected joypads
var pads := func() -> Array: return Input.get_connected_joypads().map(func(i): return [i, Input.get_joy_name(i)])
var _capture := {}  ## "dev:axis" -> resting value while capturing


func _init() -> void:
	for c in CONTROLS:
		bindings[c] = Binding.new()
	bindings.roll.axis = JOY_AXIS_LEFT_X
	bindings.pitch.axis = JOY_AXIS_LEFT_Y  # stick back reads +1 on Godot's Y: pull = nose up, as our stick wants
	bindings.yaw.axis = JOY_AXIS_RIGHT_X


func to_dict() -> Dictionary:
	var d := {}
	for c in bindings:
		d[c] = bindings[c].to_dict()
	return d


static func from_dict(d: Dictionary) -> FlightAxes:
	var fa := FlightAxes.new()
	for c in d:
		if fa.bindings.has(c):
			fa.bindings[c] = Binding.make(d[c])
	return fa


## Deadzone (rescaled so the output still reaches 1), then expo, then the lever mapping.
static func shape(v: float, b: Binding, lever: bool) -> float:
	if b.invert:
		v = -v
	if lever:
		return clampf((v + 1.0) * 0.5, 0.0, 1.0)  # a lever has no centre to dead-band
	var a := absf(v)
	if a < b.deadzone:
		return 0.0
	a = (a - b.deadzone) / (1.0 - b.deadzone)
	a = (1.0 - b.expo) * a + b.expo * a * a * a
	return clampf(signf(v) * a, -1.0, 1.0)


## The joypad index a binding reads from, or -1.
func device_index(b: Binding) -> int:
	var list: Array = pads.call()
	if list.is_empty():
		return -1
	if b.device == "":
		return list[0][0]
	for p in list:
		if p[1] == b.device:
			return p[0]
	return -1


## The control's value, or null when it's unbound or its device isn't plugged in.
func value(control: String):
	var b: Binding = bindings[control]
	if b.axis < 0:
		return null
	var dev := device_index(b)
	if dev < 0:
		return null
	return shape(reader.call(dev, b.axis), b, CONTROLS[control] == "lever")


## Fill the input frame's analogue controls. Keys (and the mouse yoke) stay in
## charge of anything unbound, or centred: a gamepad left alone doesn't pin the
## rudder at zero against Q/E.
func read(inp: ControlMapper.InputFrame) -> void:
	var r = value("roll")
	var p = value("pitch")
	r = r if r != null else 0.0
	p = p if p != null else 0.0
	if r != 0.0 or p != 0.0:
		inp.stick = [r, p]
	var y = value("yaw")
	if y != null and y != 0.0:
		inp.rudder_axis = y
	var t = value("throttle")
	if t != null:
		inp.throttle_axis = t
	var bl = value("brake_left")
	var br = value("brake_right")
	if maxf(bl if bl != null else 0.0, br if br != null else 0.0) > BRAKE_ON:
		inp.held["brake"] = true


# ------------------------------------------------------------ capture
## "Move the control you want": remember every axis at rest ...
func capture_begin() -> void:
	_capture.clear()
	for p in pads.call():
		for a in JOY_AXIS_SDL_MAX:
			_capture["%d:%d" % [p[0], a]] = reader.call(p[0], a)


## ... then bind whichever moved furthest. Returns the binding, or null until one has moved enough.
func capture_poll(control: String):
	var best := CAPTURE_DELTA
	var hit := []
	for p in pads.call():
		for a in JOY_AXIS_SDL_MAX:
			var k := "%d:%d" % [p[0], a]
			var d := absf(reader.call(p[0], a) - float(_capture.get(k, 0.0)))
			if d > best:
				best = d
				hit = [p[1], a, reader.call(p[0], a) - float(_capture.get(k, 0.0))]
	if hit.is_empty():
		return null
	var b := Binding.new()
	b.device = hit[0]
	b.axis = hit[1]
	var old: Binding = bindings[control]
	b.deadzone = old.deadzone
	b.expo = old.expo
	# levers: pushed forward should be more; bindings take the direction you moved it as "more"
	if CONTROLS[control] == "lever":
		b.invert = hit[2] < 0.0
	bindings[control] = b
	_capture.clear()
	return b


func clear(control: String) -> void:
	bindings[control].axis = -1


func describe(control: String) -> String:
	var b: Binding = bindings[control]
	if b.axis < 0:
		return "keys"
	var dev := b.device if b.device != "" else "first joypad"
	var named := " (%s)" % AXIS_NAMES[b.axis] if b.axis < AXIS_NAMES.size() else ""
	return "%s  axis %d%s%s" % [dev, b.axis, named, "  inverted" if b.invert else ""]
