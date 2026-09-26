class_name StationApp
extends Control
## Station client for the non-flying seats (port of station.py): a tactical
## map on the left and the seat's own desk on the right, driven entirely by
## role-filtered snapshots through a NetClient (remote) or LocalLink (offline).
##
##   copilot     Flight / Load / Jobs tabs over live tiles (speed, fuel, ferry
##               and pump, kick queue, boat): kick, pump, call the boat, move
##               items, fuel, loadmaster, accept/drop jobs; click a strip on the
##               map to hire a spotter there; a chat line to the pilot
##   spotter     send the spotter to a strip
##   boat        right-click the map to send the go-fast
##   controller  the task-force desk: click a unit, right-click to dispatch,
##               or click a track; launch, recall, encryption, aerostat
##   boss/chief  the HQ order menus (HQOrders): every order with cost, effect
##               and current state; LEFT/RIGHT sets it, ENTER issues it
## The Python station's hotkeys all still work, every one of them is also a
## clickable key cap in the footer, and ESC asks before leaving the seat.

const RUNNER_TABS := ["Flight", "Load", "Jobs"]
const FLIGHT_ACTIONS := [["kick", "Kick the bales", "K"], ["auto_kick", "Auto-kick over the mark", "T"],
	["pump", "Ferry pump", "V"], ["call_boat", "Call the boat", "O"], ["codeword", "Codeword to the boat (1 s burst)", "B"],
	["spotter", "Hire a spotter", "click map"]]

var link  ## NetClient or LocalLink
var role := ""
var world: World
var map: StationMap
var title: Label
var subtitle: Label
var status_lbl: Label
var hints: KeyHints
var body: VBoxContainer
var info: Label
var list: DataTable
var detail: Label
var tabs: TabBar
var chart: CGChart
var buttons: HFlowContainer
var tiles := {}
var chips := {}
var board: HQBoard
var chat: LineEdit
var confirm: ConfirmBox
var orders: HQOrders
var order_rows: Array = []
var sel_unit = null
var squad_mode := false  ## Q: the map commands our ground squads (the default desk for lieutenant and patrol)
var sel_squad = null
var status := ""
var _pending: Array = []
var _list_kind := ""
var _list_keys: Array = []
var upgrades: UpgradeTree  ## the controller's upgrade trees (U)
var _upg_sig := ""
var _last_seq = null


