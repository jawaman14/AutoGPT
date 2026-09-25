class_name StationApp
extends Control
## Station client for the non-flying seats (port of station.py): a tactical
## map on the left and the seat's own desk on the right, driven entirely by
## role-filtered snapshots through a NetClient (remote) or LocalLink (offline).
##
##   copilot     Load / Jobs / Flight tabs: move items between stations, fuel,
##               loadmaster, accept/drop jobs, kick, pump, call the boat
##   spotter     send the spotter to a strip
##   boat        right-click the map to send the go-fast
##   controller  the task-force desk: click a unit, right-click to dispatch,
##               or click a track; launch, recall, encryption, aerostat
##   boss/chief  the HQ order menus (HQOrders): every order with cost, effect
##               and current state; LEFT/RIGHT sets it, ENTER issues it
## The Python station's hotkeys all still work.

const RUNNER_TABS := ["Load", "Jobs", "Flight"]

var link  ## NetClient or LocalLink
var role := ""
var world: World
var map: StationMap
var title: Label
var status_lbl: Label
var help_lbl: Label
var body: VBoxContainer
var info: Label
var list: ItemList
var detail: Label
var tabs: TabBar
var chart: CGChart
var buttons: HFlowContainer
var orders: HQOrders
var order_rows: Array = []
var sel_unit = null
var status := ""
var _pending: Array = []
var _list_kind := ""
var _list_keys: Array = []
var _last_seq = null


## vertical: map above the desk (narrow panes, e.g. the split-screen demo).
func setup(link_, role_: String, world_: World = null, vertical := false) -> StationApp:
	link = link_
	role = role_
	world = world_ if world_ != null else World.new()
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.04, 0.05, 0.07)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var h: BoxContainer = VBoxContainer.new() if vertical else HBoxContainer.new()
	h.set_anchors_preset(Control.PRESET_FULL_RECT)
	h.add_theme_constant_override("separation", 10)
	add_child(h)
	map = StationMap.new().setup(world)
	map.role = role
	map.custom_minimum_size = Vector2(340, 340) if vertical else Vector2(700, 700)
	map.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map.size_flags_vertical = Control.SIZE_EXPAND_FILL
	map.size_flags_stretch_ratio = 1.0 if vertical else 1.15
	map.clicked.connect(_on_map_click)
	h.add_child(map)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UIStyle.panel_box(Color(0.08, 0.09, 0.12)))
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(panel)
	body = VBoxContainer.new()
	body.add_theme_constant_override("separation", 6)
	panel.add_child(body)
	title = UIStyle.label("", 22, UIStyle.AMBER)
	body.add_child(title)
	if role == Roles.COPILOT:
		tabs = TabBar.new()
		for t in RUNNER_TABS:
			tabs.add_tab(t)
		tabs.focus_mode = Control.FOCUS_NONE
		tabs.tab_changed.connect(func(_i): _list_kind = "")
		body.add_child(tabs)
	info = UIStyle.label("", 14, Color(0.9, 0.95, 1), UIStyle.mono())
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(info)
	list = GameMenu.make_list()
	list.custom_minimum_size = Vector2(0, 220)
	list.item_activated.connect(func(_i): _key("enter"))
	body.add_child(list)
	detail = UIStyle.label("", 14, UIStyle.DIM)
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(detail)
	buttons = HFlowContainer.new()
	body.add_child(buttons)
	if role == Roles.COPILOT:
		chart = CGChart.new()
		chart.custom_minimum_size = Vector2(0, 180)
		body.add_child(chart)
	status_lbl = UIStyle.label("", 15, Color(1, 0.5, 0.4))
	body.add_child(status_lbl)
	help_lbl = UIStyle.label(_help(), 13, Color(0.7, 0.7, 0.7), UIStyle.mono())
	help_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(help_lbl)
	if role in [Roles.BOSS, Roles.CHIEF]:
		orders = HQOrders.new("runner" if role == Roles.BOSS else "law")
	_build_buttons()
	return self


