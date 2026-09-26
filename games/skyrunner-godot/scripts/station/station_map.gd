class_name StationMap
extends Control
## The station's tactical map, drawn only from the role-filtered snapshot:
## runner seats see their aircraft, jobs, boats, bales and intel; the task force
## sees radar circles, tracks with 60 s velocity leaders, tips, units and the
## boats someone has eyes on; HQ seats see the three zones.
## Left-click / right-click are reported through `clicked(button, world_xy)`.

signal clicked(button: int, world_xy: Vector2)

var snap = null
var role := ""
var sel_unit = null
var tex: ImageTexture
var font: Font
var world: World


func setup(world_: World) -> StationMap:
	world = world_
	tex = ImageTexture.create_from_image(Models.minimap_image(world, 512))
	font = UIStyle.mono()
	clip_contents = true
	return self


func side() -> float:
	return minf(size.x, size.y)


## The square map is centred in whatever rectangle the desk gives it.
func origin() -> Vector2:
	return (size - Vector2(side(), side())) / 2


func w2m(x: float, y: float) -> Vector2:
	var s := side()
	return origin() + Vector2((x + World.HALF) / (2 * World.HALF) * s, s - (y + World.HALF) / (2 * World.HALF) * s)


func m2w(p: Vector2) -> Vector2:
	var s := side()
	p -= origin()
	return Vector2(p.x / s * 2 * World.HALF - World.HALF, (s - p.y) / s * 2 * World.HALF - World.HALF)


func _on_map(p: Vector2) -> bool:
	var q := p - origin()
	return q.x >= 0 and q.y >= 0 and q.x <= side() and q.y <= side()


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed and _on_map(ev.position):
		clicked.emit(ev.button_index, m2w(ev.position))
		accept_event()


func mouse_world():
	var p := get_local_mouse_position()
	if not _on_map(p):
		return null
	return m2w(p)


func _process(_dt: float) -> void:
	queue_redraw()


func _circle(x: float, y: float, r: float, col: Color, w := 1.5) -> void:
	draw_arc(w2m(x, y), r / (2 * World.HALF) * side(), 0, TAU, 48, col, w)


func _arrow(x: float, y: float, hdg: float, col: Color, size_px := 12.0) -> void:
	var c := w2m(x, y)
	var h := deg_to_rad(hdg)
	var f := Vector2(sin(h), -cos(h))
	var r := Vector2(-f.y, f.x)
	var pts := PackedVector2Array([c + f * size_px, c - f * size_px * 0.6 + r * size_px * 0.6, c - f * size_px * 0.6 - r * size_px * 0.6, c + f * size_px])
	draw_polyline(pts, col, 2.0)


func _cross(x: float, y: float, col: Color, s := 6.0) -> void:
	var c := w2m(x, y)
	draw_line(c - Vector2(s, s), c + Vector2(s, s), col, 2.0)
	draw_line(c + Vector2(-s, s), c + Vector2(s, -s), col, 2.0)


func _text(x: float, y: float, t: String, col: Color) -> void:
	draw_string(font, w2m(x, y) + Vector2(8, -6), t, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, col)


func _draw() -> void:
	var s := side()
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.12, 0.25, 0.42))  # open sea round the square chart
	draw_texture_rect(tex, Rect2(origin(), Vector2(s, s)), false)
	for af in World.AIRFIELDS:
		var a: Array = af.threshold(0)
		var b: Array = af.threshold(1)
		draw_line(w2m(a[0], a[1]), w2m(b[0], b[1]), Color.WHITE, 2.0)
		_text(af.x + 300, af.y + 200, af.code, Color(1, 1, 1, 0.9))
	if not (snap is Dictionary):
		return
	if role in [Roles.BOSS, Roles.CHIEF]:
		for z in HQ.ZONE_CENTRE:
			var c: Array = HQ.ZONE_CENTRE[z]
			_circle(c[0], c[1], 4500, Color(0.9, 0.8, 0.3, 0.6), 2.0)
			_text(c[0], c[1], z.to_upper(), Color(1, 0.9, 0.4))
		var ss = snap.get("season")
		if ss is Dictionary:
			var route = ss.get("org", {}).get("route") if ss.has("org") else null
			var patrol = ss.get("law", {}).get("patrol") if ss.has("law") else ss.get("patrol_leak")
			if route != null:
				var c: Array = HQ.ZONE_CENTRE[route]
				_circle(c[0], c[1], 5200, Color(0.4, 1, 0.4), 3.0)
			if patrol != null:
				var c: Array = HQ.ZONE_CENTRE[patrol]
				_circle(c[0], c[1], 5600, Color(0.4, 0.6, 1), 3.0)
	elif snap.get("side") == "law":
		_draw_law()
	else:
		_draw_runner()