## vertical: map above the desk (narrow panes, e.g. the split-screen demo).
func setup(link_, role_: String, world_: World = null, vertical := false) -> StationApp:
	link = link_
	role = role_
	world = world_ if world_ != null else World.new()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = UIStyle.theme()
	var bg := ColorRect.new()
	bg.color = Color(0.035, 0.04, 0.055)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var h: BoxContainer = VBoxContainer.new() if vertical else HBoxContainer.new()
	h.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	h.add_theme_constant_override("separation", 10)
	add_child(h)
	map = StationMap.new().setup(world)
	map.role = role
	map.custom_minimum_size = Vector2(340, 340) if vertical else Vector2(640, 640)
	map.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# desks with wide tables (HQ, task force) get more of the screen than the co-pilot's
	map.size_flags_stretch_ratio = 1.0 if vertical else (0.8 if role in [Roles.BOSS, Roles.CHIEF, Roles.CONTROLLER] else 1.1)
	if role in [Roles.BOSS, Roles.CHIEF, Roles.CONTROLLER] and not vertical:
		map.custom_minimum_size = Vector2(520, 520)
	map.clicked.connect(_on_map_click)
	h.add_child(map)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UIStyle.box(Color(0.06, 0.07, 0.095), 0, UIStyle.LINE, 0, Vector4(16, 12, 16, 12)))
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(panel)
	body = VBoxContainer.new()
	body.add_theme_constant_override("separation", 8)
	panel.add_child(body)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	body.add_child(head)
	title = UIStyle.title("", 28)
	head.add_child(title)
	subtitle = UIStyle.label("", 14, UIStyle.CAPTION)
	subtitle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	subtitle.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	subtitle.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	head.add_child(subtitle)
	if role in [Roles.BOSS, Roles.CHIEF]:
		board = HQBoard.new().setup("runner" if role == Roles.BOSS else "law")
		body.add_child(board)
		list = board.table
		orders = board.orders
		list.row_activated.connect(func(_i): _key("enter"))
	else:
		if Roles.side(role) == "runner" and not role in [Roles.SPOTTER, Roles.BOAT, Roles.LIEUTENANT]:
			_build_runner_tiles()
		if role == Roles.COPILOT:
			tabs = TabBar.new()
			for t in RUNNER_TABS:
				tabs.add_tab(t)
			tabs.focus_mode = Control.FOCUS_NONE
			tabs.tab_changed.connect(func(_i): _list_kind = "")
			body.add_child(tabs)
		list = DataTable.new().setup([{"title": "", "expand": true}])
		list.custom_minimum_size = Vector2(0, 200)
		list.row_activated.connect(func(_i): _key("enter"))
		body.add_child(list)
		detail = UIStyle.label("", 14, UIStyle.DIM)
		detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body.add_child(detail)
		if role == Roles.COPILOT:
			chart = CGChart.new()
			chart.custom_minimum_size = Vector2(0, 170)
			body.add_child(chart)
		# radio, scanner and cases scroll inside what's left of the column
		var scroll := ScrollContainer.new()
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.follow_focus = false
		body.add_child(scroll)
		info = UIStyle.label("", 14, Color(0.86, 0.9, 0.96))
		info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.add_child(info)
		list.size_flags_vertical = Control.SIZE_FILL
		if role == Roles.CONTROLLER:
			upgrades = UpgradeTree.new().setup("law")
			upgrades.visible = false
			upgrades.custom_minimum_size = Vector2(0, 360)
			upgrades.buy.connect(func(id): _cmd("upgrade", {"id": id}))
			body.add_child(upgrades)
			body.move_child(upgrades, list.get_index())
	buttons = HFlowContainer.new()  # extra buttons (the key caps below are clickable too)
	buttons.add_theme_constant_override("h_separation", 6)
	buttons.add_theme_constant_override("v_separation", 6)
	body.add_child(buttons)
	chat = LineEdit.new()
	chat.placeholder_text = "Radio to your side - ENTER sends"
	chat.max_length = 200
	chat.text_submitted.connect(func(t):
		if t.strip_edges() != "":
			_cmd("chat", {"text": t.strip_edges()})
		chat.text = ""
		chat.release_focus())
	body.add_child(chat)
	status_lbl = UIStyle.label("", 15, Color(1, 0.5, 0.4))
	status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(status_lbl)
	hints = KeyHints.new()
	hints.hint_pressed.connect(func(a):
		if a == "esc":
			confirm.ask()
		elif a != "":
			_key(a))
	body.add_child(hints)
	if role in [Roles.LIEUTENANT, Roles.PATROL]:
		squad_mode = true  # the whole desk is the squads
		list.row_selected.connect(func(i):
			if i >= 0 and i < _list_keys.size():
				sel_squad = _list_keys[i])
	if role in [Roles.BOSS, Roles.CHIEF] and orders == null:
		orders = HQOrders.new("runner" if role == Roles.BOSS else "law")
	_build_buttons()
	confirm = ConfirmBox.new().setup("Leave the %s seat?" % role, "Leave", "Stay")
	confirm.answered.connect(func(yes):
		if yes:
			get_tree().quit())
	add_child(confirm)
	return self


func _build_runner_tiles() -> void:
	var chip_row := HFlowContainer.new()
	chip_row.add_theme_constant_override("h_separation", 6)
	body.add_child(chip_row)
	for n in ["xpdr", "ap", "radar", "wanted", "crew"]:
		chips[n] = Chip.new().setup(n.to_upper())
		chip_row.add_child(chips[n])
	var g := GridContainer.new()
	g.columns = 4
	g.add_theme_constant_override("h_separation", 6)
	g.add_theme_constant_override("v_separation", 6)
	body.add_child(g)
	for n in [["ias", "IAS kt", false], ["alt", "ALT ft", false], ["hdg", "HDG", false], ["range", "Range", false],
			["fuel", "Fuel lb", true], ["ferry", "Ferry tank", false], ["kick", "Bales / kick", false], ["boat", "Boat", false]]:
		tiles[n[0]] = StatTile.new().setup(n[1], n[2], 17)
		g.add_child(tiles[n[0]])


