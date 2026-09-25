class_name LoadMenu
extends GameMenu
## Load planner: choose where every item rides, how much fuel to take, and see
## what that does to weight, balance, endurance and range before you commit.
##
## - Each item has a station picker (only stations that will take it), or back
##   to the ramp. The ground crew moves it (loading time depends on crew).
## - Fuel slider with presets: 25/50/75%, full, and "route + 30 min" for the
##   first active job, priced at this field's fuel source.
## - Live CG envelope (take-off dot, zero-fuel ring) and a verdict with reasons.
## Keyboard: UP/DOWN item, LEFT/RIGHT station, +/- fuel 10%, F ferry tank,
## A loadmaster, ESC close.

var stations: DataTable
var verdict: Chip
var tiles := {}
var items_box: GridContainer
var fuel_lbl: Label
var fuel_slider: HSlider
var fuel_dragging := false
var chart: CGChart
var readout: Label
var ferry_btn: Button
var sel := 0
var item_ids: Array = []
var _building := false


func _build() -> void:
	var h := HBoxContainer.new()
	h.size_flags_vertical = Control.SIZE_EXPAND_FILL
	h.add_theme_constant_override("separation", 18)
	content.add_child(h)
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(left)
	left.add_theme_constant_override("separation", 8)
	left.add_child(UIStyle.caption("Stations"))
	stations = GameMenu.make_table([{"title": "Station", "min": 120}, {"title": "Arm", "align": "right", "mono": true, "min": 64},
		{"title": "Load", "align": "right", "mono": true, "min": 110}, {"title": "Aboard", "expand": true, "min": 160}])
	stations.focus_mode = Control.FOCUS_NONE
	stations.size_flags_vertical = Control.SIZE_FILL
	stations.custom_minimum_size = Vector2(0, 250)
	left.add_child(stations)
	left.add_child(UIStyle.caption("Cargo  -  pick a station for each item"))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(scroll)
	items_box = GridContainer.new()
	items_box.columns = 3
	items_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	items_box.add_theme_constant_override("h_separation", 12)
	scroll.add_child(items_box)

	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(400, 0)
	right.add_theme_constant_override("separation", 6)
	h.add_child(right)
	var vrow := HBoxContainer.new()
	vrow.add_theme_constant_override("separation", 8)
	vrow.add_child(UIStyle.caption("Weight & balance"))
	verdict = Chip.new().setup("OK")
	vrow.add_child(verdict)
	right.add_child(vrow)
	var tg := GridContainer.new()
	tg.columns = 2
	tg.add_theme_constant_override("h_separation", 8)
	tg.add_theme_constant_override("v_separation", 8)
	for n in [["tow", "Take-off weight", true], ["cg", "CG (in)", false], ["endurance", "Endurance", false], ["route", "Route reserve", false]]:
		tiles[n[0]] = StatTile.new().setup(n[1], n[2], 18)
		tg.add_child(tiles[n[0]])
	right.add_child(tg)
	right.add_child(UIStyle.caption("Fuel"))
	fuel_lbl = UIStyle.label("", 14, UIStyle.WHITE, UIStyle.mono())
	fuel_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(fuel_lbl)
	fuel_slider = HSlider.new()
	fuel_slider.min_value = 0
	fuel_slider.step = 1
	fuel_slider.drag_started.connect(func(): fuel_dragging = true)
	fuel_slider.drag_ended.connect(func(_changed):
		fuel_dragging = false
		_set_fuel(fuel_slider.value))
	fuel_slider.value_changed.connect(func(v):
		if fuel_dragging:
			_preview_fuel(v))
	right.add_child(fuel_slider)
	var presets := HBoxContainer.new()
	for p in [["25%", 0.25], ["50%", 0.5], ["75%", 0.75], ["Full", 1.0]]:
		var b := Button.new()
		b.text = p[0]
		b.focus_mode = Control.FOCUS_NONE
		var frac: float = p[1]
		b.pressed.connect(func(): _set_fuel(s.loadout.mass.fuel_capacity_lb() * frac))
		presets.add_child(b)
	var rb := Button.new()
	rb.text = "Route +30 min"
	rb.tooltip_text = "Enough for the first job's route plus a 30-minute reserve"
	rb.focus_mode = Control.FOCUS_NONE
	rb.pressed.connect(_route_fuel)
	presets.add_child(rb)
	right.add_child(presets)
	var crew := HBoxContainer.new()
	ferry_btn = Button.new()
	ferry_btn.text = "Fill ferry tank [F]"
	ferry_btn.focus_mode = Control.FOCUS_NONE
	ferry_btn.pressed.connect(func(): key("f"))
	crew.add_child(ferry_btn)
	var lm := Button.new()
	lm.text = "Loadmaster $%d [A]" % Session.LOADMASTER_FEE
	lm.tooltip_text = "Balances the load for you, heaviest first"
	lm.focus_mode = Control.FOCUS_NONE
	lm.pressed.connect(func(): key("a"))
	crew.add_child(lm)
	right.add_child(crew)
	chart = CGChart.new()
	chart.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(chart)
	readout = UIStyle.label("", 14, UIStyle.RED)
	readout.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(readout)
	hints.set_hints([["UP/DOWN", "item", "down"], ["LEFT/RIGHT", "station", "right"], ["+/-", "fuel 10%", "+"],
		["F", "fill ferry", "f"], ["A", "loadmaster", "a"], ["ESC", "close", "esc"]])