func _draw_runner() -> void:
	for j in snap.get("jobs", []):
		_circle(j.x, j.y, 600, Color(0.3, 1, 0.3), 2.0)
		_text(j.x, j.y, str(j.dest), Color(0.4, 1, 0.4))
	for b in snap.get("boats", []):
		_arrow(b.x, b.y, b.heading, Color(0.3, 0.8, 1), 9)
		_text(b.x, b.y, "%s %s [%d]" % [b.id, b.state, int(b.cargo)], Color(0.5, 0.85, 1))
	for bl in snap.get("bales", []):
		_cross(bl.x, bl.y, Color(1, 0.9, 0.3), 3)
	for it in snap.get("intel", []):
		_cross(it.x, it.y, Color(1, 0.3, 0.3) if it.age < 10 else Color(0.6, 0.3, 0.3))
		_text(it.x, it.y, "%s %s %.0fs" % [it.unit, it.source, it.age], Color(1, 0.5, 0.5))
	for sp in snap.get("spotters", []):
		var af := World.airfield(sp.code)
		_circle(af.x, af.y, 5000, Color(1, 1, 0.4, 0.5))
	var ac = snap.get("aircraft")
	if ac is Dictionary:
		_arrow(ac.x, ac.y, ac.heading, Color(1, 1, 0), 16)


## Coverage overlay: cells no active radar sees at `coverage_agl` m above the
## ground are shaded - the valleys a smuggler flies. Computed locally from the
## same terrain (it never crosses the network).
var coverage_agl := 0.0
var _cov_net: SensorNet
var _cov_img: ImageTexture
var _cov_key := ""


func _draw_coverage() -> void:
	var active: Array = snap.get("radars", []).filter(func(r): return r.active).map(func(r): return r.code)
	var key := "%d/%s" % [int(coverage_agl), ",".join(active)]
	if key != _cov_key:
		_cov_key = key
		if _cov_net == null:
			_cov_net = SensorNet.new(world)
		var n := 48
		var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
		for j in n:
			for i in n:
				var seen := false
				for code in active:
					if _cov_net.coverage(code, coverage_agl, n)[j * n + i]:
						seen = true
						break
				img.set_pixel(i, j, Color(0, 0, 0, 0) if seen else Color(0.05, 0.05, 0.1, 0.55))
		_cov_img = ImageTexture.create_from_image(img)
	var sd := side()
	draw_texture_rect(_cov_img, Rect2(origin(), Vector2(sd, sd)), false)
	draw_string(font, origin() + Vector2(8, sd - 10), "blind below %d m AGL shaded" % int(coverage_agl),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.8, 0.9, 1))


