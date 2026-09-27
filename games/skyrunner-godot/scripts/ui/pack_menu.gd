class_name PackMenu
extends CanvasLayer
## I on foot: what you carry (FootCombat's pack) - the gun in your hands, spare
## guns, rounds and medkits - its weight against what you can carry, and +/-
## to take from or leave in the armoury (medkits are bought by the aircraft).

signal closed

var foot: FootCombat
var near_aircraft := func() -> bool: return true
var rows: VBoxContainer
var weight_bar: ProgressBar
var weight_label: Label
var status: Label
const STEP := {"ammo": 30}


func _ready() -> void:
	layer = 70
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.theme = UIStyle.theme()
	add_child(root)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UIStyle.box(Color(0.06, 0.02, 0.09, 0.95), 10, UIStyle.ACCENT, 2, Vector4(20, 14, 20, 14)))
	panel.anchor_left = 0.3
	panel.anchor_right = 0.7
	panel.anchor_top = 0.14
	panel.anchor_bottom = 0.86
	root.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	v.add_child(UIStyle.title("Your pack", 28, UIStyle.ACCENT))
	weight_label = UIStyle.label("", 15, UIStyle.WHITE)
	v.add_child(weight_label)
	weight_bar = ProgressBar.new()
	weight_bar.max_value = FootCombat.CARRY_KG
	weight_bar.show_percentage = false
	weight_bar.custom_minimum_size.y = 12
	v.add_child(weight_bar)
	rows = VBoxContainer.new()
	rows.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(rows)
	status = UIStyle.caption("+ take from the armoury   - leave it   5 use a medkit   I or ESC close")
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(status)
	refresh()


func refresh() -> void:
	for c in rows.get_children():
		c.queue_free()
	var kg := foot.weight()
	weight_bar.value = kg
	weight_bar.modulate = UIStyle.RED if kg > FootCombat.HEAVY_KG else UIStyle.WHITE
	weight_label.text = "%.1f / %.0f kg%s" % [kg, FootCombat.CARRY_KG, "   heavy: %d%% speed" % roundi(foot.speed_factor() * 100) if kg > FootCombat.HEAVY_KG else ""]
	if foot.tier != "":
		rows.add_child(UIStyle.label("In your hands: %s, %d + %d rounds" % [Arsenal.TIERS[foot.tier].name.trim_suffix("s").to_lower(), foot.mag, foot.reserve], 15, UIStyle.CYAN))
	var ars = foot.armoury()
	for item in ["pistol", "rifle", "mg", "rpg", "ammo", "medkit"]:
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 10)
		var title: String = "Rounds" if item == "ammo" else ("Medkit ($%d)" % FootCombat.MEDKIT_COST if item == "medkit" else Arsenal.TIERS[item].name.trim_suffix("s"))
		var have := int(foot.pack.get(item, 0))
		var l := UIStyle.label("%s  x%d" % [title, have], 15)
		l.custom_minimum_size.x = 230
		h.add_child(l)
		var spare := ""
		if ars != null and item != "medkit":
			spare = "rack %d" % (ars.ammo if item == "ammo" else int(ars.stock.get(item, 0)))
		var cap := UIStyle.caption(("%.1f kg per %d  %s" if STEP.has(item) else "%.1f kg  %s") % ([FootCombat.KG[item] * STEP[item], STEP[item], spare] if STEP.has(item) else [FootCombat.KG[item], spare]))
		cap.custom_minimum_size.x = 170
		h.add_child(cap)
		var plus := Button.new()
		plus.text = "+"
		plus.focus_mode = Control.FOCUS_NONE
		plus.disabled = item == "medkit" and not near_aircraft.call()
		plus.pressed.connect(func(): _act(foot.pack_add(item, STEP.get(item, 1))))
		h.add_child(plus)
		var minus := Button.new()
		minus.text = "-"
		minus.focus_mode = Control.FOCUS_NONE
		minus.disabled = have == 0 or item == "medkit"
		minus.pressed.connect(func(): _act(foot.pack_drop(item, STEP.get(item, 1))))
		h.add_child(minus)
		rows.add_child(h)


func _act(err: String) -> void:
	status.text = err if err != "" else "Packed."
	refresh()


func _input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and not ev.echo:
		if ev.physical_keycode in [KEY_ESCAPE, KEY_I]:
			close()
		elif ev.physical_keycode == KEY_5:
			_act(foot.use_medkit())
		get_viewport().set_input_as_handled()


func close() -> void:
	closed.emit()
	queue_free()