## Key caps for the footer: [key label, what it does, the _key() action].
func _hints() -> Array:
	var out := []
	match role:
		Roles.COPILOT:
			out = [["1-3", "tabs", ""], ["K", "kick", "k"], ["V", "pump", "v"], ["O", "call boat", "o"], ["B", "codeword", "b"], ["T", "auto-kick", "t"]]
			var tab: String = RUNNER_TABS[tabs.current_tab] if tabs != null else "Flight"
			if tab == "Load":
				out += [["LEFT/RIGHT", "move item", "right"], ["A", "loadmaster", "a"], ["+/-", "fuel 10%", "+"], ["F", "fill ferry", "f"]]
			elif tab == "Jobs":
				out += [["ENTER", "accept / drop", "enter"]]
			else:
				out += [["ENTER", "do it", "enter"]]
		Roles.SPOTTER:
			out = [["UP/DOWN", "pick a strip", "down"], ["ENTER", "send the spotter (60 s)", "enter"]]
		Roles.BOAT:
			out = [["RIGHT-CLICK", "send the go-fast there", ""]]
		Roles.CONTROLLER:
			out = [["CLICK", "unit, then track", ""], ["H", "heli", "h"], ["I", "interceptor", "i"], ["C", "cutter", "c"],
				["R", "recall", "r"], ["E", "encryption", "e"], ["B", "aerostat", "b"], ["G", "coverage", "g"], ["T", "tac channel", "t"], ["J", "jam here", "j"], ["X", "raid stash", "x"], ["U", "upgrades", "u"], ["TAB", "next unit", "tab"]]
			if upgrades != null and upgrades.visible:
				out = [["U", "back to the desk", "u"], ["UP/DOWN", "select", "down"], ["ENTER", "buy", "enter"]]
		Roles.BOSS, Roles.CHIEF:
			out = [["UP/DOWN", "order", "down"], ["LEFT/RIGHT", "change it", "right"], ["ENTER", "issue", "enter"]]
		Roles.LIEUTENANT, Roles.PATROL:
			out = [["UP/DOWN", "squad", "down"]]
	var snap = link.snapshot() if link != null else null
	if snap is Dictionary and commands_squads(snap):
		if squad_mode:
			out = ([] if role in [Roles.LIEUTENANT, Roles.PATROL] else [["Q", "back to the desk", "q"]]) + out.slice(0, 1 if role in [Roles.LIEUTENANT, Roles.PATROL] else 0) + [["CLICK", "squad", ""], ["RIGHT-CLICK", "send it", ""], ["TAB", "next squad", "tab"],
				["A", "checkpoint here" if _own() == "police" else "ambush here", "a"], ["M", "melt away", "m"], ["H", "hold", "h"], ["D", "disband", "d"],
				["F/V/K", "raise foot / car / truck", "f"]]
		else:
			out.append(["Q", "squads", "q"])
	return out + [["ESC", "leave seat", "esc"]]


func _btn(text: String, fn: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 30)
	b.pressed.connect(fn)
	buttons.add_child(b)


func _build_buttons() -> void:
	match role:
		Roles.SPOTTER:
			_btn("Send spotter", func(): _key("enter"))
		Roles.BOSS, Roles.CHIEF:
			_btn("<", func(): _key("left"))
			_btn(">", func(): _key("right"))
			_btn("Issue order  ENTER", func(): _key("enter"))
			_btn("Ready for tonight", func(): _cmd("hq", {"order": "ready"}))
	buttons.visible = buttons.get_child_count() > 0


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
	if confirm.visible:
		if k in [KEY_ENTER, KEY_KP_ENTER, KEY_ESCAPE]:
			confirm.key("esc" if k == KEY_ESCAPE else "enter")
		get_viewport().set_input_as_handled()
		return
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
	if k == "esc":
		confirm.ask()
		return
	if role == Roles.COPILOT and k in ["1", "2", "3"]:
		tabs.current_tab = int(k) - 1
		return
	if k == "q" and commands_squads(snap) and not role in [Roles.LIEUTENANT, Roles.PATROL]:
		squad_mode = not squad_mode
		status = "Squads: click one, right-click to send it" if squad_mode else ""
		return
	if squad_mode and _squad_key(k, snap):
		return
	if role in [Roles.LIEUTENANT, Roles.PATROL]:
		if k in ["up", "down"]:
			GameMenu.list_move(list, 1 if k == "down" else -1)
			var i := GameMenu.selected(list)
			if i >= 0 and i < _list_keys.size():
				sel_squad = _list_keys[i]
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
	if k == "b":
		_cmd("call_boat", {"brief": true})
		return
	var tab: String = RUNNER_TABS[tabs.current_tab] if tabs != null else "Flight"
	if k in ["up", "down"]:
		GameMenu.list_move(list, 1 if k == "down" else -1)
		return
	var i := GameMenu.selected(list)
	if tab == "Flight" and k == "enter" and i >= 0 and i < _list_keys.size():
		var act: String = _list_keys[i]
		if act == "spotter":
			status = "Click a strip on the map to put a spotter there ($%d)." % Session.SPOTTER_FEE
		elif act == "codeword":
			_cmd("call_boat", {"brief": true})
		else:
			_cmd(act)
		return
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
				board.update(ss)
				order_rows = board.rows
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
	if k == "u":
		upgrades.visible = not upgrades.visible
		_upg_sig = ""
		return
	if upgrades.visible:
		if k in ["up", "down"]:
			upgrades.move(1 if k == "down" else -1)
		elif k == "enter":
			upgrades.activate()
		return
	if k == "x":
		# raid the known stash house nearest the mouse (or the hottest one)
		var known: Array = snap.get("stashes", []).filter(func(st): return not st.burned)
		if known.is_empty():
			status = "No stash house known yet: they warm up as loads go through them."
			return
		var pick = Py.max_by(known, func(st): return st.heat) if pos == null else Py.min_by(known, func(st): return PyMath.hypot(st.x - pos.x, st.y - pos.y))
		_cmd("raid_stash", {"id": pick.id})
		return
	if k == "j":
		# the jammer van: at the mouse, else on the latest DF fix
		var fixes: Array = snap.get("df", []).filter(func(d): return d.fix != null)
		if pos == null and not fixes.is_empty():
			pos = Vector2(float(fixes.back().fix[0]), float(fixes.back().fix[1]))
		if pos == null:
			status = "Point at the map (or take a DF fix) to place the jammer."
		else:
			_cmd("jam", {"x": pos.x, "y": pos.y})
		return
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
		"t":
			_cmd("radio_channel", {"channel": "police" if snap.get("radio_channel", "police") == "police_tac" else "police_tac"})
		"g":
			# coverage overlay: off -> blind below 150 / 500 / 1500 m AGL
			var steps := [0.0, 150.0, 500.0, 1500.0]
			map.coverage_agl = steps[(steps.find(map.coverage_agl) + 1) % steps.size()]
		"up", "down":
			GameMenu.list_move(list, 1 if k == "down" else -1)
			var i := GameMenu.selected(list)
			if i >= 0 and i < _list_keys.size():
				sel_unit = _list_keys[i]