func _draw_law() -> void:
	if coverage_agl > 0:
		_draw_coverage()
	for r in snap.get("radars", []):
		_circle(r.x, r.y, r.range, Color(1, 0.25, 0.25, 0.6) if r.active else Color(0.4, 0.2, 0.2, 0.4))
		if r.active and r.has("beam"):
			# the rotating beam, with a fading wake behind it like a PPI scope
			var a := deg_to_rad(float(r.beam))
			for k in 6:
				var ak := a - deg_to_rad(4.0 * k)
				draw_line(w2m(r.x, r.y), w2m(r.x + sin(ak) * r.range, r.y + cos(ak) * r.range),
					Color(0.4, 1, 0.5, 0.5 - 0.08 * k), 2.0 if k == 0 else 1.0)
	for d in snap.get("df", []):
		# DF: every bearing line, and the fix's 2-sigma error ellipse
		var fade := clampf(1.0 - float(d.age) / 120.0, 0.2, 1.0)
		for b in d.bearings:
			var a := deg_to_rad(float(b[3]))
			draw_line(w2m(b[1], b[2]), w2m(b[1] + sin(a) * 30000.0, b[2] + cos(a) * 30000.0), Color(0.6, 0.8, 1, 0.55 * fade), 1.0)
		if d.fix != null and d.ellipse != null:
			var e: Array = d.ellipse
			var pts := PackedVector2Array()
			var th := deg_to_rad(float(e[2]))
			for k in 33:
				var u := TAU * k / 32.0
				var ax: float = e[0] * cos(u)
				var bx: float = e[1] * sin(u)
				# major axis along bearing th (from north)
				pts.append(w2m(d.fix[0] + ax * sin(th) + bx * cos(th), d.fix[1] + ax * cos(th) - bx * sin(th)))
			draw_polyline(pts, Color(0.6, 0.85, 1, 0.9 * fade), 2.0)
			_text(d.fix[0], d.fix[1], "DF %.0fs" % float(d.age), Color(0.7, 0.9, 1))
	for z in snap.get("jammed", []):
		_circle(z[0], z[1], z[2], Color(1, 0.3, 0.9, 0.85), 2.0)
		_text(z[0], z[1], "JAMMED", Color(1, 0.45, 0.95))
	for tip in snap.get("tips", []):
		_circle(tip.x, tip.y, tip.r, Color(1, 0.8, 0.2, 0.8), 2.0)
		_text(tip.x, tip.y, str(tip.text).substr(0, 28), Color(1, 0.85, 0.3))
	for t in snap.get("tracks", []):
		var c := w2m(t.x, t.y)
		var stale: bool = t.age >= 6
		var col := Color(1, 0.3, 0.3) if t.age < 6 else Color(0.6, 0.3, 0.3)
		var trail: Array = t.get("trail", [])
		for k in trail.size():
			draw_circle(w2m(trail[k][0], trail[k][1]), 2.0, Color(col.r, col.g, col.b, 0.15 + 0.5 * k / maxf(1.0, trail.size())))
		if stale:  # coasting: dead-reckoned, drawn open
			draw_arc(c, 7, 0, TAU, 12, col, 1.5)
		else:
			draw_rect(Rect2(c - Vector2(6, 6), Vector2(12, 12)), col, false, 2.0)
		draw_line(c, w2m(t.x + t.vx * 60, t.y + t.vy * 60), col, 1.5)
		var nm: String = t.squawk if t.squawk else "TRK %s" % t.id
		var mode := ""
		if t.has("code"):
			# Mode A code and Mode C altitude in hundreds of feet, as a real data block shows them
			mode = (" %s A%03d" % [t.code, int(float(t.alt) / 0.3048 / 100)]) if t.get("alt") != null else " no alt"
		var emergency: bool = t.get("code") in ["7500", "7600", "7700"]
		_text(t.x, t.y, "%s%s %s %.0fs" % [nm, mode, t.source, t.age], Color(1, 0.2, 0.9) if emergency else Color(1, 0.5, 0.5))
	for b in snap.get("boats", []):
		_arrow(b.x, b.y, b.heading, Color(1, 0.6, 0.2), 9)
		_text(b.x, b.y, "go-fast %s" % b.state, Color(1, 0.7, 0.3))
	for u in snap.get("units", []):
		var col := Color(0.4, 0.7, 1) if u.id != sel_unit else Color.WHITE
		if u.state == "crashed":
			_cross(u.x, u.y, Color(0.5, 0.5, 0.5))
			continue
		_arrow(u.x, u.y, u.heading, col, 11)
		_text(u.x, u.y, "%s %s%s" % [u.id, u.state, " EYES ON" if u.sees else ""], col)
