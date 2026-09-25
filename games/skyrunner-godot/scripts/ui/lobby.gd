class_name Lobby
extends Control
## Start screen: host a game (mode, players, graphics, seed) or join one as a
## remote seat. Emits `start(opts)` with the same keys as the command line.

signal start(opts: Dictionary)

var mode_ob: OptionButton
var players: SpinBox
var graphics_ob: OptionButton
var seed_box: SpinBox
var new_cb: CheckBox
var watch_cb: CheckBox
var host_cb: CheckBox
var addr: LineEdit
var role_ob: OptionButton
var name_le: LineEdit
var plan_lbl: Label

const MODES := [["Sandbox (solo)", "solo"], ["Campaign 1979-", "campaign"], ["Co-op: friends crew for you", "coop"],
	["Versus: friends run the task force", "versus"], ["Task-force desk vs AI runners", "police"]]
const JOIN_ROLES := ["copilot", "spotter", "boat", "boss", "controller", "interceptor", "cutter", "chief"]


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.07, 0.1)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UIStyle.panel_box())
	center.add_child(panel)
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(620, 0)
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	v.add_child(UIStyle.label("SKYRUNNER", 40, UIStyle.AMBER))
	v.add_child(UIStyle.label("Bush flying, weight & balance, and the long arm of the law.", 16, UIStyle.DIM))
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
	plan_lbl = UIStyle.label("", 14, UIStyle.CYAN, UIStyle.mono())
	plan_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(plan_lbl)
	var go := Button.new()
	go.text = "Fly"
	go.custom_minimum_size = Vector2(0, 40)
	go.pressed.connect(_go)
	v.add_child(go)
	v.add_child(HSeparator.new())
	v.add_child(UIStyle.label("Join a game", 20, UIStyle.AMBER))
	var j := HBoxContainer.new()
	addr = LineEdit.new()
	addr.placeholder_text = "host:47800"
	addr.custom_minimum_size = Vector2(200, 0)
	role_ob = OptionButton.new()
	for r in JOIN_ROLES:
		role_ob.add_item(r)
	name_le = LineEdit.new()
	name_le.placeholder_text = "your name"
	var join := Button.new()
	join.text = "Join"
	join.pressed.connect(_join)
	for c in [addr, role_ob, name_le, join]:
		j.add_child(c)
	v.add_child(j)
	_plan()


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
		"watch": watch_cb.button_pressed, "host": host_cb.button_pressed})


func _join() -> void:
	if addr.text.strip_edges() == "":
		plan_lbl.text = "Enter the host's address (host:port)."
		return
	start.emit({"connect": addr.text.strip_edges(), "role": JOIN_ROLES[role_ob.selected],
		"name": name_le.text if name_le.text else "player", "graphics": graphics_ob.get_item_text(graphics_ob.selected)})