func _on_map_click(button: int, p: Vector2) -> void:
	var snap = link.snapshot()
	if not (snap is Dictionary):
		return
	if squad_mode:
		_squad_click(button, p, snap)
		return
	if role == Roles.BOAT and button == MOUSE_BUTTON_RIGHT:
		_cmd("boat_goto", {"x": p.x, "y": p.y})
		return
	if role in [Roles.COPILOT, Roles.SPOTTER] and button == MOUSE_BUTTON_LEFT:
		var af = strip_at(p)
		if af != null:
			if role == Roles.COPILOT:
				_cmd("hire_spotter", {"code": af.code})
			else:
				_cmd("spotter_move", {"code": af.code})
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


# ------------------------------------------------------------------ ground squads
## Seats that can order the ground war's squads (with one running).
func commands_squads(snap: Dictionary) -> bool:
	var g = snap.get("ground")
	return g is Dictionary and not g.is_empty() and role in [Roles.BOSS, Roles.CHIEF, Roles.CONTROLLER, Roles.LIEUTENANT, Roles.PATROL]


func _own() -> String:
	return "police" if Roles.side(role) == "law" else "org"


func _my_squads(snap: Dictionary) -> Array:
	return snap.get("ground", {}).get("squads", []).filter(func(d): return d.faction == _own())


func _squad_key(k: String, snap: Dictionary) -> bool:
	var mine := _my_squads(snap)
	var raise := {"f": "foot", "v": "car", "k": "truck"}
	if raise.has(k):
		_cmd("recruit_squad", {"kind": raise[k]})
		return true
	if k == "tab":
		if mine.is_empty():
			return true
		var ids: Array = mine.map(func(d): return d.id)
		var i := ids.find(sel_squad)
		sel_squad = ids[(i + 1) % ids.size()]
		return true
	if sel_squad == null:
		return false
	var at = map.mouse_world()
	match k:
		"a":
			if at != null:
				_cmd("squad_order", {"id": sel_squad, "order": {"type": "checkpoint" if _own() == "police" else "ambush", "x": at.x, "y": at.y}})
		"m":
			_cmd("squad_order", {"id": sel_squad, "order": {"type": "melt"}})
		"h":
			_cmd("squad_order", {"id": sel_squad, "order": {"type": "hold"}})
		"d":
			_cmd("disband_squad", {"id": sel_squad})
			sel_squad = null
		_:
			return false
	return true


## Click: pick one of ours. Right-click: the order that fits the spot - a
## stash (guard it; for the police: stake it out, or raid it when it's known),
## an enemy squad (go after it), or anywhere else (patrol / hold the street).
func _squad_click(button: int, p: Vector2, snap: Dictionary) -> void:
	var near := func(items: Array):
		return Py.min_by(items, func(o): return PyMath.hypot(o.x - p.x, o.y - p.y))
	if button == MOUSE_BUTTON_LEFT:
		var d = near.call(_my_squads(snap))
		sel_squad = d.id if d != null and PyMath.hypot(d.x - p.x, d.y - p.y) < 1200 else null
		return
	if button != MOUSE_BUTTON_RIGHT or sel_squad == null:
		return
	var enemy = near.call(snap.get("ground", {}).get("squads", []).filter(func(d): return d.faction != _own()))
	var stash = near.call(snap.get("stashes", []))
	var o := {}
	if enemy != null and PyMath.hypot(enemy.x - p.x, enemy.y - p.y) < 500:
		o = {"type": "attack", "squad": enemy.id}
	elif stash != null and PyMath.hypot(stash.x - p.x, stash.y - p.y) < 700:
		if _own() == "police":
			o = {"type": "raid", "stash": stash.id}  # the desk only sees the houses it knows about
		else:
			o = {"type": "guard", "stash": stash.id}
	else:
		o = {"type": "patrol_zone", "x": p.x, "y": p.y, "market": GroundWar.market_at(p.x, p.y)}
	_cmd("squad_order", {"id": sel_squad, "order": o})