func _items() -> Array:
	return Py.sorted_by(s.loadout.items.values(), func(i): return float(i.job_id) * 1e7 + i.id)


func refresh() -> void:
	var lo: Loadout = s.loadout
	if not fuel_dragging:
		lo.fuel_lb = s.fm.fuel_lb()
	title.text = "LOAD PLANNER"
	subtitle.text = "%s  -  crew loading: %d" % [s.spec.name, s.crew_count()]
	_refresh_stations()
	_refresh_items()
	_refresh_fuel_and_wb()


func _refresh_stations() -> void:
	var lo: Loadout = s.loadout
	var weights: Array = lo.station_weights(true)
	stations.clear_rows()
	for i in lo.spec.stations.size():
		var st: Aircraft.Station = lo.spec.stations[i]
		var who := []
		for it in lo.items.values():
			if lo.assignment.get(it.id) == i:
				who.append(it.label)
		if st.kind == "pilot":
			who = ["You (%.0f lb)" % Loadout.PILOT_LB]
		elif lo.copilot_aboard and i == lo.copilot_station():
			who = ["Co-pilot (%.0f lb)" % Loadout.PILOT_LB] + who
		var over: bool = weights[i] > st.max_lb
		var frac: float = weights[i] / maxf(1.0, st.max_lb)
		var col := UIStyle.RED if over else (UIStyle.AMBER if frac > 0.85 else (UIStyle.WHITE if weights[i] > 0 else UIStyle.CAPTION))
		stations.add_row([st.name, "%.1f" % st.x_in, "%.0f/%.0f" % [weights[i], st.max_lb], ", ".join(who) + ("  OVER!" if over else "")],
			{"cell_colors": {2: col, 3: UIStyle.RED if over else Color(0.9, 0.92, 0.95)}, "selectable": false})


func _refresh_items() -> void:
	var lo: Loadout = s.loadout
	var items := _items()
	var ids := items.map(func(i): return i.id)
	sel = clampi(sel, 0, maxi(0, items.size() - 1))
	if ids != item_ids:  # rebuild the pickers only when the item set changes
		item_ids = ids
		for c in items_box.get_children():
			c.queue_free()
		for it in items:
			items_box.add_child(UIStyle.label("", 14, UIStyle.WHITE, UIStyle.mono()))
			var ob := OptionButton.new()
			ob.focus_mode = Control.FOCUS_NONE
			ob.fit_to_longest_item = true
			var iid: int = it.id
			ob.item_selected.connect(func(idx): _picked(iid, ob.get_item_id(idx)))
			items_box.add_child(ob)
			items_box.add_child(UIStyle.label("", 13, UIStyle.AMBER))
	_building = true
	for n in items.size():
		var it: Loadout.Item = items[n]
		var lbl: Label = items_box.get_child(n * 3)
		var ob: OptionButton = items_box.get_child(n * 3 + 1)
		var st_lbl: Label = items_box.get_child(n * 3 + 2)
		var flags := ("HOT " if it.hot else "") + ("FRAGILE " if it.fragile else "") + ("DROP " if it.droppable else "")
		if it.kind == "tank":
			flags += "%.0f/%.0f lb fuel " % [it.fuel_lb, it.fuel_cap_lb]
		lbl.text = "%s %-16s %5.0f lb %s" % [">" if n == sel else " ", it.label, it.weight_lb, flags]
		lbl.add_theme_color_override("font_color", Color(1, 0.6, 0.45) if it.hot else UIStyle.WHITE)
		ob.clear()
		ob.add_item("** ramp **", -1)
		for si in lo.valid_stations(it):
			var ok := lo.can_place(it, si)
			ob.add_item(lo.spec.stations[si].name + ("" if ok else " (full)"), si)
			ob.set_item_disabled(ob.item_count - 1, not ok and lo.assignment.get(it.id) != si)
		var cur = lo.assignment.get(it.id)
		ob.select(ob.get_item_index(cur if cur != null else -1))
		st_lbl.text = ("loading %.0fs" % lo.pending[it.id]) if lo.pending.has(it.id) else ("ON THE RAMP" if cur == null else "")
	_building = false


func _picked(iid: int, station: int) -> void:
	if _building:
		return
	var err = s.place_item(iid, station)
	if err:
		s.say(err)
	refresh()


func _cruise() -> Array:
	return [float(PilotBot.CRUISE_FUEL_PPH.get(s.aircraft_key, 60)), float(PilotBot.CRUISE_KTS.get(s.aircraft_key, 110))]


