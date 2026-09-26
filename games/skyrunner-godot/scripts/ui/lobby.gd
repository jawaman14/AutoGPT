class_name Lobby
extends Control
## Start screen: host a game (mode, players, graphics, seed) or join one as a
## remote seat. Emits `start(opts)` with the same keys as the command line.
## Fully keyboard-driven too: TAB/arrows move focus (Fly has it first), ENTER
## presses, and the key caps at the bottom say so.

signal start(opts: Dictionary)

var mode_ob: OptionButton
var players: SpinBox
var graphics_ob: OptionButton
var seed_box: SpinBox
var map_box: SpinBox
var map_ob: OptionButton
var new_cb: CheckBox
var watch_cb: CheckBox
var host_cb: CheckBox
var addr: LineEdit
var role_ob: OptionButton
var name_le: LineEdit
var plan_lbl: Label
var go_btn: Button
var hints: KeyHints

const MODES := [["Sandbox (solo)", "solo"], ["Campaign 1979-", "campaign"], ["Co-op: friends crew for you", "coop"],
	["Versus: friends run the task force", "versus"], ["Task-force desk vs AI runners", "police"]]
const JOIN_ROLES := ["", "copilot", "spotter", "boat", "boss", "lieutenant", "controller", "interceptor", "cutter", "chief", "patrol"]


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = UIStyle.theme()
	var bg := ColorRect.new()
	bg.color = Color(0.035, 0.045, 0.065)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UIStyle.box(Color(0.06, 0.07, 0.095, 0.97), 10, UIStyle.LINE, 1, Vector4(28, 22, 28, 20)))
	center.add_child(panel)
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(660, 0)
	v.add_theme_constant_override("separation", 10)
	panel.add_child(v)
	v.add_child(UIStyle.title("Skyrunner", 64))
	v.add_child(UIStyle.label("Bush flying, weight & balance, and the long arm of the law.", 16, UIStyle.DIM))
	v.add_child(UIStyle.caption("Host a game"))
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 14)
	v.add_child(g)
	mode_ob = OptionButton.new()
	for m in MODES:
		mode_ob.add_item(m[0])
	mode_ob.item_selected.connect(func(_i): _plan())
	_row(g, "Mode", mode_ob)
	players = SpinBox.new()
	players.min_value = 1
	players.max_value = 9
	players.value = 1
	players.value_changed.connect(func(_v): _plan())
	_row(g, "Players at the table", players)
	graphics_ob = OptionButton.new()
	for q in ["high", "medium", "low"]:
		graphics_ob.add_item(q)
	_row(g, "Graphics", graphics_ob)
	seed_box = SpinBox.new()
	seed_box.min_value = 1
	seed_box.max_value = 99999
	seed_box.value = 1
	_row(g, "Job board seed", seed_box)
	map_ob = OptionButton.new()
	for m in ["Costa Brava (city coast)", "The classic island", "A generated island"]:
		map_ob.add_item(m)
	map_box = SpinBox.new()
	map_box.min_value = 1
	map_box.max_value = 99999
	map_box.value = 42
	map_box.tooltip_text = "The seed the island grows from"
	var mrow := HBoxContainer.new()
	mrow.add_child(map_ob)
	mrow.add_child(map_box)
	var roll := Button.new()
	roll.text = "New island"
	roll.pressed.connect(func():
		map_ob.select(2)
		map_box.value = randi_range(1, 99999))
	mrow.add_child(roll)
	_row(g, "Map", mrow)
	var flags := HBoxContainer.new()
	new_cb = CheckBox.new()
	new_cb.text = "New game (ignore save)"
	watch_cb = CheckBox.new()
	watch_cb.text = "Watch the AI fly"
	host_cb = CheckBox.new()
	host_cb.text = "Open remote seats"
	for c in [new_cb, watch_cb, host_cb]:
		flags.add_child(c)
	v.add_child(flags)
	var pp := PanelContainer.new()
	pp.add_theme_stylebox_override("panel", UIStyle.box(Color(0.3, 0.8, 1, 0.06), 6, Color(0.5, 0.9, 1, 0.25), 1, Vector4(12, 8, 12, 8)))
	plan_lbl = UIStyle.label("", 14, UIStyle.CYAN)
	plan_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	pp.add_child(plan_lbl)
	v.add_child(pp)
	go_btn = Button.new()
	go_btn.text = "FLY"
	go_btn.custom_minimum_size = Vector2(0, 46)
	go_btn.add_theme_font_size_override("font_size", 20)
	go_btn.add_theme_stylebox_override("normal", UIStyle.box(UIStyle.ACCENT.darkened(0.35), 6, UIStyle.ACCENT, 1))
	go_btn.add_theme_stylebox_override("hover", UIStyle.box(UIStyle.ACCENT.darkened(0.2), 6, UIStyle.ACCENT, 1))
	go_btn.add_theme_color_override("font_color", UIStyle.WHITE)
	go_btn.pressed.connect(_go)
	v.add_child(go_btn)
	v.add_child(HSeparator.new())
	v.add_child(UIStyle.caption("Join a game"))
	var j := HBoxContainer.new()
	addr = LineEdit.new()
	addr.placeholder_text = "host:47800"
	addr.custom_minimum_size = Vector2(200, 0)
	role_ob = OptionButton.new()
	for r in JOIN_ROLES:
		role_ob.add_item(r if r != "" else "pick a seat")
	name_le = LineEdit.new()
	name_le.placeholder_text = "your name"
	var join := Button.new()
	join.text = "Join"
	join.pressed.connect(_join)
	j.add_theme_constant_override("separation", 8)
	for c in [addr, role_ob, name_le, join]:
		j.add_child(c)
	v.add_child(j)
	hints = KeyHints.new()
	hints.set_hints([["TAB", "next field", ""], ["ARROWS", "change", ""], ["ENTER", "press / fly", ""], ["F", "fly now", "fly"]])
	hints.hint_pressed.connect(func(a):
		if a == "fly":
			_go())
	v.add_child(hints)
	addr.text_submitted.connect(func(_t): _join())
	name_le.text_submitted.connect(func(_t): _join())
	_plan()
	go_btn.grab_focus.call_deferred()