## The strip under a map click (within 1.5 km), or null.
func strip_at(p: Vector2):
	var af = Py.min_by(world.airfields, func(a): return PyMath.hypot(a.x - p.x, a.y - p.y))
	return af if af != null and PyMath.hypot(af.x - p.x, af.y - p.y) < 1500 else null


# ------------------------------------------------------------ drawing
func _process(delta: float) -> void:
	var dt := minf(delta, 0.1)
	link.tick(dt)
	var snap = link.snapshot()
	map.snap = snap
	map.sel_unit = sel_unit
	map.sel_squad = sel_squad
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
			Roles.LIEUTENANT, Roles.PATROL:
				_draw_squads(snap)
			_:
				_draw_runner(snap)
	if link is NetClient and not link.players.is_empty():
		subtitle.text = "  ".join(link.players.map(func(p): return "%s (%s)" % [p.name, p.role if p.role != "" else "lobby"]))
	status_lbl.text = status if status != "" else ("Link lost: %s" % link.error if link.error != null and not link.alive() else "")
	hints.set_hints(_hints())


## Refill the table only when its rows change, so selection and scroll survive.
## `cells` is one Array per row; `defs` the DataTable columns for this kind.
func _set_list(kind: String, keys: Array, cells: Array, colors := {}, defs := []) -> void:
	list.visible = kind != "none"
	if kind != _list_kind or keys != _list_keys:
		var keep := list.selected_row()
		if kind != _list_kind:
			list.configure(defs if not defs.is_empty() else [{"title": "", "expand": true}])
		else:
			list.clear_rows()
		for r in cells:
			list.add_row(r)
		_list_kind = kind
		_list_keys = keys
		if list.row_count() > 0:
			list.select(clampi(keep, 0, list.row_count() - 1))
	else:
		for i in cells.size():
			for c in cells[i].size():
				list.set_cell(i, c, str(cells[i][c]))
	for i in colors:
		list.set_row_color(i, colors[i])


func _runner_tiles(ac, snap: Dictionary) -> void:
	if tiles.is_empty():
		return
	if not (ac is Dictionary):
		for t in tiles.values():
			t.set_value("-", UIStyle.CAPTION)
		return
	tiles["ias"].set_value("%.0f" % ac.ias)
	tiles["alt"].set_value("%.0f" % (ac.alt / 0.3048))
	tiles["hdg"].set_value("%03.0f" % fposmod(ac.heading, 360))
	tiles["range"].set_value("%.0f km" % ac.range_km, UIStyle.WHITE, -1.0, "%.0f min" % (float(ac.get("endurance_h", 0)) * 60))
	var cap := float(snap.get("loadout", {}).get("fuel_cap", 1))
	tiles["fuel"].set_value("%.0f" % ac.fuel, UIStyle.RED if ac.fuel < 20 else UIStyle.GREEN, ac.fuel / maxf(1.0, cap))
	tiles["ferry"].set_value("%.0f lb" % ac.ferry_fuel, UIStyle.CYAN if ac.pumping else UIStyle.WHITE, -1.0,
		"PUMPING" if ac.pumping else ("pump off" if ac.ferry_fuel > 0 else "no tank fuel"))
	var bales: int = snap.get("loadout", {}).get("items", []).filter(func(it): return it.get("droppable", false)).size()
	tiles["kick"].set_value("%d aboard" % bales, UIStyle.AMBER if ac.kick_queue else UIStyle.WHITE, -1.0,
		("kicking %d" % int(ac.kick_queue)) if ac.kick_queue else ("auto-kick on" if ac.auto_kick else "auto-kick off"))
	var boats: Array = snap.get("boats", [])
	if boats.is_empty():
		tiles["boat"].set_value("-", UIStyle.CAPTION, -1.0, "no boat out")
	else:
		var b: Dictionary = boats[0]
		var d := PyMath.hypot(float(b.x) - float(ac.x), float(b.y) - float(ac.y)) / 1000
		tiles["boat"].set_value(str(b.state).replace("_", " "), UIStyle.CYAN, -1.0, "%.1f km, %d aboard" % [d, int(b.cargo)])
	chips["xpdr"].set_state(("XPDR %s %s" % [ac.squawk, ac.get("code", "")]) if ac.transponder else "XPDR OFF",
		UIStyle.GREEN if ac.transponder else UIStyle.AMBER, true)
	chips["ap"].set_state("AP", UIStyle.CYAN, ac.autopilot)
	var det = ac.get("detector")
	chips["radar"].visible = det != null
	var who: Array = ac.get("painters", []).map(func(p): return "%s %03d" % [p.code, int(p.bearing)])
	chips["radar"].set_state("RADAR %s%s" % [str(det), ("  " + ", ".join(who)) if not who.is_empty() else ""],
		UIStyle.RED if det == "LOCK" else UIStyle.AMBER, det in ["LOCK", "PAINT"])
	var w := int(ac.wanted)
	chips["wanted"].set_state(("WANTED " + "\u2605".repeat(w)) if w else "NOT WANTED", UIStyle.RED if w else UIStyle.GREEN, w > 0)
	chips["crew"].set_state("CO-PILOT ABOARD" if ac.get("copilot") else "SOLO", UIStyle.CYAN, Py.truthy(ac.get("copilot")))