func _refresh_fuel_and_wb() -> void:
	var lo: Loadout = s.loadout
	var cap := lo.mass.fuel_capacity_lb()
	fuel_slider.max_value = cap
	if not fuel_dragging:
		fuel_slider.set_value_no_signal(lo.fuel_lb)
	var src: Array = s.fuel_source()
	var supply := "unlimited" if src[1] >= 1e8 else "%.0f lb in the cache" % src[1]
	var price := "free (your cache)" if src[0] == 0 else "$%.2f/lb" % src[0]
	fuel_lbl.text = "%.0f / %.0f lb in the wings   %s, %s" % [lo.fuel_lb, cap, price, supply]
	var ferry := lo.ferry_fuel_lb()
	if not lo.ferry_tanks().is_empty():
		fuel_lbl.text += "\nferry tank %.0f lb (pump it forward in flight)" % ferry
	ferry_btn.disabled = lo.ferry_tanks().is_empty()
	var wb = lo.compute()
	var zfw = lo.compute(0.0)
	chart.set_data(s.spec, Vector2(wb.cg_in, wb.weight_lb), Vector2(zfw.cg_in, zfw.weight_lb), wb.ok())
	var details := []
	if wb.overweight_lb > 0:
		details.append("%.0f lb over MTOW" % wb.overweight_lb)
	if not wb.in_envelope:
		details.append("CG outside envelope")
	if not wb.station_overloads.is_empty():
		details.append("station overload")
	if not lo.unassigned().is_empty():
		details.append("%d item(s) left on the ramp" % lo.unassigned().size())
	var cr := _cruise()
	var hours: float = (lo.fuel_lb + ferry) / cr[0]
	verdict.set_state("OK" if wb.ok() else "OUT OF LIMITS", UIStyle.GREEN if wb.ok() else UIStyle.RED, true)
	var heavy: bool = wb.weight_lb > s.spec.mtow_lb
	tiles["tow"].set_value("%.0f lb" % wb.weight_lb, UIStyle.RED if heavy else UIStyle.WHITE, wb.weight_lb / s.spec.mtow_lb,
		"MTOW %.0f lb" % s.spec.mtow_lb)
	tiles["cg"].set_value("%.1f" % wb.cg_in, UIStyle.WHITE if wb.in_envelope else UIStyle.RED, -1.0,
		"limits %.1f - %.1f" % [wb.fwd_limit_in, wb.aft_limit_in])
	tiles["endurance"].set_value("%d:%02d" % [int(hours), int(fposmod(hours * 60, 60))], UIStyle.WHITE, -1.0,
		"range ~%.0f km at cruise" % (hours * cr[1] * 1.852))
	var need = _route_need()
	if need != null:
		var margin: float = (lo.fuel_lb + ferry - need[1]) / cr[0] * 60
		tiles["route"].set_value("%s%.0f min" % ["SHORT " if margin < 0 else "", absf(margin)],
			UIStyle.RED if margin < 0 else (UIStyle.AMBER if margin < 30 else UIStyle.GREEN), -1.0,
			"%.1f km needs ~%.0f lb" % [need[0] / 1000, need[1]])
	else:
		tiles["route"].set_value("-", UIStyle.CAPTION, -1.0, "take a job to plan fuel")
	readout.text = "; ".join(details)


## [route metres, fuel lb without reserve] for the first active job, or null.
func _route_need():
	if s.active_jobs.is_empty() or s.state == null:
		return null
	var legs := PilotBot.mission_for(s, s.active_jobs[0], s.location)
	var x := s.state.x
	var y := s.state.y
	var dist := 0.0
	for lg in legs:
		dist += PyMath.hypot(lg.x - x, lg.y - y)
		x = lg.x
		y = lg.y
	var cr := _cruise()
	return [dist, dist / 1852.0 / cr[1] * 1.3 * cr[0]]


func _preview_fuel(v: float) -> void:
	s.loadout.fuel_lb = v  # what-if while dragging; applied (and paid for) on release
	_refresh_fuel_and_wb()


func _set_fuel(v: float) -> void:
	s.set_fuel(v)
	refresh()


func _route_fuel() -> void:
	if s.active_jobs.is_empty():
		s.say("Take a job first: the route decides the fuel.")
		return
	var legs := PilotBot.mission_for(s, s.active_jobs[0], s.location)
	_set_fuel(PilotBot.plan_fuel_lb(s, legs, 0.5))


func key(k: String) -> void:
	var items := _items()
	match k:
		"up":
			sel = posmod(sel - 1, maxi(1, items.size()))
		"down":
			sel = posmod(sel + 1, maxi(1, items.size()))
		"left", "right":
			if not items.is_empty():
				s.cycle_item(items[mini(sel, items.size() - 1)].id, 1 if k == "right" else -1)
		"a":
			if not s.hire_loadmaster():
				s.say("Loadmaster couldn't fit everything.")
		"+", "-":
			_set_fuel(s.fm.fuel_lb() + (0.1 if k == "+" else -0.1) * s.loadout.mass.fuel_capacity_lb())
			return
		"f":
			var err = s.fill_ferry(10000)
			if err:
				s.say(err)
	refresh()
