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


func setup(world: World) -> StationMap:
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


func _draw_law() -> void:
	for r in snap.get("radars", []):
		_circle(r.x, r.y, r.range, Color(1, 0.25, 0.25, 0.6) if r.active else Color(0.4, 0.2, 0.2, 0.4))
	for tip in snap.get("tips", []):
		_circle(tip.x, tip.y, tip.r, Color(1, 0.8, 0.2, 0.8), 2.0)
		_text(tip.x, tip.y, str(tip.text).substr(0, 28), Color(1, 0.85, 0.3))
	for t in snap.get("tracks", []):
		var c := w2m(t.x, t.y)
		var col := Color(1, 0.3, 0.3) if t.age < 3 else Color(0.6, 0.3, 0.3)
		draw_rect(Rect2(c - Vector2(6, 6), Vector2(12, 12)), col, false, 2.0)
		draw_line(c, w2m(t.x + t.vx * 60, t.y + t.vy * 60), col, 1.5)
		var nm: String = t.squawk if t.squawk else "TRK %s" % t.id
		_text(t.x, t.y, "%s %s %.0fs" % [nm, t.source, t.age], Color(1, 0.5, 0.5))
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