func _draw_runner(snap: Dictionary) -> void:
	var ac = snap.get("aircraft")
	title.text = {"copilot": "CO-PILOT", "spotter": "SPOTTER", "boat": "GO-FAST BOAT"}.get(role, role.to_upper())
	subtitle.text = "%s   $%s" % [snap.mode, Py.money(int(snap.get("money", 0)))]
	_runner_tiles(ac, snap)
	var lines := []
	if ac is Dictionary:
		lines.append("%s  -  %s%s" % [ac.type, ac.phase, (" at " + ac.location) if ac.location else ""])
		if ac.outcome:
			lines.append(ac.outcome)
	if snap.has("campaign"):
		var c: Dictionary = snap.campaign
		lines += ["", "CHAPTER %d  -  %d  %s" % [int(c.chapter), int(c.year), c.title]] + c.objectives
	var tab: String = RUNNER_TABS[tabs.current_tab] if tabs != null else ("Spotter" if role == Roles.SPOTTER else "Flight")
	var lo: Dictionary = snap.get("loadout", {})
	if chart != null:
		chart.visible = tab == "Load"
	detail.text = ""
	if role == Roles.BOAT:
		var boats: Array = snap.get("boats", [])
		_set_list("boats", boats.map(func(b): return b.id), boats.map(func(b): return [b.id, str(b.state).replace("_", " "), "%d" % int(b.cargo)]),
			{}, [{"title": "Boat", "min": 110}, {"title": "State", "expand": true}, {"title": "Bales", "align": "right", "mono": true}])
	elif tab == "Load":
		var wb: Dictionary = lo.get("wb", {})
		detail.text = "%.0f / %.0f lb   CG %.1f in (%.1f-%.1f)   %s   crew %d   fuel %.0f / %.0f lb" % [wb.get("weight", 0), wb.get("mtow", 0),
			wb.get("cg", 0), wb.get("fwd", 0), wb.get("aft", 0), "OK" if wb.get("ok") else "OUT OF LIMITS", int(lo.get("crew", 0)),
			lo.get("fuel", 0), lo.get("fuel_cap", 0)]
		detail.add_theme_color_override("font_color", UIStyle.DIM if wb.get("ok") else UIStyle.RED)
		var items: Array = lo.get("items", [])
		var colors := {}
		for n in items.size():
			if items[n].get("hot"):
				colors[n] = Color(1, 0.62, 0.48)
		_set_list("load", items.map(func(it): return it.id), items.map(func(it): return [str(it.label), "%.0f lb" % it.weight,
			it.station if it.station else "RAMP", ("loading %.0fs" % it.pending) if it.pending else ""]), colors,
			[{"title": "Item", "expand": true, "min": 150}, {"title": "Weight", "align": "right", "mono": true, "min": 80},
			{"title": "Station", "min": 110}, {"title": "", "min": 90}])
		if chart != null and ac is Dictionary:
			chart.set_data(Aircraft.spec(ac.key), Vector2(wb.get("cg", 0), wb.get("weight", 0)), Vector2(wb.get("cg", 0), wb.get("weight", 0) - lo.get("fuel", 0)), wb.get("ok", false))
	elif tab == "Jobs":
		var keys := []
		var cells := []
		for j in snap.get("board", []):
			keys.append(["board", j.id])
			cells.append(["BOARD", str(j.title), "$" + Py.money(int(j.payout))])
		for j in snap.get("jobs", []):
			keys.append(["active", j.id])
			cells.append(["TAKEN", str(j.title), "$" + Py.money(int(j.payout))])
		if keys.is_empty():
			detail.text = "Park at a field to see its board."
		_set_list("jobs", keys, cells, {}, [{"title": "", "min": 70}, {"title": "Job", "expand": true},
			{"title": "Pay", "align": "right", "mono": true, "min": 90}])
	elif tab == "Spotter":
		var at: Array = snap.get("spotters", []).map(func(sp): return sp.code)
		_set_list("spotter", World.AIRFIELDS.map(func(a): return a.code), World.AIRFIELDS.map(func(a): return [a.code, a.name,
			"WATCHING" if at.has(a.code) else ""]), {}, [{"title": "Code", "min": 70}, {"title": "Strip", "expand": true}, {"title": "", "min": 100}])
		detail.text = "Or click a strip on the map."
	else:
		var st := _flight_states(ac, snap)
		_set_list("flight", FLIGHT_ACTIONS.map(func(f): return f[0]), FLIGHT_ACTIONS.map(func(f): return [f[1], f[2], st.get(f[0], "")]), {},
			[{"title": "Crew job", "expand": true}, {"title": "Key", "min": 100}, {"title": "Now", "expand": true}])
	# newest radio first: the column scrolls, and what just happened must be on top
	var top: Array = ["RADIO"] + snap.get("messages", []).slice(-5).map(func(m): return "  " + str(m))
	top.reverse()
	top.push_front(top.pop_back())
	var sc = snap.get("scanner")
	if sc != null and not sc.is_empty():
		top += ["", "SCANNER"] + sc.slice(-4).map(func(m): return "  " + str(m).substr(0, 70))
	info.text = "\n".join(top + [""] + lines)


