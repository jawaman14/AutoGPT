extends TestCase
## The pilot's controls: flight keys as rebindable actions (Input Helper), and
## FlightAxes - a yoke, throttle lever, pedals and toe brakes from any device,
## with invert, deadzone, expo and "move it to bind it".

const TMP := "user://test_controls.cfg"


func after_each() -> void:
	ControlsConfig.reset()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))


## A fake set of joypads: {index: [name, {axis: value}]}.
func _fake(fa: FlightAxes, devs: Dictionary) -> void:
	fa.pads = func() -> Array: return devs.keys().map(func(i): return [i, devs[i][0]])
	fa.reader = func(dev: int, axis: int) -> float: return float(devs[dev][1].get(axis, 0.0)) if devs.has(dev) else 0.0


func test_the_default_keys_are_the_old_ones() -> void:
	ControlsConfig.ensure()
	for pair in [["pitch_down", KEY_W], ["pitch_down", KEY_UP], ["roll_left", KEY_A], ["throttle_up", KEY_R], ["brake", KEY_SPACE],
			["flaps_down", KEY_G], ["throttle_cut", KEY_X]]:
		var ev := InputEventKey.new()
		ev.physical_keycode = pair[1]
		ev.pressed = true
		check(ev.is_action(ControlsConfig.action(pair[0])), "%s on %s" % [pair[0], OS.get_keycode_string(pair[1])])
	check("W" in ControlsConfig.describe("pitch_down"), "named: %s" % ControlsConfig.describe("pitch_down"))


func test_rebind_swaps_and_saves() -> void:
	ControlsConfig.ensure()
	var i := InputEventKey.new()
	i.physical_keycode = KEY_I
	ControlsConfig.rebind("flaps_down", i)
	check(i.is_action(ControlsConfig.action("flaps_down")), "flaps down on I")
	var g := InputEventKey.new()
	g.physical_keycode = KEY_G
	check(not g.is_action(ControlsConfig.action("flaps_down")), "and no longer on G")
	# taking another flight control's key swaps them
	var t := InputEventKey.new()
	t.physical_keycode = KEY_T
	ControlsConfig.rebind("flaps_down", t)
	check(t.is_action(ControlsConfig.action("flaps_down")) and not t.is_action(ControlsConfig.action("flaps_up")), "T taken from flaps up")
	check(i.is_action(ControlsConfig.action("flaps_up")), "which gets I in exchange")
	# a gamepad button, named for the pad
	var jb := InputEventJoypadButton.new()
	jb.button_index = JOY_BUTTON_Y
	jb.device = -1
	ControlsConfig.rebind("throttle_full", jb)
	check("Button" in ControlsConfig.describe("throttle_full"), "a button: %s" % ControlsConfig.describe("throttle_full"))
	ControlsConfig.axes.bindings.throttle.axis = 5
	ControlsConfig.save_file(TMP)
	ControlsConfig.reset()
	check(g.is_action(ControlsConfig.action("flaps_down")), "defaults back")
	check(ControlsConfig.load_file(TMP), "loaded")
	check(t.is_action(ControlsConfig.action("flaps_down")), "the saved key")
	check(jb.is_action(ControlsConfig.action("throttle_full")), "the saved button")
	check_eq(ControlsConfig.axes.bindings.throttle.axis, 5, "the saved axis")
	check(not InputMap.action_get_events("ui_up").is_empty(), "the game's other actions untouched")


func test_shaping() -> void:
	var b := FlightAxes.Binding.new()
	b.deadzone = 0.1
	check_eq(FlightAxes.shape(0.05, b, false), 0.0, "inside the deadzone")
	check_near(FlightAxes.shape(1.0, b, false), 1.0, 1e-6, "still reaches full")
	check_near(FlightAxes.shape(0.55, b, false), 0.5, 1e-6, "rescaled past the deadzone")
	b.expo = 1.0
	check_near(FlightAxes.shape(0.55, b, false), 0.125, 1e-6, "expo: finer near the centre")
	check_near(FlightAxes.shape(-1.0, b, false), -1.0, 1e-6, "and full at the stops")
	b.invert = true
	check_near(FlightAxes.shape(-1.0, b, false), 1.0, 1e-6, "inverted")
	var lever := FlightAxes.Binding.new()
	check_near(FlightAxes.shape(-1.0, lever, true), 0.0, 1e-6, "a lever at rest: idle")
	check_near(FlightAxes.shape(1.0, lever, true), 1.0, 1e-6, "pushed: full")


