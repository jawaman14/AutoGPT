class_name Hud
extends Control
## Pilot HUD, laid out by what the eye needs when:
##   top-left      status chips: transponder, autopilot, crew, radar, weather, pulse
##   top-centre    wanted stars with the suspicion / bust / rival bars under them
##   top-right     money and aircraft, then a card per active job (distance,
##                 bearing, time left), campaign objectives under those
##   left          radio and crew messages as fading toasts
##   bottom-left   the crew strip (what the co-pilot is doing) over the flight
##                 tiles: IAS, ALT, AGL, VS, HDG, GS, power, fuel, flaps, W&B
##   bottom-centre ground hints as key caps, the PAPI when on approach
##   bottom-right  the minimap
## Everything is anchored, so it holds together from 1024x768 to 4K.

var pulse := 0.0  ## the pilot's heart rate when it's up (Nerves), else 0
var s: Session
var cam_mode := "chase"
var mouse_yoke := false

var chips := {}
var tiles := {}
var zones := {}  ## name -> the anchored box of each HUD region (tests check they never overlap)
var wanted: Label
var susp_bar: ProgressBar
var bust_bar: ProgressBar
var rival_bar: ProgressBar
var status: Label
var jobs_box: VBoxContainer
var objectives: Label
var intel: Label
var toasts: ToastFeed
var crew: PanelContainer
var crew_lbl: Label
var warn: Label
var center: Label
var hints: KeyHints
var papi_label: Label
var papi_dots: Array = []
var minimap: Minimap


func setup(sess: Session) -> Hud:
	s = sess
	name = "Hud"
	theme = UIStyle.theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_chips()
	_build_wanted()
	_build_status()
	_build_flight()
	toasts = ToastFeed.new()
	_anchor(toasts, Vector4(0, 0.30, 0.42, 0.62), Vector4(14, 0, 0, -6))
	zones["toasts"] = toasts
	add_child(toasts)
	intel = UIStyle.label("", 14, Color(1, 0.8, 0.5), UIStyle.mono())
	intel.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_anchor(intel, Vector4(0.5, 0.5, 1, 0.62), Vector4(0, 0, -14, 0))
	add_child(intel)
	warn = _centered(UIStyle.label("", 30, UIStyle.RED), 0.22)
	center = _centered(UIStyle.label("", 24, UIStyle.AMBER), 0.42)
	papi_label = _centered(UIStyle.label("", 14), 0.84)
	var papi_row := HBoxContainer.new()
	papi_row.add_theme_constant_override("separation", 8)
	papi_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	papi_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_anchor(papi_row, Vector4(0.3, 0.87, 0.7, 0.87), Vector4(0, 0, 0, 18))
	for k in 4:
		var dot := ColorRect.new()
		dot.custom_minimum_size = Vector2(18, 18)
		dot.visible = false
		papi_row.add_child(dot)
		papi_dots.append(dot)
	add_child(papi_row)
	hints = KeyHints.new()
	hints.alignment = FlowContainer.ALIGNMENT_CENTER
	_anchor(hints, Vector4(0.38, 1, 0.8, 1), Vector4(0, -40, 0, -12))
	zones["hints"] = hints
	add_child(hints)
	minimap = Minimap.new()
	add_child(minimap)
	minimap.setup(sess)
	return self


## Anchor a control to a fraction box with pixel margins (left, top, right, bottom).
func _anchor(c: Control, a: Vector4, o := Vector4.ZERO) -> void:
	c.anchor_left = a.x
	c.anchor_top = a.y
	c.anchor_right = a.z
	c.anchor_bottom = a.w
	c.offset_left = o.x
	c.offset_top = o.y
	c.offset_right = o.z
	c.offset_bottom = o.w


func _centered(l: Label, y_frac: float) -> Label:
	add_child(l)
	_anchor(l, Vector4(0, y_frac, 1, y_frac))
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.grow_vertical = Control.GROW_DIRECTION_BOTH
	return l