## What each crew job is doing right now, for the Flight tab.
func _flight_states(ac, snap: Dictionary) -> Dictionary:
	if not (ac is Dictionary):
		return {}
	var bales: int = snap.get("loadout", {}).get("items", []).filter(func(it): return it.get("droppable", false)).size()
	var boats: Array = snap.get("boats", [])
	return {
		"kick": ("kicking, %d to go" % int(ac.kick_queue)) if ac.kick_queue else ("%d bales aboard" % bales if bales else "nothing to kick"),
		"auto_kick": "ON" if ac.auto_kick else "off",
		"pump": ("ON  -  %.0f lb left" % ac.ferry_fuel) if ac.pumping else ("off  -  %.0f lb in the tank" % ac.ferry_fuel if ac.ferry_fuel > 0 else "no ferry fuel"),
		# a call is a transmission: the task force's direction finders hear it (BALANCE.md)
		"call_boat": (str(boats[0].state).replace("_", " ") + "  -  a ~5 s call: DF gets a tight fix") if not boats.is_empty() else "no boat out",
		"codeword": "\"rain check\": the boat knows the mark; DF barely hears it" if not boats.is_empty() else "no boat out",
		"spotter": "watching: " + (", ".join(snap.get("spotters", []).map(func(sp): return sp.code)) if not snap.get("spotters", []).is_empty() else "none"),
	}


func _draw_hq(snap: Dictionary) -> void:
	var ss = snap.get("season")
	if not (ss is Dictionary):
		title.text = "NO HQ IN THIS GAME"
		subtitle.text = "needs layer 5 / --players 5+"
		board.visible = false
		return
	board.visible = true
	var head := "NIGHT %d/%d  -  %s" % [int(ss.night), int(ss.nights), str(ss.phase).to_upper()]
	if ss.winner:
		head += "  -  %s WINS (%s)" % ["ORGANISATION" if ss.winner == "runner" else "TASK FORCE", ss.reason]
	title.text = "THE ORGANISATION" if role == Roles.BOSS else "TASK FORCE HQ"
	subtitle.text = head
	board.update(ss)
	order_rows = board.rows