func test_a_gamepad_by_default() -> void:
	var fa := FlightAxes.new()
	_fake(fa, {0: ["Xbox Series Controller", {JOY_AXIS_LEFT_X: 0.5, JOY_AXIS_LEFT_Y: -1.0, JOY_AXIS_RIGHT_X: 0.03}]})
	var inp := ControlMapper.InputFrame.new()
	fa.read(inp)
	check(inp.stick != null and inp.stick[0] > 0.4 and inp.stick[1] < -0.9, "left stick is the yoke: %s" % [inp.stick])
	check(inp.rudder_axis == null, "a centred right stick leaves the rudder to Q/E")
	check(inp.throttle_axis == null, "the throttle stays on the triggers / keys")
	_fake(fa, {})
	inp = ControlMapper.InputFrame.new()
	fa.read(inp)
	check(inp.stick == null, "no joypad: keys and mouse")


func test_yoke_quadrant_and_pedals_on_three_devices() -> void:
	var fa := FlightAxes.new()
	var devs := {
		0: ["Saitek Pro Flight Yoke", {0: 0.0, 1: 0.0, 2: -1.0}],
		1: ["Saitek Pro Flight Rudder Pedals", {0: -1.0, 1: -1.0, 2: 0.0}],
	}
	_fake(fa, devs)
	# bind by moving each control
	for step in [["roll", 0, 0, 0.8], ["pitch", 0, 1, 0.9], ["throttle", 0, 2, 1.0], ["yaw", 1, 2, -0.9], ["brake_left", 1, 0, 1.0], ["brake_right", 1, 1, 1.0]]:
		fa.capture_begin()
		check(fa.capture_poll(step[0]) == null, "%s: nothing moved yet" % step[0])
		var was: float = devs[step[1]][1][step[2]]
		devs[step[1]][1][step[2]] = step[3]
		var b = fa.capture_poll(step[0])
		check(b != null and b.device == devs[step[1]][0] and b.axis == step[2], "%s bound to %s axis %d" % [step[0], devs[step[1]][0], step[2]])
		devs[step[1]][1][step[2]] = was
	# the pedals come back as a different joypad index: matched by name
	var yoke: Array = devs[0]
	devs.clear()
	devs[3] = ["Saitek Pro Flight Rudder Pedals", {0: 1.0, 1: -1.0, 2: 0.6}]
	devs[2] = yoke
	yoke[1][2] = 0.2  # throttle at 60%
	var inp := ControlMapper.InputFrame.new()
	fa.read(inp)
	check_near(float(inp.rudder_axis), (0.6 - 0.06) / 0.94, 0.01, "rudder from the pedals (%s)" % [inp.rudder_axis])
	check_near(float(inp.throttle_axis), 0.6, 0.01, "an absolute throttle lever")
	check(inp.held.has("brake"), "a toe brake")
	# round trip
	var back := FlightAxes.from_dict(fa.to_dict())
	check_eq(back.bindings.yaw.device, "Saitek Pro Flight Rudder Pedals", "saved by device name")


func test_axes_fly_the_aircraft() -> void:
	var s := Session.new({"seed": 1, "location": "HAR"})
	s.spawn_airborne(0.0, -6000.0, 600.0, 90.0, 110.0)
	var fa := FlightAxes.new()
	fa.bindings.throttle.axis = 2
	_fake(fa, {0: ["Yoke", {JOY_AXIS_LEFT_X: 1.0, 2: 1.0}]})
	var inp := ControlMapper.InputFrame.new()
	fa.read(inp)
	s.update(1.0 / 30, inp)
	check(s.mapper.controls.aileron > 0.9, "full right aileron")
	check_near(s.mapper.controls.throttle, 1.0, 1e-6, "full throttle from the lever")
	s.dispose()


func test_the_panel() -> void:
	var m := ControlsMenu.new()
	Engine.get_main_loop().root.add_child(m)
	check_eq(m.key_rows.size(), ControlsConfig.names().size(), "a row for every flight control")
	check_eq(m.axis_rows.size(), FlightAxes.CONTROLS.size(), "and every axis")
	m._rebind("brake")
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_N
	ev.pressed = true
	m._input(ev)
	check(ev.is_action(ControlsConfig.action("brake")), "rebound through the panel")
	m._toggle_palette()
	check_eq(UIStyle.palette, "safe", "the colour-safe palette")
	m._toggle_palette()
	check_eq(UIStyle.palette, "neon", "and back")
	m.queue_free()
