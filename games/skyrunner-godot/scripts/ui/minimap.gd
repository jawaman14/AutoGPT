class_name Minimap
extends Control
## North-up island map: strips, radar circles, your jobs, boats, bales, and the
## police you actually know about (eyeballs, scanner, spotters). Port of
## render/hud.py Minimap. M toggles the big map.

var s: Session
var tex: ImageTexture
var big := false
const SMALL := 220.0
const BIG := 560.0


func setup(sess: Session) -> Minimap:
	s = sess
	tex = ImageTexture.create_from_image(Models.minimap_image(sess.world, 256))
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	_layout()
	return self


func _layout() -> void:
	var sz := BIG if big else SMALL
	custom_minimum_size = Vector2(sz, sz)
	size = Vector2(sz, sz)
	set_anchors_preset(Control.PRESET_BOTTOM_RIGHT if not big else Control.PRESET_CENTER)
	if big:
		position = (get_parent_area_size() - size) / 2 if is_inside_tree() else Vector2.ZERO
	else:
		position = (get_parent_area_size() if is_inside_tree() else Vector2(1280, 720)) - size - Vector2(12, 12)


func toggle() -> void:
	big = not big
	_layout()


func to_map(x: float, y: float) -> Vector2:
	var sz := size.x
	x = clampf(x, -World.HALF, World.HALF)
	y = clampf(y, -World.HALF, World.HALF)
	return Vector2((x + World.HALF) / (2 * World.HALF) * sz, sz - (y + World.HALF) / (2 * World.HALF) * sz)


func _process(_dt: float) -> void:
	if not big:
		position = get_parent_area_size() - size - Vector2(12, 12)
	queue_redraw()


func _cross(p: Vector2, col: Color, r := 5.0) -> void:
	draw_line(p - Vector2(r, r), p + Vector2(r, r), col, 2.0)
	draw_line(p + Vector2(-r, r), p + Vector2(r, -r), col, 2.0)


func _draw() -> void:
	if s == null:
		return
	var sz := size.x
	draw_texture_rect(tex, Rect2(Vector2.ZERO, size), false)
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.6), false, 2.0)
	var font := UIStyle.mono()
	for af in s.world.airfields:
		var col := Color(1, 1, 1) if af.kind in ["hub", "regional"] else Color(1, 0.8, 0.3)
		var a: Array = af.threshold(0)
		var b: Array = af.threshold(1)
		draw_line(to_map(a[0], a[1]), to_map(b[0], b[1]), col, 3.0)
		draw_string(font, to_map(af.x + 600, af.y + 400), af.code, HORIZONTAL_ALIGNMENT_LEFT, -1, 11 if not big else 15, Color(1, 1, 1, 0.9))
		if af.radar_km:
			draw_arc(to_map(af.x, af.y), af.radar_km * 1000 / (2 * World.HALF) * sz, 0, TAU, 48, Color(1, 0.2, 0.2, 0.5), 1.5)
	for j in s.active_jobs:
		var xy: Array = s.job_xy(j)
		draw_arc(to_map(xy[0], xy[1]), 8, 0, TAU, 16, Color(0.3, 0.8, 1) if j.is_airdrop() else Color(0.3, 1, 0.3), 2.0)
	for b in s.maritime.boats:
		if b.kind == "gofast" and b.state != "delivered":
			_cross(to_map(b.x, b.y), Color(0.3, 0.9, 1), 4)
	for bl in s.maritime.bales:
		if bl.state == "floating":
			_cross(to_map(bl.x, bl.y), Color(1, 0.9, 0.3), 2.5)
	var st: FlightModel.FlightState = s.state
	var known := {}
	for k in s.intel:
		var v: Array = s.intel[k]
		if v[0] <= s.time:
			known[k] = [v[1], v[2]]
	if st != null:
		for u in s.police.units:
			if u.state != "crashed" and PyMath.hypot3(u.x - st.x, u.y - st.y, u.z - st.alt) < PoliceSystem.SIGHT_RANGE_M:
				known[u.id] = [u.x, u.y]
		for c in s.maritime.boats:
			if c.kind == "cutter" and PyMath.hypot(c.x - st.x, c.y - st.y) < 9000:
				known[c.id] = [c.x, c.y]
	for uid in known:
		_cross(to_map(known[uid][0], known[uid][1]), Color(0.8, 0.3, 1) if str(uid).begins_with("Rival") else Color(0.3, 0.5, 1))
	if st != null:
		var h := deg_to_rad(st.heading)
		var c := to_map(st.x, st.y)
		var f := Vector2(sin(h), -cos(h))
		var r := Vector2(-f.y, f.x)
		draw_colored_polygon(PackedVector2Array([c + f * 10, c - f * 6 + r * 6, c - f * 6 - r * 6]), Color(1, 1, 0))