## The lieutenant's and the patrol commander's desk: our squads, their
## weapons and orders, the armoury, who holds the streets, the commander's log.
func _draw_squads(snap: Dictionary) -> void:
	var law := role == Roles.PATROL
	title.text = "PATROL COMMAND" if law else "LIEUTENANT"
	var g: Dictionary = snap.get("ground", {})
	if g.is_empty():
		info.text = "No ground war in this game."
		return
	var mine := _my_squads(snap)
	var cells := []
	var colors := {}
	for i in mine.size():
		var d: Dictionary = mine[i]
		cells.append([d.id, d.kind, "%d/%d" % [int(d.men), int(d.men0)], Arsenal.describe(d.loadout), d.tactic if d.tactic != "" else d.order, d.state])
		if d.state == "fighting":
			colors[i] = UIStyle.RED
		elif d.state == "routed":
			colors[i] = UIStyle.AMBER
	_set_list("squads", mine.map(func(d): return d.id), cells, colors, [{"title": "Squad", "min": 70}, {"title": "Unit", "min": 60},
		{"title": "Men", "align": "right", "mono": true, "min": 60}, {"title": "Weapons", "expand": true, "ratio": 2},
		{"title": "Orders", "min": 110}, {"title": "State", "min": 90}])
	var ars: Dictionary = snap.get("arsenal", {})
	var lines := ["%s: %s, %d rounds" % ["Police arsenal" if law else "Armoury", Arsenal.describe(ars.get("stock", {})), int(ars.get("ammo", 0))]]
	if law:
		lines.append("Funds $%s   arrests %d   officers down %d" % [Py.money(int(snap.get("law_funds", 0))), int(g.get("arrests", 0)), int(g.get("officers_down", 0))])
	else:
		lines.append("Cash $%s" % Py.money(int(snap.get("money", 0))))
	lines.append("")
	lines.append("STREETS (who's out there)")
	var ctl: Dictionary = g.get("control", {})
	for m in ctl:
		var c: Dictionary = ctl[m]
		var tot: float = c.org + c.rival + c.police
		if tot > 1.0:
			lines.append("  %-6s ours %2.0f%%   Los Cuervos %2.0f%%   police %2.0f%%" % [m,
				100.0 * (c.police if law else c.org) / tot, 100.0 * c.rival / tot, 100.0 * (c.org if law else c.police) / tot])
	var fights: Array = g.get("fights", [])
	if not fights.is_empty():
		lines += ["", "SHOTS FIRED"] + fights.map(func(f): return "  %s vs %s, %.0f s" % [f.a, f.b, float(f.age)])
	lines += ["", "COMMANDER (%s)" % ("AI" if g.get("commander", {}).get("ai", true) else "you")]
	lines += g.get("commander", {}).get("log", []).map(func(l): return "  " + str(l))
	var news: Array = snap.get("chronicle", {}).get("news", [])
	if not news.is_empty():
		lines += ["", "NEWS"] + news.slice(-4).map(func(n): return "  " + str(n.text))
	info.text = "\n".join(lines)
	detail.text = "Selected: %s" % (sel_squad if sel_squad != null else "- (click a squad, or UP/DOWN)")


func _draw_law(snap: Dictionary) -> void:
	title.text = "TASK FORCE DESK"
	subtitle.text = snap.mode
	var sc: Dictionary = snap.score
	var rs: Dictionary = snap.runner_score
	var cases: Array = Py.sorted_by(snap.get("cases", []), func(c): return -c.suspicion)
	var lines := [
		"Stock:  heli %d   interceptor %d   cutter %d" % [int(snap.stock.get("heli", 0)), int(snap.stock.get("interceptor", 0)), int(snap.stock.get("cutter", 0))],
		"Radio %s on %s   -   Aerostat %s" % ["ENCRYPTED" if snap.encrypted else "plain (scanners can hear you)",
			"TACTICAL" if snap.get("radio_channel") == "police_tac" else "dispatch", snap.aerostat],
		"Busts %d   boats %d   bales seized %d      Runners: bales in %d, escaped %d" % [int(sc.busts), int(sc.boats_seized), int(sc.bales_seized),
			int(rs.bales_delivered), int(rs.escapes)],
		"Selected unit: %s" % (sel_unit if sel_unit != null else "-  (click one on the map or pick it below)"), "", "CASES",
	]
	for c in cases.slice(0, 6):
		lines.append("  %-10s suspicion %3.0f%%   %s%s" % [c.id, c.suspicion, "\u2605".repeat(int(c.wanted)) if c.wanted else "", "   TIPPED" if c.tipped else ""])
	if cases.is_empty():
		lines.append("  (quiet)")
	lines += ["", "RADIO / ALERTS"] + snap.get("messages", []).slice(-8).map(func(m): return "  " + str(m))
	info.text = "\n".join(lines)
	subtitle.text = "%s  -  funds $%s" % [snap.mode, Py.money(int(snap.get("law_funds", 0)))]
	if upgrades.visible:
		list.visible = false
		var sig := "%s|%d" % [snap.get("upgrades", []), int(snap.get("law_funds", 0))]
		if sig != _upg_sig:
			_upg_sig = sig
			upgrades.update(snap.get("upgrades", []), int(snap.get("law_funds", 0)))
		return
	var units: Array = snap.get("units", [])
	var colors := {}
	for n in units.size():
		if units[n].id == sel_unit:
			colors[n] = UIStyle.AMBER
	_set_list("units", units.map(func(u): return u.id), units.map(func(u): return [u.id, u.kind, u.state, ("-> " + str(u.target)) if u.target else ""]),
		colors, [{"title": "Unit", "min": 110}, {"title": "Kind", "min": 100}, {"title": "State", "min": 90}, {"title": "Target", "expand": true}])