func _unhandled_key_input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and not ev.echo and ev.keycode == KEY_F:
		_go()
		get_viewport().set_input_as_handled()


func _row(g: GridContainer, text: String, c: Control) -> void:
	g.add_child(UIStyle.label(text, 16))
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	g.add_child(c)


func _plan() -> void:
	var n := int(players.value)
	if n <= 1:
		plan_lbl.text = "One player: you fly; the task force and everyone else is AI."
		return
	var plan := Layers.plan_match(n, MODES[mode_ob.selected][1] != "coop")
	plan_lbl.text = plan.describe()


func _go() -> void:
	start.emit({"mode": MODES[mode_ob.selected][1] if MODES[mode_ob.selected][1] != "police" else "solo",
		"police": MODES[mode_ob.selected][1] == "police", "players": int(players.value) if players.value > 1 else 0,
		"graphics": graphics_ob.get_item_text(graphics_ob.selected), "seed": int(seed_box.value), "new": new_cb.button_pressed,
		"watch": watch_cb.button_pressed, "host": host_cb.button_pressed, "map": [MapCity.SEED, 0, int(map_box.value)][map_ob.selected]})


func _join() -> void:
	if addr.text.strip_edges() == "":
		plan_lbl.text = "Enter the host's address (host:port)."
		return
	start.emit({"connect": addr.text.strip_edges(), "role": JOIN_ROLES[role_ob.selected],
		"name": name_le.text if name_le.text else "player", "graphics": graphics_ob.get_item_text(graphics_ob.selected)})
