class_name LogisticsMenu
extends CanvasLayer
## SHIFT+H in the aircraft, H at the organisation's desks: where the product and
## the cash are (Logistics), the trucks on the road, and orders - a truck of
## product or cash from a stash to another stash, the club (HQ) or a buyer's
## meet; and in the aircraft, cash bags on and off where you're parked.
##
## Works from a view (Logistics.view) and a command callable, so a remote desk
## drives it through the link like any other order.

signal closed

var view_fn: Callable  ## () -> Dictionary: the logistics view
var cmd_fn: Callable  ## (name, args) -> [ok, message]
var pilot := false  ## the aircraft's seat: cash bags on and off
var rows: VBoxContainer
var trucks: VBoxContainer
var from_ob: OptionButton
var to_ob: OptionButton
var what_ob: OptionButton
var amount: SpinBox
var status: Label
var _sites: Array = []
var _dests: Array = []
const WHAT := ["cash", "cocaine", "marijuana", "the armoury", "rifles", "pistols", "machine guns", "RPGs"]
const TIER := {"rifles": "rifle", "pistols": "pistol", "machine guns": "mg", "RPGs": "rpg"}
const BUYERS := [["family", "the Morettis (town)"], ["agency", "the Company (north)"], ["rival", "Los Cuervos (west)"]]


func _ready() -> void:
	layer = 70
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.theme = UIStyle.theme()
	add_child(root)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UIStyle.box(Color(0.06, 0.02, 0.09, 0.95), 10, UIStyle.ACCENT, 2, Vector4(20, 14, 20, 14)))
	panel.anchor_left = 0.14
	panel.anchor_right = 0.86
	panel.anchor_top = 0.08
	panel.anchor_bottom = 0.92
	root.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	v.add_child(UIStyle.title("Logistics", 28, UIStyle.ACCENT))
	v.add_child(UIStyle.caption("Product sells only where it sits; wages and loads are paid from the club's safe; the growers want cash on the strip."))
	rows = VBoxContainer.new()
	v.add_child(rows)
	var order := HBoxContainer.new()
	order.add_theme_constant_override("separation", 8)
	v.add_child(order)
	what_ob = OptionButton.new()
	for w in WHAT:
		what_ob.add_item(w)
	from_ob = OptionButton.new()
	to_ob = OptionButton.new()
	amount = SpinBox.new()
	amount.max_value = 1e9
	amount.step = 10
	amount.value = 0
	amount.tooltip_text = "0 = all of it"
	for c in [UIStyle.label("Send", 15), what_ob, UIStyle.label("from", 15), from_ob, UIStyle.label("to", 15), to_ob, amount]:
		order.add_child(c)
	var go := Button.new()
	go.text = "Truck it"
	go.focus_mode = Control.FOCUS_NONE
	go.pressed.connect(_send)
	order.add_child(go)
	var home := Button.new()
	home.text = "All cash home"
	home.focus_mode = Control.FOCUS_NONE
	home.pressed.connect(_all_home)
	order.add_child(home)
	if pilot:
		var bags := HBoxContainer.new()
		bags.add_theme_constant_override("separation", 8)
		v.add_child(bags)
		var load_b := Button.new()
		load_b.text = "Load cash bags here (C)"
		load_b.focus_mode = Control.FOCUS_NONE
		load_b.pressed.connect(func(): _act(cmd_fn.call("load_cash", {"amount": amount.value if amount.value > 0 else 1e12})))
		bags.add_child(load_b)
		var unload_b := Button.new()
		unload_b.text = "Unload the bags here (U)"
		unload_b.focus_mode = Control.FOCUS_NONE
		unload_b.pressed.connect(func(): _act(cmd_fn.call("unload_cash", {})))
		bags.add_child(unload_b)
	v.add_child(UIStyle.caption("ON THE ROAD"))
	trucks = VBoxContainer.new()
	trucks.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(trucks)
	status = UIStyle.caption("H or ESC close")
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(status)
	refresh()