func _panel(bg := Color(0.02, 0.03, 0.05, 0.62)) -> PanelContainer:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", UIStyle.box(bg, 8, Color(1, 1, 1, 0.07), 1, Vector4(10, 8, 10, 8)))
	return p


func _build_chips() -> void:
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 6)
	row.add_theme_constant_override("v_separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_anchor(row, Vector4(0, 0, 0.36, 0), Vector4(14, 12, 0, 70))
	zones["chips"] = row
	for n in ["xpdr", "ap", "crew", "kick", "pump", "radar", "wx", "pulse", "cam"]:
		chips[n] = Chip.new().setup(n.to_upper())
		row.add_child(chips[n])
	add_child(row)


func _build_wanted() -> void:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_anchor(v, Vector4(0.36, 0, 0.64, 0), Vector4(0, 8, 0, 110))
	zones["wanted"] = v
	wanted = UIStyle.label("", 26, UIStyle.RED)
	wanted.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(wanted)
	susp_bar = _bar(UIStyle.AMBER)
	bust_bar = _bar(UIStyle.RED)
	rival_bar = _bar(Color(0.8, 0.3, 1))
	for b in [susp_bar, bust_bar, rival_bar]:
		v.add_child(b)
	add_child(v)


func _bar(col: Color) -> ProgressBar:
	var b := ProgressBar.new()
	b.custom_minimum_size = Vector2(0, 8)
	b.max_value = 1.0
	b.show_percentage = false
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_theme_stylebox_override("background", UIStyle.box(Color(0, 0, 0, 0.5), 4, Color(0, 0, 0, 0), 0, Vector4(0, 0, 0, 0)))
	b.add_theme_stylebox_override("fill", UIStyle.box(col, 4, Color(0, 0, 0, 0), 0, Vector4(0, 0, 0, 0)))
	b.visible = false
	return b


func _build_status() -> void:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_anchor(v, Vector4(0.66, 0, 1, 0.55), Vector4(0, 10, -14, 0))
	zones["status"] = v
	status = UIStyle.label("", 17)
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.add_child(status)
	jobs_box = VBoxContainer.new()
	jobs_box.add_theme_constant_override("separation", 4)
	jobs_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(jobs_box)
	objectives = UIStyle.label("", 15, UIStyle.AMBER)
	objectives.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	objectives.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(objectives)
	add_child(v)


func _build_flight() -> void:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.alignment = BoxContainer.ALIGNMENT_END
	_anchor(v, Vector4(0, 0.62, 0.36, 1), Vector4(14, 0, 0, -12))
	zones["flight"] = v
	crew = _panel(Color(0.02, 0.1, 0.12, 0.7))
	crew_lbl = UIStyle.label("", 14, UIStyle.CYAN)
	crew_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	crew.add_child(crew_lbl)
	crew.visible = false
	v.add_child(crew)
	var p := _panel()
	v.add_child(p)
	var pv := VBoxContainer.new()
	pv.add_theme_constant_override("separation", 4)
	pv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(pv)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	pv.add_child(h)
	var g := GridContainer.new()
	g.columns = 4
	g.add_theme_constant_override("h_separation", 6)
	g.add_theme_constant_override("v_separation", 6)
	g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(g)
	for n in [["ias", "IAS kt"], ["alt", "ALT ft"], ["agl", "AGL ft"], ["vs", "VS fpm"],
			["hdg", "HDG"], ["gs", "GS kt"], ["pwr", "Power"], ["fuel", "Fuel lb"]]:
		tiles[n[0]] = StatTile.new().setup(n[1], n[0] == "fuel", 18)
		g.add_child(tiles[n[0]])
	var foot := UIStyle.label("", 13, UIStyle.CAPTION, UIStyle.mono())
	pv.add_child(foot)
	tiles["wb"] = foot
	add_child(v)


func refresh() -> void:
	var st: FlightModel.FlightState = s.state
	if st == null:
		return
	var c: FlightModel.Controls = s.fm.controls
	var lo: Loadout = s.loadout
	_flight(st, c, lo)
	_chip_row(st, c)
	_wanted()
	_status(st, lo)
	_crew(lo)
	var il := []
	for m in s.scanner_log.slice(-3):
		if s.time - m[0] < 40:
			il.append("SCAN " + str(m[1]).substr(0, 52))
	intel.text = "\n".join(il)
	var camp = s.campaign
	objectives.text = ("%d - %s\n" % [camp.chapter.year, camp.chapter.title] + "\n".join(camp.objective_lines())) if camp != null else ""
	toasts.sync(s.messages, s.time)
	_warnings(st, c)
	if s.phase in ["crashed", "busted"]:
		center.text = s.last_outcome + "\n\nPress ENTER to continue"
		hints.set_hints([["ENTER", "continue"]])
	elif s.parked:
		center.text = ""
		var h := [["J", "jobs"], ["L", "load & fuel"], ["H", "hangar & gear"], ["TAB", "get out"], ["F1", "help"]]
		if not lo.compute().ok():
			h.append(["L", "LOAD OUT OF LIMITS"])
		if not lo.pending.is_empty():
			h.append(["...", "loading %.0f crew-s" % Py.sum_by(lo.pending.values(), func(v): return v)])
		hints.set_hints(h)
	else:
		center.text = ""
		hints.set_hints([])
	_papi(st)


func _flight(st: FlightModel.FlightState, c: FlightModel.Controls, lo: Loadout) -> void:
	var stall: bool = st.stall_warning
	tiles["ias"].set_value("%.0f" % st.ias_kts, UIStyle.RED if stall else UIStyle.WHITE)
	tiles["alt"].set_value("%.0f" % (st.alt / 0.3048))
	var agl := maxf(0.0, st.agl / 0.3048 - s.fm.mass.gear_height_ft)
	tiles["agl"].set_value("%.0f" % agl, UIStyle.AMBER if agl < 150 and not st.on_ground else UIStyle.WHITE)
	tiles["vs"].set_value("%+.0f" % st.vs_fpm, UIStyle.RED if st.vs_fpm < -1000 else UIStyle.WHITE)
	tiles["hdg"].set_value("%03.0f" % fposmod(st.heading, 360))
	tiles["gs"].set_value("%.0f" % st.gs_kts)
	tiles["pwr"].set_value("%.0f%%" % (c.throttle * 100), UIStyle.WHITE, -1.0, "%.0f rpm" % st.rpm)
	var cap := lo.mass.fuel_capacity_lb()
	var he: Array = s.range_estimate()
	var sub := ("%.0f km / %.0f min" % [he[1], he[0] * 60]) if not st.on_ground else "range: airborne only"
	var ferry := lo.ferry_fuel_lb()
	if ferry > 0 or not lo.ferry_tanks().is_empty():
		sub += "  +%.0f ferry" % ferry
	var low: bool = st.fuel_lb < 20 and not st.on_ground
	tiles["fuel"].set_value("%.0f" % st.fuel_lb, UIStyle.RED if low else (UIStyle.AMBER if st.fuel_lb < 0.2 * cap else UIStyle.GREEN),
		st.fuel_lb / maxf(1.0, cap), sub)
	tiles["wb"].text = "FLAP %d/3  TRIM %+.2f  WT %.0f lb  CG %.1f in%s" % [int(round(c.flaps * 3)), -c.pitch_trim, st.weight_lb,
		st.cg_in, "  BRAKE" if c.brake > 0.5 else ""]


func _chip_row(st: FlightModel.FlightState, c: FlightModel.Controls) -> void:
	var emerg: bool = s.squawk_code in ["7500", "7600", "7700"]
	chips["xpdr"].set_state(("XPDR %s %s" % [s.squawk, s.squawk_code]) if s.transponder else "XPDR OFF",
		UIStyle.RED if emerg and s.transponder else (UIStyle.GREEN if s.transponder else UIStyle.AMBER), true)
	chips["ap"].set_state("AP", UIStyle.CYAN, s.autopilot.engaged)
	var who: String = {"human": "CREW: CO-PILOT", "ai": "CREW: ROSA"}.get(s.copilot, "SOLO")
	chips["crew"].set_state(who, UIStyle.CYAN, Py.truthy(s.copilot))
	chips["kick"].visible = s.kick_queue > 0 or s.auto_kick
	chips["kick"].set_state("KICK %d" % s.kick_queue if s.kick_queue else "AUTO-KICK", UIStyle.AMBER, true)
	chips["pump"].visible = s.pumping
	chips["pump"].set_state("PUMP", UIStyle.CYAN, true)
	chips["radar"].visible = s.gear.has("detector")
	var det: String = s.police.detector() if s.gear.has("detector") else ""
	chips["radar"].set_state({"LOCK": "RADAR LOCK", "PAINT": "RADAR PAINT"}.get(det, "RADAR CLEAR") + _painter_text(st),
		UIStyle.RED if det == "LOCK" else (UIStyle.AMBER if det == "PAINT" else UIStyle.GREEN), det != "")
	chips["wx"].visible = not s.weather.is_empty()
	if not s.weather.is_empty():
		var w := s.weather
		chips["wx"].set_state("%s %03d/%d moon %d%%" % [str(w.sky).to_upper(), int(w.wind_dir), int(w.wind_kt), int(float(w.moon) * 100)],
			UIStyle.RED if w.sky == "storm" else UIStyle.WHITE, w.sky != "clear")
	chips["pulse"].visible = pulse > 0.0
	chips["pulse"].set_state("PULSE %.0f%s" % [pulse, " SHAKING" if pulse > 131 else ""], UIStyle.RED, true)
	chips["cam"].set_state("%s%s" % ["YOKE:MOUSE  " if mouse_yoke else "", cam_mode.to_upper()], UIStyle.CAPTION, false)


## The strongest painter as "HAR ↗": which site, and which way it is from the nose.
func _painter_text(st: FlightModel.FlightState) -> String:
	var ps: Array = s.police.painters() if s.gear.has("detector") and s.has_upgrade("bearing_detector") else []
	if ps.is_empty():
		return ""
	var p: Dictionary = ps[0]
	for q in ps:
		if q.locked and not p.locked:
			p = q
	var arrows := ["\u2191", "\u2197", "\u2192", "\u2198", "\u2193", "\u2199", "\u2190", "\u2196"]
	var rel := fposmod(float(p.bearing) - st.heading + 22.5, 360.0)
	return "  %s %s%s" % [p.code, arrows[int(rel / 45.0) % 8], " +%d" % (ps.size() - 1) if ps.size() > 1 else ""]


func _wanted() -> void:
	var w: int = s.police.wanted
	wanted.text = ("★".repeat(w) + "☆".repeat(3 - w)) if w else ""
	var sp: float = s.police.suspicion
	susp_bar.visible = sp > 1 and not w
	susp_bar.value = sp / 100
	bust_bar.visible = s.police.bust_meter > 1
	bust_bar.value = s.police.bust_meter / 100
	rival_bar.visible = s.police.rival_meter > 1
	rival_bar.value = s.police.rival_meter / 100


func _status(st: FlightModel.FlightState, lo: Loadout) -> void:
	status.text = "$%s   %s%s" % [Py.money(s.money), s.spec.name, ("\nat " + World.airfield(s.location).name) if s.location else ""]
	var jobs := s.active_jobs.slice(0, 5)
	while jobs_box.get_child_count() > jobs.size():
		var c := jobs_box.get_child(jobs_box.get_child_count() - 1)
		jobs_box.remove_child(c)
		c.queue_free()
	while jobs_box.get_child_count() < jobs.size():
		var p := _panel()
		var l := UIStyle.label("", 14, UIStyle.CYAN, UIStyle.mono())
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		p.add_child(l)
		jobs_box.add_child(p)
	for n in jobs.size():
		var j: Jobs.Job = jobs[n]
		var xy: Array = s.job_xy(j)
		var d := PyMath.hypot(xy[0] - st.x, xy[1] - st.y) / 1000
		var brg := UIStyle.bearing_to(st.x, st.y, xy[0], xy[1])
		var tl = j.time_left(s.time)
		var tls := "  %d:%02d left" % [int(tl / 60), int(fposmod(tl, 60))] if tl != null else ""
		var extra := ""
		if j.is_airdrop():
			var boat = s.maritime.boat(j.boat_id) if j.boat_id != null else null
			var left := Py.count(lo.items.values(), func(i): return i.job_id == j.id)
			extra = "\n%d bales aboard  -  boat %s" % [left, str(boat.state).replace("_", " ") if boat != null else "?"]
		var l: Label = jobs_box.get_child(n).get_child(0)
		l.text = "%s%s  $%s\n%.1f km  brg %03.0f%s%s" % ["HOT " if j.hot() else "", j.dest_label(), Py.money(j.payout), d, brg, tls, extra]
		l.add_theme_color_override("font_color", Color(1, 0.62, 0.48) if j.hot() else UIStyle.CYAN)


## What the co-pilot is doing, in words: the pilot shouldn't have to look back.
func _crew(lo: Loadout) -> void:
	var parts := []
	if s.copilot:
		parts.append({"human": "Co-pilot", "ai": "Rosa"}[s.copilot])
	if s.kick_queue > 0:
		parts.append("kicking: %d to go" % s.kick_queue)
	elif not s._droppables().is_empty() and s.auto_kick:
		parts.append("ready to kick %d over the mark" % s._droppables().size())
	if s.pumping:
		parts.append("pumping ferry fuel (%.0f lb left)" % lo.ferry_fuel_lb())
	for m in s.messages.slice(-3):
		if str(m[1]).begins_with("[copilot]") and s.time - m[0] < 15:
			parts.append("\"%s\"" % str(m[1]).substr(10))
	crew.visible = parts.size() > (1 if s.copilot else 0)
	crew_lbl.text = "  -  ".join(parts)


func _warnings(st: FlightModel.FlightState, c: FlightModel.Controls) -> void:
	var warns := []
	if st.stall_warning:
		warns.append("STALL")
	if s.police.bust_meter > 1:
		warns.append("POLICE ON YOUR TAIL")
	if s.police.rival_meter > 1:
		warns.append("RIVALS CLOSING")
	if st.fuel_lb < 20 and not st.on_ground:
		warns.append("LOW FUEL")
	if c.flaps > 0 and st.ias_kts > s.spec.max_flap_kts + 5:
		warns.append("FLAP OVERSPEED")
	warn.text = "   ".join(warns)


func _papi(st: FlightModel.FlightState) -> void:
	var dests := []
	for j in s.active_jobs:
		if not j.is_airdrop():
			dests.append(World.airfield(j.dest))
	var best = null
	var dist := 1e9
	var aim := [0.0, 0.0]
	for a in (dests if dests else s.world.airfields):
		for end in [0, 1]:
			var t: Array = a.threshold(end)
			var d := PyMath.hypot(t[0] - st.x, t[1] - st.y)
			var sgn := 1 if end == 0 else -1
			if (a.x - t[0]) * (st.x - t[0]) + (a.y - t[1]) * (st.y - t[1]) > 0:
				continue  # only the end you'd be approaching
			if d < dist:
				best = a
				dist = d
				aim = [t[0] + sgn * a.ux * 60, t[1] + sgn * a.uy * 60]
	if best == null or dist > 6000 or st.on_ground:
		for dot in papi_dots:
			dot.visible = false
		papi_label.text = ""
		return
	var lights := UIStyle.papi(st.alt - s.fm.mass.gear_height_ft * 0.3048, PyMath.hypot(aim[0] - st.x, aim[1] - st.y),
		s.world.airfield_elev(best))
	for k in 4:
		papi_dots[k].visible = true
		papi_dots[k].color = Color(1, 1, 0.95) if lights[k] == "W" else Color(1, 0.15, 0.1)
	papi_label.text = "%s %.0fx%.0fm  %.1fkm" % [best.code, best.length, best.width, dist / 1000]
