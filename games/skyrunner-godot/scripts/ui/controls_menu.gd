class_name ControlsMenu
extends CanvasLayer
## F8: the pilot's controls. Every flight key and button can be rebound (press
## Rebind, then the key or joypad button: Input Helper does the mapping and
## names the button for the pad in use). Every analogue control - yoke, throttle
## lever, pedals, toe brakes - is bound by moving it (FlightAxes.capture), from
## any device, with invert, deadzone and expo. The colour-safe palette is here
## too. Everything is saved to user:// when the panel closes.

signal closed

var panel: PanelContainer
var status: Label
var key_rows := {}  ## action -> the Label showing its bindings
var axis_rows := {}  ## control -> {desc: Label, bar: ProgressBar, tune: Label}
var palette_btn: Button
var waiting_key := ""  ## an action waiting for its new key or button
var capturing := ""  ## an axis control waiting to be moved


func _ready() -> void:
	layer = 70
	ControlsConfig.ensure()
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.theme = UIStyle.theme()
	add_child(root)
	panel = PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UIStyle.box(Color(0.06, 0.02, 0.09, 0.96), 10, UIStyle.ACCENT, 2, Vector4(20, 14, 20, 14)))
	panel.anchor_left = 0.08
	panel.anchor_right = 0.92
	panel.anchor_top = 0.05
	panel.anchor_bottom = 0.95
	root.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	panel.add_child(v)
	v.add_child(UIStyle.title("Controls", 30, UIStyle.ACCENT))
	status = UIStyle.caption("Rebind: press the key or joypad button.  Bind axis: move the control all the way.  ESC saves and closes.")
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(status)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(body)

	body.add_child(UIStyle.label("Axes: yoke, throttle quadrant, pedals, toe brakes", 18, UIStyle.CYAN))
	var ag := GridContainer.new()
	ag.columns = 9
	ag.add_theme_constant_override("h_separation", 8)
	body.add_child(ag)
	for c in FlightAxes.CONTROLS:
		ag.add_child(UIStyle.label(FlightAxes.LABELS[c], 15))
		var desc := UIStyle.label("", 14, UIStyle.DIM)
		desc.custom_minimum_size.x = 260
		ag.add_child(desc)
		var bar := ProgressBar.new()
		bar.min_value = 0.0 if FlightAxes.CONTROLS[c] == "lever" else -1.0
		bar.max_value = 1.0
		bar.step = 0.01
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(120, 14)
		ag.add_child(bar)
		ag.add_child(_btn("Bind", func(): _capture(c)))
		ag.add_child(_btn("Invert", func(): _tweak(c, "invert", 0)))
		ag.add_child(_btn("Dead -/+", func(): _tweak(c, "deadzone", 1), func(): _tweak(c, "deadzone", -1)))
		ag.add_child(_btn("Expo -/+", func(): _tweak(c, "expo", 1), func(): _tweak(c, "expo", -1)))
		var tune := UIStyle.label("", 13, UIStyle.CAPTION)
		ag.add_child(tune)
		ag.add_child(_btn("Clear", func():
			ControlsConfig.axes.clear(c)
			_refresh()))
		axis_rows[c] = {"desc": desc, "bar": bar, "tune": tune}

	body.add_child(UIStyle.label("Keys and buttons", 18, UIStyle.CYAN))
	var kg := GridContainer.new()
	kg.columns = 3
	kg.add_theme_constant_override("h_separation", 12)
	body.add_child(kg)
	for n in ControlsConfig.names():
		kg.add_child(UIStyle.label(ControlsConfig.LABELS[n], 15))
		var l := UIStyle.label("", 15, UIStyle.WHITE)
		l.custom_minimum_size.x = 320
		kg.add_child(l)
		kg.add_child(_btn("Rebind", func(): _rebind(n)))
		key_rows[n] = l

	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 12)
	v.add_child(foot)
	palette_btn = _btn("", _toggle_palette)
	foot.add_child(palette_btn)
	foot.add_child(_btn("Defaults", func():
		ControlsConfig.reset()
		status.text = "Back to the defaults."
		_refresh()))
	foot.add_child(_btn("Save and close", close))
	_refresh()


