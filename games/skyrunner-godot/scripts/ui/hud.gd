class_name Hud
extends Control
## Pilot HUD: flight data, money/wanted status, active jobs, messages, warnings,
## PAPI, scanner intel, campaign objectives, throttle and bust/rival bars, and
## the minimap (port of render/hud.py Hud).

var s: Session
var flight: Label
var status: Label
var jobs: Label
var msgs: Label
var warn: Label
var center: Label
var hint: Label
var intel: Label
var objectives: Label
var papi_label: Label
var papi_dots: Array = []
var minimap: Minimap
var throttle_bar: ProgressBar
var bust_bar: ProgressBar
var rival_bar: ProgressBar
var cam_mode := "chase"
var mouse_yoke := false


func setup(sess: Session) -> Hud:
	s = sess
	name = "Hud"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mono := UIStyle.mono()
	flight = _place(UIStyle.label("", 17, UIStyle.GREEN, mono), Control.PRESET_TOP_LEFT, Vector2(14, 10))
	status = _place(UIStyle.label("", 18), Control.PRESET_TOP_RIGHT, Vector2(-14, 10), true)
	jobs = _place(UIStyle.label("", 15, UIStyle.CYAN, mono), Control.PRESET_TOP_RIGHT, Vector2(-14, 120), true)
	objectives = _place(UIStyle.label("", 15, UIStyle.AMBER), Control.PRESET_TOP_RIGHT, Vector2(-14, 260), true)
	msgs = UIStyle.label("", 16)
	msgs.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	msgs.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	msgs.anchor_left = 0.0
	msgs.anchor_right = 0.62
	msgs.anchor_top = 0.45
	msgs.anchor_bottom = 0.78
	msgs.offset_left = 14
	add_child(msgs)
	intel = _place(UIStyle.label("", 14, Color(1, 0.8, 0.5), mono), Control.PRESET_BOTTOM_RIGHT, Vector2(-250, -300), true)
	warn = _centered(UIStyle.label("", 30, UIStyle.RED), 0.2)
	center = _centered(UIStyle.label("", 24, UIStyle.AMBER), 0.42)
	hint = _centered(UIStyle.label("", 16, UIStyle.DIM), 0.95)
	papi_label = _centered(UIStyle.label("", 14), 0.84)
	var papi_row := HBoxContainer.new()
	papi_row.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	papi_row.position = Vector2(-52, -90)
	papi_row.add_theme_constant_override("separation", 8)
	papi_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for k in 4:
		var dot := ColorRect.new()
		dot.custom_minimum_size = Vector2(18, 18)
		dot.visible = false
		papi_row.add_child(dot)
		papi_dots.append(dot)
	add_child(papi_row)
	throttle_bar = _bar(Color(0.4, 1, 0.45), Vector2(16, 120), true)
	throttle_bar.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	throttle_bar.position = Vector2(14, -134)
	bust_bar = _bar(UIStyle.RED, Vector2(360, 12), false)
	bust_bar.set_anchors_preset(Control.PRESET_CENTER_TOP)
	bust_bar.position = Vector2(-180, 190)
	rival_bar = _bar(Color(0.8, 0.3, 1), Vector2(360, 12), false)
	rival_bar.set_anchors_preset(Control.PRESET_CENTER_TOP)
	rival_bar.position = Vector2(-180, 208)
	minimap = Minimap.new()
	add_child(minimap)
	minimap.setup(sess)
	return self


func _place(l: Label, preset: int, offset: Vector2, right := false) -> Label:
	add_child(l)
	l.set_anchors_preset(preset)
	if right:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		l.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	if preset in [Control.PRESET_BOTTOM_LEFT, Control.PRESET_BOTTOM_RIGHT]:
		l.grow_vertical = Control.GROW_DIRECTION_BEGIN
	l.position += offset
	return l


## A label centred horizontally at a fraction of the screen height.
func _centered(l: Label, y_frac: float) -> Label:
	add_child(l)
	l.anchor_left = 0.0
	l.anchor_right = 1.0
	l.anchor_top = y_frac
	l.anchor_bottom = y_frac
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.grow_vertical = Control.GROW_DIRECTION_BOTH
	return l


func _bar(col: Color, sz: Vector2, vertical: bool) -> ProgressBar:
	var b := ProgressBar.new()
	b.custom_minimum_size = sz
	b.size = sz
	b.max_value = 1.0
	b.show_percentage = false
	b.fill_mode = ProgressBar.FILL_BOTTOM_TO_TOP if vertical else ProgressBar.FILL_BEGIN_TO_END
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.5)
	var fg := StyleBoxFlat.new()
	fg.bg_color = col
	b.add_theme_stylebox_override("background", bg)
	b.add_theme_stylebox_override("fill", fg)
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(b)
	return b