func refresh() -> void:
	var lv: Dictionary = view_fn.call()
	for c in rows.get_children():
		c.queue_free()
	for c in trucks.get_children():
		c.queue_free()
	if lv.is_empty():
		rows.add_child(UIStyle.label("No logistics in this game.", 15))
		return
	rows.add_child(UIStyle.label("%-26s %-6s %9s %9s %10s" % ["", "market", "coke lb", "grass lb", "cash"], 14, UIStyle.DIM, UIStyle.mono()))
	var ids: Array = lv.sites.filter(func(s): return not s.burned).map(func(s): return s.id)
	var rebuild: bool = ids != _sites
	if rebuild:
		_sites = []
		_dests = []
		from_ob.clear()
		to_ob.clear()
	for s in lv.sites:
		var l := UIStyle.label("%-26s %-6s %9d %9d %10s%s" % [str(s.name).left(26), s.market, int(s.cocaine), int(s.marijuana),
			"$" + Py.money(int(s.cash)), "  BURNED" if s.burned else ""], 14, UIStyle.RED if s.burned else UIStyle.WHITE, UIStyle.mono())
		rows.add_child(l)
		if not s.burned and rebuild:
			_sites.append(s.id)
			from_ob.add_item(str(s.name))
			_dests.append(s.id)
			to_ob.add_item(str(s.name))
	rows.add_child(UIStyle.label("%-26s  the safe: wages, loads, lawyers   cash aboard: $%s" % [str(lv.hq).left(26), Py.money(int(lv.aboard))], 14, UIStyle.CYAN))
	var arm: Dictionary = lv.get("armoury", {})
	if not arm.is_empty():
		rows.add_child(UIStyle.label("The armoury at %s: %s" % [arm.at, Arsenal.describe(arm.weapons) if int(arm.count) > 0 else "empty"], 14, UIStyle.AMBER))
	if rebuild:
		_dests.append(Logistics.HQ)
		to_ob.add_item(str(lv.hq) + " (cash)")
		for b in BUYERS:
			_dests.append(b[0])
			to_ob.add_item("sell: " + b[1])
		to_ob.select(_dests.size() - 4)  # the club
	for t in lv.trucks:
		trucks.add_child(UIStyle.label("%s: %s -> %s, %d min" % [t.what, t.from, t.to, int(ceil(t.eta / 60.0))], 14))
	if lv.trucks.is_empty():
		trucks.add_child(UIStyle.caption("nothing on the road"))
	if str(lv.last) != "":
		trucks.add_child(UIStyle.caption(str(lv.last)))
	var lost: Dictionary = lv.get("lost", {})
	if float(lost.get("product", 0)) > 0 or int(lost.get("cash", 0)) > 0:
		trucks.add_child(UIStyle.caption("Lost so far: %d lb, $%s" % [int(lost.product), Py.money(int(lost.cash))]))


func _send() -> void:
	if _sites.is_empty():
		return
	var what: String = WHAT[what_ob.selected]
	var from: String = _sites[from_ob.selected]
	var to: String = _dests[to_ob.selected]
	var r: Array
	if what == "the armoury":
		r = cmd_fn.call("move_armoury", {"to": to})  # all of it (the 'from' is wherever it is)
	elif TIER.has(what):
		if not to in ["family", "agency", "rival"]:
			r = [false, "Guns move as the whole armoury - pick 'the armoury' to move it."]
		else:
			r = cmd_fn.call("sell_product", {"buyer": to, "good": "guns", "tier": TIER[what], "qty": amount.value if amount.value > 0 else 1e9})
	elif what == "cash":
		r = cmd_fn.call("move_cash", {"from": from, "to": to, "amount": amount.value if amount.value > 0 else 1e12})
	elif to in ["family", "agency", "rival"]:
		r = cmd_fn.call("sell_product", {"buyer": to, "good": what, "qty": amount.value if amount.value > 0 else 1e9, "from": from})
	else:
		r = cmd_fn.call("move_goods", {"from": from, "to": to, "good": what, "lb": amount.value if amount.value > 0 else 1e9})
	_act(r)


func _all_home() -> void:
	var lv: Dictionary = view_fn.call()
	var n := 0
	for s in lv.get("sites", []):
		if int(s.cash) > 0 and not s.burned:
			var r: Array = cmd_fn.call("move_cash", {"from": s.id, "to": Logistics.HQ})
			if r[0]:
				n += 1
	_act([true, "%d cash truck(s) heading home." % n if n > 0 else "No cash out in the stashes."])


func _act(r: Array) -> void:
	status.text = str(r[1]) if not r[0] or str(r[1]) != "ok" else "Done."
	refresh()


func _process(_dt: float) -> void:
	if Engine.get_process_frames() % 30 == 0:
		refresh()


func _input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and not ev.echo:
		match ev.physical_keycode:
			KEY_ESCAPE, KEY_H:
				close()
			KEY_C:
				if pilot:
					_act(cmd_fn.call("load_cash", {"amount": amount.value if amount.value > 0 else 1e12}))
			KEY_U:
				if pilot:
					_act(cmd_fn.call("unload_cash", {}))
		get_viewport().set_input_as_handled()


func close() -> void:
	closed.emit()
	queue_free()
