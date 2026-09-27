class_name ControlsConfig
extends RefCounted
## The pilot's controls as rebindable input actions, and the player's settings.
##
## Keys and buttons are InputMap actions ("fly_pitch_up", ...) with the game's
## defaults, remapped through Nathan Hoad's Input Helper (MIT, addons/input_helper,
## instanced on demand - no autoload), which also names each button for the pad
## in use. The events are saved as themselves (physical keys stay physical). The flight axes
## (yoke, throttle quadrant, pedals, toe brakes, across several devices) are
## ours: FlightAxes. Both are saved to user://controls.cfg; the look (palette,
## screen filter) to user://settings.cfg.

const PATH := "user://controls.cfg"
const SETTINGS_PATH := "user://settings.cfg"
const PREFIX := "fly_"

## Held flight controls: action -> default keys, gamepad buttons, gamepad axes ([axis, sign]).
const HELD := {
	"pitch_up": {"keys": [KEY_S, KEY_DOWN]},
	"pitch_down": {"keys": [KEY_W, KEY_UP]},
	"roll_left": {"keys": [KEY_A, KEY_LEFT]},
	"roll_right": {"keys": [KEY_D, KEY_RIGHT]},
	"yaw_left": {"keys": [KEY_Q]},
	"yaw_right": {"keys": [KEY_E]},
	"throttle_up": {"keys": [KEY_R, KEY_PAGEUP], "axes": [[JOY_AXIS_TRIGGER_RIGHT, 1.0]]},
	"throttle_down": {"keys": [KEY_F, KEY_PAGEDOWN], "axes": [[JOY_AXIS_TRIGGER_LEFT, 1.0]]},
	"brake": {"keys": [KEY_B, KEY_SPACE], "buttons": [JOY_BUTTON_LEFT_SHOULDER]},
	"trim_up": {"keys": [KEY_BRACKETRIGHT], "buttons": [JOY_BUTTON_DPAD_RIGHT]},
	"trim_down": {"keys": [KEY_BRACKETLEFT], "buttons": [JOY_BUTTON_DPAD_LEFT]},
}
## One-shot flight controls.
const PRESSED := {
	"flaps_down": {"keys": [KEY_G], "buttons": [JOY_BUTTON_DPAD_DOWN]},
	"flaps_up": {"keys": [KEY_T], "buttons": [JOY_BUTTON_DPAD_UP]},
	"throttle_cut": {"keys": [KEY_X]},
	"throttle_full": {"keys": [KEY_Z]},
}
const LABELS := {
	"pitch_up": "Pitch up (pull)", "pitch_down": "Pitch down (push)", "roll_left": "Roll left", "roll_right": "Roll right",
	"yaw_left": "Rudder left", "yaw_right": "Rudder right", "throttle_up": "Throttle up", "throttle_down": "Throttle down",
	"brake": "Brakes", "trim_up": "Trim nose up", "trim_down": "Trim nose down", "flaps_down": "Flaps down",
	"flaps_up": "Flaps up", "throttle_cut": "Throttle cut", "throttle_full": "Full throttle",
}

static var _helper: Node = null
static var axes := FlightAxes.new()
static var _loaded := false


## Every rebindable control, held ones first.
static func names() -> Array:
	return HELD.keys() + PRESSED.keys()


static func action(n: String) -> String:
	return PREFIX + n


## Register the actions with their defaults (once), then the player's saved bindings.
static func ensure() -> void:
	for n in names():
		if not InputMap.has_action(action(n)):
			InputMap.add_action(action(n), 0.3)
			_add_defaults(n)
	if not _loaded:
		_loaded = true
		load_file()


static func _add_defaults(n: String) -> void:
	var d: Dictionary = HELD.get(n, PRESSED.get(n, {}))
	for k in d.get("keys", []):
		var ev := InputEventKey.new()
		ev.physical_keycode = k
		InputMap.action_add_event(action(n), ev)
	for b in d.get("buttons", []):
		var ev := InputEventJoypadButton.new()
		ev.device = -1
		ev.button_index = b
		InputMap.action_add_event(action(n), ev)
	for a in d.get("axes", []):
		var ev := InputEventJoypadMotion.new()
		ev.device = -1
		ev.axis = a[0]
		ev.axis_value = a[1]
		InputMap.action_add_event(action(n), ev)


## Input Helper, instanced on demand (it tracks the device in use from _input, so it lives in the tree).
static func helper() -> Node:
	if _helper == null or not is_instance_valid(_helper):
		_helper = (load("res://addons/input_helper/input_helper.gd") as GDScript).new()
		_helper.name = "InputHelper"
		var tree := Engine.get_main_loop() as SceneTree
		if tree != null:
			tree.root.add_child.call_deferred(_helper)
	return _helper


## The labels of an action's bindings: "W, Up, LB Button".
static func describe(n: String) -> String:
	ensure()
	var h := helper()
	var out := []
	for ev in InputMap.action_get_events(action(n)):
		out.append(h.get_label_for_input(ev))
	return ", ".join(out) if not out.is_empty() else "-"


## Bind `ev` (a key, mouse or joypad button) as the action's first key or button.
## A clash with another flight control swaps the two; the game's other keys are never touched.
static func rebind(n: String, ev: InputEvent) -> void:
	ensure()
	var h := helper()
	var is_key := ev is InputEventKey or ev is InputEventMouseButton
	var mine: Array = h.get_keyboard_inputs_for_action(action(n)) if is_key else h.get_joypad_inputs_for_action(action(n))
	var old: InputEvent = mine[0] if not mine.is_empty() else null
	for other in names():
		if other == n:
			continue
		for e in InputMap.action_get_events(action(other)):
			if e.is_match(ev):
				InputMap.action_erase_event(action(other), e)
				if old != null:
					InputMap.action_add_event(action(other), old)
	if is_key:
		h.set_keyboard_input_for_action(action(n), ev, false)
	else:
		h.set_joypad_input_for_action(action(n), ev, false)


## Back to the game's defaults (keys, buttons and axes).
static func reset() -> void:
	ensure()
	for n in names():
		InputMap.action_erase_events(action(n))
		_add_defaults(n)
	axes = FlightAxes.new()


static func save_file(path := PATH) -> void:
	ensure()
	var cf := ConfigFile.new()
	# the events themselves: Input Helper's text format would turn physical keys into
	# layout keycodes and pin joypad buttons to pad 0
	for n in names():
		cf.set_value("keys", n, InputMap.action_get_events(action(n)))
	cf.set_value("axes", "bindings", axes.to_dict())
	cf.save(path)


static func load_file(path := PATH) -> bool:
	var cf := ConfigFile.new()
	if cf.load(path) != OK:
		return false
	ensure()
	for n in names():
		var evs = cf.get_value("keys", n, null)
		if evs is Array and not evs.is_empty():
			InputMap.action_erase_events(action(n))
			for ev in evs:
				if ev is InputEvent:
					InputMap.action_add_event(action(n), ev)
	axes = FlightAxes.from_dict(cf.get_value("axes", "bindings", {}))
	return true


# ------------------------------------------------------------ the look
## {palette: "neon"|"safe", filter: ScreenFilter mode}
static func settings() -> Dictionary:
	var cf := ConfigFile.new()
	cf.load(SETTINGS_PATH)
	return {"palette": cf.get_value("look", "palette", "neon"), "filter": cf.get_value("look", "filter", "off")}


static func save_setting(key: String, value) -> void:
	var cf := ConfigFile.new()
	cf.load(SETTINGS_PATH)
	cf.set_value("look", key, value)
	cf.save(SETTINGS_PATH)