func refresh() -> void:
	var st: FlightModel.FlightState = s.state
	if st == null:
		return
	var c: FlightModel.Controls = s.fm.controls
	var lo: Loadout = s.loadout
	var flaps := int(round(c.flaps * 3))
	var he: Array = s.range_estimate()
	var ferry := lo.ferry_fuel_lb()
	var fuel_line := "FUEL %5.0f lb" % st.fuel_lb
	if ferry > 0 or not lo.ferry_tanks().is_empty():
		fuel_line += " +%.0f ferry%s" % [ferry, " PUMP" if s.pumping else ""]
	var lines := [
		"IAS  %5.0f kt" % st.ias_kts,
		"GS   %5.0f kt" % st.gs_kts,
		"ALT  %5.0f ft" % (st.alt / 0.3048),
		"AGL  %5.0f ft" % maxf(0.0, st.agl / 0.3048 - s.fm.mass.gear_height_ft),
		"VS   %+5.0f fpm" % st.vs_fpm,
		"HDG  %5.0f" % fposmod(st.heading, 360),
		"PWR  %5.0f %%   RPM %4.0f" % [c.throttle * 100, st.rpm],
		"FLAP %d/3   TRIM %+.2f" % [flaps, -c.pitch_trim],
		fuel_line,
		("RNG  %5.0f km  (%.0f min)" % [he[1], he[0] * 60]) if not st.on_ground else "RNG     -- (airborne only)",
		"WT   %5.0f lb  CG %.1fin" % [st.weight_lb, st.cg_in],
		"XPDR %s   AP %s%s" % ["ON " + s.squawk if s.transponder else "OFF", "ON" if s.autopilot.engaged else "--",
			"   KICKING" if s.kick_queue else ""],
		"%s%sCAM:%s" % ["BRAKE " if c.brake > 0.5 else "", "YOKE:MOUSE " if mouse_yoke else "", cam_mode],
	]
	flight.text = "\n".join(lines)
	throttle_bar.value = c.throttle
	var wanted: int = s.police.wanted
	var det := ""
	if s.gear.has("detector"):
		det = {"LOCK": "  RADAR LOCK", "PAINT": "  radar paint"}.get(s.police.detector(), "  radar clear")
	var susp := "  suspicion %3.0f%%" % s.police.suspicion if s.police.suspicion > 1 and not wanted else ""
	status.text = "$%s\n%s\nWANTED [%s]%s%s\n%s" % [Py.money(s.money), s.spec.name, "*".repeat(wanted) + ".".repeat(3 - wanted),
		det, susp, ("At " + World.airfield(s.location).name) if s.location else ""]
	status.add_theme_color_override("font_color", UIStyle.RED if wanted else UIStyle.WHITE)
	var jl := []
	for j in s.active_jobs.slice(0, 6):
		var xy: Array = s.job_xy(j)
		var d := PyMath.hypot(xy[0] - st.x, xy[1] - st.y) / 1000
		var brg := UIStyle.bearing_to(st.x, st.y, xy[0], xy[1])
		var tl = j.time_left(s.time)
		var tls := " %d:%02d" % [int(tl / 60), int(fposmod(tl, 60))] if tl != null else ""
		var extra := ""
		if j.is_airdrop():
			var boat = s.maritime.boat(j.boat_id) if j.boat_id != null else null
			var left := Py.count(lo.items.values(), func(i): return i.job_id == j.id)
			extra = " [%d aboard, boat %s]" % [left, boat.state if boat != null else "?"]
		jl.append("%s%s %4.1fkm brg %03.0f%s  $%s%s" % ["!" if j.hot() else "", j.dest_label(), d, brg, tls, Py.money(j.payout), extra])
	jobs.text = "\n".join(jl)
	var il := []
	for m in s.scanner_log.slice(-3):
		if s.time - m[0] < 40:
			il.append("SCAN " + str(m[1]).substr(0, 52))
	intel.text = "\n".join(il)
	var camp = s.campaign
	objectives.text = ("%d - %s\n" % [camp.chapter.year, camp.chapter.title] + "\n".join(camp.objective_lines())) if camp != null else ""
	var ml := []
	for m in s.messages:
		if s.time - m[0] < 12:
			ml.append(m[1])
	msgs.text = "\n".join(ml)
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
	warn.text = "  ".join(warns)
	bust_bar.value = s.police.bust_meter / 100
	rival_bar.value = s.police.rival_meter / 100
	bust_bar.visible = s.police.bust_meter > 1
	rival_bar.visible = s.police.rival_meter > 1
	if s.phase in ["crashed", "busted"]:
		center.text = s.last_outcome + "\n\nPress ENTER to continue"
		hint.text = ""
	elif s.parked:
		var wb = lo.compute()
		var busy := "   loading... %.0f crew-s" % Py.sum_by(lo.pending.values(), func(v): return v) if not lo.pending.is_empty() else ""
		center.text = ""
		hint.text = "[J] Jobs  [L] Load & fuel  [H] Hangar & gear  [F1] Help%s%s" % ["" if wb.ok() else "   !! LOAD OUT OF LIMITS !!", busy]
	else:
		center.text = ""
		hint.text = ""
	_papi(st)


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