func _help() -> String:
	match role:
		Roles.COPILOT:
			return "[1][2][3] tabs  UP/DOWN select  LEFT/RIGHT move item  A loadmaster  +/- fuel  F ferry\nENTER accept/drop job  K kick  O call boat  V pump  T auto-kick"
		Roles.SPOTTER:
			return "UP/DOWN pick a strip  ENTER send the spotter there (60 s)"
		Roles.BOAT:
			return "Right-click the map to send the go-fast there"
		Roles.CONTROLLER:
			return "Click a unit, then right-click the map (or click a track) to dispatch.\nH heli  I interceptor  C cutter (to mouse)  R recall  E encryption  B aerostat  TAB next unit"
		Roles.BOSS, Roles.CHIEF:
			return "UP/DOWN pick an order  LEFT/RIGHT change it  ENTER issue.  Old hotkeys work too."
	return ""


func _btn(text: String, fn: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(fn)
	buttons.add_child(b)


func _build_buttons() -> void:
	match role:
		Roles.COPILOT:
			_btn("< station", func(): _key("left"))
			_btn("station >", func(): _key("right"))
			_btn("Loadmaster", func(): _key("a"))
			_btn("Fuel -10%", func(): _key("-"))
			_btn("Fuel +10%", func(): _key("+"))
			_btn("Fill ferry", func(): _key("f"))
			_btn("Accept/drop job", func(): _key("enter"))
			_btn("Kick", func(): _key("k"))
			_btn("Pump", func(): _key("v"))
			_btn("Call boat", func(): _key("o"))
			_btn("Auto-kick", func(): _key("t"))
		Roles.SPOTTER:
			_btn("Send spotter", func(): _key("enter"))
		Roles.CONTROLLER:
			_btn("Launch heli", func(): _key("h"))
			_btn("Launch interceptor", func(): _key("i"))
			_btn("Launch cutter", func(): _key("c"))
			_btn("Recall", func(): _key("r"))
			_btn("Next unit", func(): _key("tab"))
			_btn("Encryption", func(): _key("e"))
			_btn("Aerostat", func(): _key("b"))
		Roles.BOSS, Roles.CHIEF:
			_btn("<", func(): _key("left"))
			_btn(">", func(): _key("right"))
			_btn("Issue order", func(): _key("enter"))
			_btn("Ready", func(): _cmd("hq", {"order": "ready"}))


# ------------------------------------------------------------ commands
func _cmd(name: String, args := {}) -> void:
	var seq: int = link.send_command(name, args)
	if link is LocalLink:
		status = "" if link.last_result[0] else link.last_result[1]
	else:
		_pending.append(seq)
		status = ""


func _check_acks() -> void:
	for seq in _pending.duplicate():
		if link.acks.has(seq):
			_pending.erase(seq)
			var r: Array = link.acks[seq]
			link.acks.erase(seq)
			if not r[0]:
				status = r[1]


# ------------------------------------------------------------ input
func _unhandled_key_input(ev: InputEvent) -> void:
	if not (ev is InputEventKey and ev.pressed):
		return
	var k: int = ev.physical_keycode if ev.physical_keycode else ev.keycode
	var name := ""
	match k:
		KEY_UP: name = "up"
		KEY_DOWN: name = "down"
		KEY_LEFT: name = "left"
		KEY_RIGHT: name = "right"
		KEY_ENTER, KEY_KP_ENTER: name = "enter"
		KEY_PLUS, KEY_EQUAL, KEY_KP_ADD: name = "+"
		KEY_MINUS, KEY_KP_SUBTRACT: name = "-"
		KEY_TAB: name = "tab"
		KEY_ESCAPE:
			get_tree().quit()
			return
		_:
			if k >= KEY_A and k <= KEY_Z:
				name = char(k).to_lower()
			elif k >= KEY_1 and k <= KEY_4:
				name = char(k)
	if name == "" or ev.echo and not name in ["up", "down", "left", "right"]:
		return
	_key(name)
	get_viewport().set_input_as_handled()


func _key(k: String) -> void:
	var snap = link.snapshot()
	if not (snap is Dictionary):
		return
	if role == Roles.COPILOT and k in ["1", "2", "3"]:
		tabs.current_tab = int(k) - 1
		return
	match role:
		Roles.BOSS, Roles.CHIEF:
			_hq_key(k, snap)
		Roles.CONTROLLER:
			_law_key(k, snap)
		Roles.SPOTTER:
			if k in ["up", "down"]:
				GameMenu.list_move(list, 1 if k == "down" else -1)
			elif k == "enter" and GameMenu.selected(list) >= 0:
				_cmd("spotter_move", {"code": World.AIRFIELDS[GameMenu.selected(list)].code})
		_:
			_runner_key(k, snap)


func _runner_key(k: String, snap: Dictionary) -> void:
	var crew := {"k": "kick", "o": "call_boat", "v": "pump", "t": "auto_kick"}
	if crew.has(k):
		_cmd(crew[k])
		return
	var tab: String = RUNNER_TABS[tabs.current_tab] if tabs != null else "Flight"
	if k in ["up", "down"]:
		GameMenu.list_move(list, 1 if k == "down" else -1)
		return
	var i := GameMenu.selected(list)
	if tab == "Load":
		var lo: Dictionary = snap.get("loadout", {})
		if k in ["left", "right"] and i >= 0 and i < _list_keys.size():
			_cmd("move_item", {"item_id": _list_keys[i], "direction": 1 if k == "right" else -1})
		elif k == "a":
			_cmd("loadmaster")
		elif k in ["+", "-"]:
			_cmd("set_fuel", {"lb": float(lo.get("fuel", 0)) + (0.1 if k == "+" else -0.1) * float(lo.get("fuel_cap", 0))})
		elif k == "f":
			_cmd("fill_ferry", {"lb": 10000})
	elif tab == "Jobs" and k == "enter" and i >= 0 and i < _list_keys.size():
		var r: Array = _list_keys[i]
		_cmd("accept_job" if r[0] == "board" else "drop_job", {"job_id": r[1]})


func _hq_key(k: String, snap: Dictionary) -> void:
	var ss = snap.get("season")
	if not (ss is Dictionary):
		return
	var i := GameMenu.selected(list)
	match k:
		"up", "down":
			GameMenu.list_move(list, 1 if k == "down" else -1)
			return
		"left", "right":
			if i >= 0 and i < order_rows.size():
				orders.adjust(order_rows[i], 1 if k == "right" else -1, ss)
			return
		"enter":
			if i >= 0 and i < order_rows.size():
				var r: Dictionary = order_rows[i]
				var args := {"order": r.order}
				args.merge(r.args)
				_cmd("hq", args)
			return
	# the Python station's hotkeys
	var o: Dictionary = ss.get("org", {})
	var L: Dictionary = ss.get("law", {})
	if role == Roles.BOSS:
		var simple := {"1": ["launder", {}], "2": ["buy_front", {"kind": "laundromat"}], "3": ["buy_front", {"kind": "car_lot"}],
			"4": ["buy_front", {"kind": "marina"}], "p": ["opsec", {}], "c": ["counterintel", {}], "y": ["loyalty", {}],
			"z": ["lie_low", {}], "u": ["upgrade", {}], "g": ["gear", {"name": "scanner"}], "h": ["gear", {"name": "detector"}]}
		if simple.has(k):
			var a := {"order": simple[k][0]}
			a.merge(simple[k][1])
			_cmd("hq", a)
		elif k == "l":
			_cmd("hq", {"order": "lawyer", "on": not o.get("lawyer", false)})
		elif k == "k":
			_cmd("hq", {"order": "crews", "n": (int(o.get("crews", 0)) + 1) % 3})
		elif k == "d":
			_cmd("hq", {"order": "decoys", "n": (int(o.get("decoys", 0)) + 1) % 3})
		elif k == "r":
			_cmd("hq", {"order": "route", "zone": HQOrders.ZONES[(HQOrders.ZONES.find(o.get("route", "west")) + 1) % 3]})
	else:
		var simple := {"a": "aerostat", "r": "recruit", "w": "wiretap", "u": "audit", "s": "ia_sweep", "e": "encryption", "p": "press"}
		if simple.has(k):
			_cmd("hq", {"order": simple[k]})
		elif k in ["h", "i", "c"]:
			var unit: String = {"h": "heli", "i": "interceptor", "c": "cutter"}[k]
			_cmd("hq", {"order": "fund", "unit": unit, "n": (int(L.get("funded", {}).get(unit, 0)) + 1) % 4})
		elif k == "z":
			var cur = L.get("patrol")
			var zs := [null] + HQOrders.ZONES
			_cmd("hq", {"order": "patrol", "zone": zs[(zs.find(cur) + 1) % 4]})


func _law_key(k: String, snap: Dictionary) -> void:
	var pos = map.mouse_world()
	var units: Array = snap.get("units", []).filter(func(u): return u.state != "crashed")
	match k:
		"tab":
			if not units.is_empty():
				var ids := units.map(func(u): return u.id)
				sel_unit = ids[(ids.find(sel_unit) + 1) % ids.size()] if sel_unit in ids else ids[0]
		"h", "i", "c":
			var a := {"kind": {"h": "heli", "i": "interceptor", "c": "cutter"}[k]}
			if pos != null:
				a.merge({"x": pos.x, "y": pos.y})
			_cmd("launch", a)
		"r":
			if sel_unit != null:
				_cmd("recall", {"unit": sel_unit})
		"e":
			_cmd("encrypt", {"on": not snap.get("encrypted", false)})
		"b":
			_cmd("aerostat", {"on": snap.get("aerostat") == "down"})
		"up", "down":
			GameMenu.list_move(list, 1 if k == "down" else -1)
			var i := GameMenu.selected(list)
			if i >= 0 and i < _list_keys.size():
				sel_unit = _list_keys[i]


func _on_map_click(button: int, p: Vector2) -> void:
	var snap = link.snapshot()
	if not (snap is Dictionary):
		return
	if role == Roles.BOAT and button == MOUSE_BUTTON_RIGHT:
		_cmd("boat_goto", {"x": p.x, "y": p.y})
		return
	if role != Roles.CONTROLLER:
		return
	var near := func(items: Array):
		return Py.min_by(items, func(o): return PyMath.hypot(o.x - p.x, o.y - p.y))
	if button == MOUSE_BUTTON_LEFT:
		var u = near.call(snap.get("units", []))
		if u != null and PyMath.hypot(u.x - p.x, u.y - p.y) < 1200:
			sel_unit = u.id
			return
		var t = near.call(snap.get("tracks", []))
		if sel_unit != null and t != null and PyMath.hypot(t.x - p.x, t.y - p.y) < 1200:
			_cmd("dispatch", {"unit": sel_unit, "target": t.id})
	elif button == MOUSE_BUTTON_RIGHT and sel_unit != null:
		_cmd("dispatch", {"unit": sel_unit, "x": p.x, "y": p.y})


# ------------------------------------------------------------ drawing
func _process(delta: float) -> void:
	var dt := minf(delta, 0.1)
	link.tick(dt)
	var snap = link.snapshot()
	map.snap = snap
	map.sel_unit = sel_unit
	if not (snap is Dictionary):
		title.text = "Connecting..." if link.error == null else "Disconnected: %s" % link.error
		return
	_check_acks()
	if snap.get("seq") != _last_seq or link is LocalLink:
		_last_seq = snap.get("seq")
		match role:
			Roles.BOSS, Roles.CHIEF:
				_draw_hq(snap)
			Roles.CONTROLLER:
				_draw_law(snap)
			_:
				_draw_runner(snap)
	status_lbl.text = status if status != "" else ("Link lost: %s" % link.error if link.error != null and not link.alive() else "")


## Refill the list only when its rows change, so selection and scroll survive.
func _set_list(kind: String, keys: Array, texts: Array, colors := {}) -> void:
	if kind != _list_kind or keys != _list_keys:
		var keep := GameMenu.selected(list)
		list.clear()
		for t in texts:
			list.add_item(t)
		_list_kind = kind
		_list_keys = keys
		if list.item_count > 0:
			list.select(clampi(keep, 0, list.item_count - 1))
	else:
		for i in texts.size():
			list.set_item_text(i, texts[i])
	for i in colors:
		if i < list.item_count:
			list.set_item_custom_fg_color(i, colors[i])


func _draw_runner(snap: Dictionary) -> void:
	var ac = snap.get("aircraft")
	title.text = "%s - %s   $%s" % [role.to_upper(), snap.mode, Py.money(int(snap.get("money", 0)))]
	var lines := []
	if ac is Dictionary:
		lines += [
			"%s  %s%s" % [ac.type, ac.phase, (" @" + ac.location) if ac.location else ""],
			"IAS %.0fkt  GS %.0f  ALT %.0fft  HDG %.0f" % [ac.ias, ac.gs, ac.alt / 0.3048, ac.heading],
			"FUEL %.0f lb + ferry %.0f  range %.0f km  %s" % [ac.fuel, ac.ferry_fuel, ac.range_km, "PUMP ON" if ac.pumping else ""],
			"XPDR %s  AP %s  RADAR %s  WANTED %s" % ["ON " + ac.squawk if ac.transponder else "OFF", "ON" if ac.autopilot else "off",
				ac.detector if ac.detector else "-", "*".repeat(int(ac.wanted))],
			"KICK queue %d  auto-kick %s" % [int(ac.kick_queue), "on" if ac.auto_kick else "off"],
		]
		if ac.outcome:
			lines.append(ac.outcome)
	if snap.has("campaign"):
		var c: Dictionary = snap.campaign
		lines += ["", "CH%d %d %s" % [int(c.chapter), int(c.year), c.title]] + c.objectives
	var tab: String = RUNNER_TABS[tabs.current_tab] if tabs != null else ("Spotter" if role == Roles.SPOTTER else "Flight")
	var lo: Dictionary = snap.get("loadout", {})
	if chart != null:
		chart.visible = tab == "Load"
	if tab == "Load":
		var wb: Dictionary = lo.get("wb", {})
		lines.append("LOAD  %.0f/%.0f lb  CG %.1f (%.1f-%.1f)  %s  crew %d" % [wb.get("weight", 0), wb.get("mtow", 0), wb.get("cg", 0),
			wb.get("fwd", 0), wb.get("aft", 0), "OK" if wb.get("ok") else "OUT OF LIMITS", int(lo.get("crew", 0))])
		lines.append("fuel %.0f / %.0f lb" % [lo.get("fuel", 0), lo.get("fuel_cap", 0)])
		var items: Array = lo.get("items", [])
		_set_list("load", items.map(func(it): return it.id), items.map(func(it): return "%-16s %5.0f lb -> %s%s" % [str(it.label).substr(0, 16),
			it.weight, it.station if it.station else "RAMP", (" loading %.0fs" % it.pending) if it.pending else ""]))
		if chart != null and ac is Dictionary:
			chart.set_data(Aircraft.spec(ac.key), Vector2(wb.get("cg", 0), wb.get("weight", 0)), Vector2(wb.get("cg", 0), wb.get("weight", 0) - lo.get("fuel", 0)), wb.get("ok", false))
	elif tab == "Jobs":
		var rows := []
		var texts := []
		for j in snap.get("board", []):
			rows.append(["board", j.id])
			texts.append("+ %-34s $%s" % [str(j.title).substr(0, 34), Py.money(int(j.payout))])
		for j in snap.get("jobs", []):
			rows.append(["active", j.id])
			texts.append("* %-34s $%s" % [str(j.title).substr(0, 34), Py.money(int(j.payout))])
		if rows.is_empty():
			lines.append("(park at a field to see its board)")
		_set_list("jobs", rows, texts)
	elif tab == "Spotter":
		_set_list("spotter", World.AIRFIELDS.map(func(a): return a.code), World.AIRFIELDS.map(func(a): return "%s %s" % [a.code, a.name]))
		lines.append("Spotters at: " + ", ".join(snap.get("spotters", []).map(func(sp): return sp.code)))
	else:
		_set_list("none", [], [])
	var sc = snap.get("scanner")
	lines.append("")
	lines.append("SCANNER:" if sc != null else "(no scanner fitted)")
	for m in (sc if sc != null else []).slice(-4):
		lines.append("  " + str(m).substr(0, 56))
	lines.append("")
	lines += snap.get("messages", []).slice(-5)
	info.text = "\n".join(lines)


func _draw_hq(snap: Dictionary) -> void:
	var ss = snap.get("season")
	if not (ss is Dictionary):
		title.text = "No HQ in this game (needs layer 5 / --players 5+)"
		info.text = ""
		return
	var head := "NIGHT %d/%d  %s" % [int(ss.night), int(ss.nights), str(ss.phase).to_upper()]
	if ss.winner:
		head += "  -  %s WINS (%s)" % ["ORGANISATION" if ss.winner == "runner" else "TASK FORCE", ss.reason]
	var lines := ["Public: heat %d   task-force support %d" % [int(ss.public.heat), int(ss.public.support)]]
	if role == Roles.BOSS:
		var o: Dictionary = ss.org
		title.text = "THE ORGANISATION  -  " + head
		var ev = ss.get("evidence")
		lines += [
			"Dirty $%s   Clean $%s / $%s to retire" % [Py.money(int(o.dirty)), Py.money(int(o.clean)), Py.money(int(ss.retire_target))],
			"Fronts: %s  (wash $%s/night)" % [", ".join(o.fronts) if o.fronts else "none", Py.money(int(ss.capacity))],
			"Case against you: %s%s" % [ss.evidence_rumor, (" (%.0f/100 - your sources)" % ev) if ev != null else ""],
			"Moves left tonight: %d%s" % [int(o.actions), "   READY" if o.ready else ""],
		]
		if ss.get("patrol_leak"):
			lines.append("Dispatcher: the patrol goes %s tonight" % ss.patrol_leak)
	else:
		var L: Dictionary = ss.law
		title.text = "TASK FORCE HQ  -  " + head
		var est = ss.get("clean_estimate")
		lines += [
			"Evidence %.0f/%.0f   budget $%.0fk tonight   support %.0f" % [L.evidence, ss.indict_evidence, L.budget_k, L.support],
			"Known fronts %d   laundered estimate %s" % [int(ss.known_fronts), ("$" + Py.money(int(est))) if est else "unknown"],
			"Moves left tonight: %d%s" % [int(L.actions), "   READY" if L.ready else ""],
		]
	var rv = ss.get("rival")
	if rv is Dictionary:
		if role == Roles.BOSS:
			lines.append("%s: %s%s%s" % [rv.name, rv.band, ("   truce %d nights" % int(rv.truce_nights)) if rv.truce_nights else "",
				"   OUT FOR REVENGE" if rv.grudge else ""])
		else:
			lines.append("%s: %s, %d busted" % [rv.name, rv.band, int(rv.busts)])
	lines += HQOrders.realism_lines(ss, "runner" if role == Roles.BOSS else "law")
	lines += ["", "NEWS:"] + ss.get("news", []).slice(-4).map(func(n): return "  " + str(n).substr(0, 70))
	lines += ["LOG:"] + ss.get("log", []).slice(-5).map(func(n): return "  " + str(n).substr(0, 70))
	info.text = "\n".join(lines)
	order_rows = orders.rows(ss)
	var colors := {}
	for i in order_rows.size():
		if order_rows[i].key == "ready":
			colors[i] = UIStyle.GREEN
	_set_list("orders", order_rows.map(func(r): return r.key), order_rows.map(func(r): return "%-34s %s" % [r.label, r.state]), colors)
	var i := GameMenu.selected(list)
	detail.text = order_rows[i].detail if i >= 0 and i < order_rows.size() else ""


func _draw_law(snap: Dictionary) -> void:
	title.text = "TASK FORCE DESK - %s" % snap.mode
	var sc: Dictionary = snap.score
	var rs: Dictionary = snap.runner_score
	var cases: Array = Py.sorted_by(snap.get("cases", []), func(c): return -c.suspicion)
	var lines := [
		"Stock  heli %d  interceptor %d  cutter %d" % [int(snap.stock.get("heli", 0)), int(snap.stock.get("interceptor", 0)), int(snap.stock.get("cutter", 0))],
		"Radio %s   Aerostat %s" % ["ENCRYPTED" if snap.encrypted else "plain (scanners can hear you)", snap.aerostat],
		"Score: busts %d  boats %d  bales %d  | runners: bales in %d  escaped %d" % [int(sc.busts), int(sc.boats_seized), int(sc.bales_seized),
			int(rs.bales_delivered), int(rs.escapes)],
		"Selected: %s" % (sel_unit if sel_unit != null else "-"), "", "CASES:",
	]
	for c in cases.slice(0, 6):
		lines.append("  %-10s susp %3.0f%%  wanted %s%s" % [c.id, c.suspicion, "*".repeat(int(c.wanted)), "  TIPPED" if c.tipped else ""])
	if cases.is_empty():
		lines.append("  (quiet)")
	lines += ["", "RADIO / ALERTS:"] + snap.get("messages", []).slice(-8).map(func(m): return "  " + str(m).substr(0, 60))
	info.text = "\n".join(lines)
	var units: Array = snap.get("units", [])
	_set_list("units", units.map(func(u): return u.id), units.map(func(u): return "%-10s %-11s %-8s %s" % [u.id, u.kind, u.state,
		("-> " + str(u.target)) if u.target else ""]))