## A button; the second callback (if any) is the right click.
func _btn(text: String, cb: Callable, right := Callable()) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	if right.is_valid():
		b.button_mask = MOUSE_BUTTON_MASK_LEFT | MOUSE_BUTTON_MASK_RIGHT
		b.gui_input.connect(func(ev):
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_RIGHT:
				right.call())
		b.tooltip_text = "left click: more   right click: less"
	return b


func _refresh() -> void:
	for n in key_rows:
		key_rows[n].text = "press a key or button ..." if waiting_key == n else ControlsConfig.describe(n)
	for c in axis_rows:
		var b: FlightAxes.Binding = ControlsConfig.axes.bindings[c]
		axis_rows[c].desc.text = "move it ..." if capturing == c else ControlsConfig.axes.describe(c)
		axis_rows[c].tune.text = "dz %.2f  expo %.1f" % [b.deadzone, b.expo]
	palette_btn.text = "Colours: %s" % ("colour-safe" if UIStyle.palette == "safe" else "neon")


func _rebind(n: String) -> void:
	waiting_key = n
	capturing = ""
	status.text = "%s: press the new key or joypad button (ESC to cancel)." % ControlsConfig.LABELS[n]
	_refresh()


func _capture(c: String) -> void:
	capturing = c
	waiting_key = ""
	ControlsConfig.axes.capture_begin()
	status.text = "%s: move it through its whole range (ESC to cancel)." % FlightAxes.LABELS[c]
	_refresh()


## `dir`: 0 toggles invert, +1/-1 steps deadzone or expo.
func _tweak(c: String, what: String, dir: int) -> void:
	var b: FlightAxes.Binding = ControlsConfig.axes.bindings[c]
	match what:
		"invert":
			b.invert = not b.invert
		"deadzone":
			b.deadzone = clampf(b.deadzone + 0.02 * dir, 0.0, 0.5)
		"expo":
			b.expo = clampf(b.expo + 0.1 * dir, 0.0, 1.0)
	_refresh()


func _toggle_palette() -> void:
	UIStyle.set_palette("neon" if UIStyle.palette == "safe" else "safe")
	ControlsConfig.save_setting("palette", UIStyle.palette)
	status.text = "Colours: %s - new screens use it now; restart for everything." % UIStyle.palette
	_refresh()


func _input(ev: InputEvent) -> void:
	var is_key: bool = ev is InputEventKey and ev.pressed and not ev.echo
	if is_key and ev.physical_keycode == KEY_ESCAPE:
		if waiting_key != "" or capturing != "":
			waiting_key = ""
			capturing = ""
			status.text = "Cancelled."
			_refresh()
		else:
			close()
		get_viewport().set_input_as_handled()
		return
	if waiting_key != "":
		var take: InputEvent = null
		if is_key:
			var k := InputEventKey.new()
			k.physical_keycode = ev.physical_keycode if ev.physical_keycode else ev.keycode
			take = k
		elif ev is InputEventJoypadButton and ev.pressed:
			var jb := InputEventJoypadButton.new()
			jb.device = -1
			jb.button_index = ev.button_index
			take = jb
		if take != null:
			ControlsConfig.rebind(waiting_key, take)
			status.text = "%s: %s" % [ControlsConfig.LABELS[waiting_key], ControlsConfig.describe(waiting_key)]
			waiting_key = ""
			_refresh()
			get_viewport().set_input_as_handled()
			return
	if is_key:
		get_viewport().set_input_as_handled()  # the panel is modal: no flying while it's open


func _process(_dt: float) -> void:
	if capturing != "":
		var b = ControlsConfig.axes.capture_poll(capturing)
		if b != null:
			status.text = "%s: %s" % [FlightAxes.LABELS[capturing], ControlsConfig.axes.describe(capturing)]
			capturing = ""
			_refresh()
	for c in axis_rows:
		var v = ControlsConfig.axes.value(c)
		var bar: ProgressBar = axis_rows[c].bar
		bar.value = v if v != null else bar.min_value
		bar.modulate.a = 1.0 if v != null else 0.35  # unbound or unplugged


func close() -> void:
	ControlsConfig.save_file()
	closed.emit()
	queue_free()
