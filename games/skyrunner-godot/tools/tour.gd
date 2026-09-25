extends SceneTree
## On-foot and world tour for the demo video (Movie Maker, fixed 30 fps):
##
##   xvfb-run godot --rendering-method gl_compatibility --write-movie tour.avi --fixed-fps 30 \
##       --script res://tools/tour.gd -- [graphics] [map_seed]
##
## Parked at the cove strip with the HQ season running: get out, run to the
## job board and open it, walk into the villa and issue an order from the
## boss's desk, then fly the camera past the three headquarters and over the
## island as the sun goes down.

var app: PilotApp
var s: Session
var t := 0.0
var shot := -1
var shots: Array = []  ## [duration, start callable, per-frame callable]
var shot_t := 0.0
var caption: Label
var path: Array = []
var target: Area3D = null  ## what the walk is heading for
var orbit := {}
var _stall := [Vector3.ZERO, 0.0]  ## last position, seconds without progress


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	var opts := {"seed": 9, "location": "COV", "features": Session.SANDBOX_FEATURES + ["hq"]}
	if a.size() > 1:
		opts["map_seed"] = int(a[1])
	s = Session.new(opts)
	s.nights.runner_ai = null
	app = PilotApp.new()
	root.add_child(app)
	app.setup(s, a[0] if a.size() > 0 else "high")
	app.scene.set_hour(9.5)
	app.cam_mode = "chase"
	caption = UIStyle.label("", 22, UIStyle.AMBER)
	caption.add_theme_stylebox_override("normal", UIStyle.panel_box(Color(0, 0, 0, 0.65)))
	caption.position = Vector2(24, 24)
	var layer := CanvasLayer.new()
	layer.layer = 50
	layer.add_child(caption)
	root.add_child(layer)
	shots = [
		[3.0, func(): _cap("Parked at %s. TAB: get out and walk." % World.airfield(s.location).name), Callable()],
		[7.0, _walk_to_board, _follow_path],
		[12.0, _cut_ahead, _follow_path],  # walks end early on arrival
		[3.5, func(): _use(), Callable()],
		[1.0, _close_menus, Callable()],
		[16.0, _walk_to_desk, _follow_path],
		[5.5, _desk_orders, Callable()],
		[7.0, func(): _orbit_hq("org", 13.0, "The organisation's villa: sited by the map generator near the cove."), _orbit_step],
		[7.0, func(): _orbit_hq("rival", 15.0, "Los Cuervos' compound: the rival outfit's base."), _orbit_step],
		[7.0, func(): _orbit_hq("law", 16.0, "The task-force HQ, radar turning on the roof."), _orbit_step],
		[9.0, _dusk_flyover, _orbit_step],
		[7.0, _night_villa, _orbit_step],
	]


func _close_menus() -> void:
	for m in app.menus.values():
		m.visible = false


func _cap(text: String) -> void:
	caption.text = "  " + text + "  "


func _areas(node: Node, action: String, out: Array) -> Array:
	if node is Area3D and node.get_meta("action", "") == action:
		out.append(node)
	for c in node.get_children():
		_areas(c, action, out)
	return out


func _nearest(action: String) -> Area3D:
	var best: Area3D = null
	for ar in _areas(app.scene, action, []):
		if best == null or ar.global_position.distance_to(app.walker.global_position) < best.global_position.distance_to(app.walker.global_position):
			best = ar
	return best


## A straight walk (with a dog-leg through `via` if given) to stand 1.3 m before `area`.
func _route_to(area: Area3D, via := []) -> void:
	var back: Vector3 = area.get_parent().global_transform.basis.z.normalized()
	path = via + [area.global_position - back * 1.3]
	target = area
	app.walker.look_enabled = true


func _walk_to_board() -> void:
	app._toggle_on_foot()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_cap("On foot: to the job board (E to use).")
	var board := _nearest("jobs")
	if board == null:
		board = _nearest("load")
	_route_to(board)


func _walk_to_desk() -> void:
	_cap("Into the villa: the boss's desk.")
	var desk := _nearest("hq_org")
	var node: Node3D = desk.get_parent()
	var door := node.global_transform * Vector3(0, 0, -9.0)  # out front, then in through the doorway
	var inside := node.global_transform * Vector3(0, 0, -3.5)
	# a real walk from the airstrip would be long: the cut puts us at the courtyard gate
	var gate := node.global_transform * Vector3(0, 0, -16.0)
	app.walker.place(gate.x, -gate.z, 0.0)
	_route_to(desk, [door, inside])


## Seven seconds of a hundred-metre run is enough: cut to the last stretch.
func _cut_ahead() -> void:
	if path.is_empty():
		return
	var w := app.walker
	var goal: Vector3 = path.back()
	var d := w.global_position.distance_to(goal)
	if d > 14.0:
		var p := goal + (w.global_position - goal).normalized() * 10.0
		w.place(p.x, -p.z, 0.0)


func _follow_path() -> void:
	var w := app.walker
	if path.is_empty():
		_key(KEY_W, false)
		_key(KEY_SHIFT, false)
		return
	var p: Vector3 = path[0]
	var flat := Vector3(p.x, w.global_position.y, p.z)
	if w.global_position.distance_to(flat) < 0.6:
		path.pop_front()
		return
	w.look_at(flat, Vector3.UP)
	_key(KEY_W, true)
	_key(KEY_SHIFT, w.global_position.distance_to(flat) > 2.5)
	# boxed in by furniture short of the point: close enough, take the next one
	if w.global_position.distance_to(_stall[0]) < 0.03:
		_stall[1] += 1.0 / 30.0
		if _stall[1] > 0.7:
			path.pop_front()
			_stall[1] = 0.0
	else:
		_stall = [w.global_position, 0.0]


## Stop, turn to face what we came for, and press E.
func _face_and_use() -> void:
	_key(KEY_W, false)
	_key(KEY_SHIFT, false)
	var w := app.walker
	if target != null:
		var p := target.global_position
		w.look_at(Vector3(p.x, w.global_position.y, p.z), Vector3.UP)
		w.cam.rotation.x = -0.25
		w._update_focus()
	w.use()


func _use() -> void:
	_face_and_use()
	_cap("E: the job board opens where you stand.")


func _desk_orders() -> void:
	_face_and_use()
	var m: HQMenu = app.menus["hq"]
	_cap("The boss's desk: tonight's orders, same rules as the boss station.")
	if m.visible:
		var i := m.rows.map(func(r): return r.key).find("route")
		if i >= 0:
			m.list.select(i)
			m._detail()
			m.key("right")


func _key(k: int, down: bool) -> void:
	if Input.is_physical_key_pressed(k) == down:
		return
	var ev := InputEventKey.new()
	ev.physical_keycode = k
	ev.keycode = k
	ev.pressed = down
	Input.parse_input_event(ev)


func _cinema() -> void:
	for m in app.menus.values():
		m.visible = false
	if app.on_foot:
		app.walker.set_physics_process(false)
		app.walker.cam.current = false
	app.cam.current = true
	app.set_process(false)  # the app would move its camera back
	app.hud.visible = false
	app.foot_prompt.visible = false


func _orbit_hq(kind: String, hour: float, text: String) -> void:
	_cinema()
	app.scene.set_hour(hour)
	var h: Dictionary = s.world.map.hqs[kind]
	var gz := s.world.ground(h.x, h.y)
	orbit = {"c": Vector3(h.x, gz + 3.0, -h.y), "r": 46.0, "hgt": 16.0, "a0": deg_to_rad(-h.heading) - PI / 2, "rate": 0.35}
	_cap(text)


func _dusk_flyover() -> void:
	app.scene.set_hour(18.2)
	orbit = {"c": Vector3(0, 0, 0), "r": 9000.0, "hgt": 2600.0, "a0": 0.4, "rate": 0.05, "look_y": 150.0}
	_cap("Sunset over %s." % ("the classic island" if s.world.map.id == "classic" else "island #%d" % s.world.map.map_seed))


func _night_villa() -> void:
	app.scene.set_hour(21.0)
	var h: Dictionary = s.world.map.hqs["org"]
	var gz := s.world.ground(h.x, h.y)
	orbit = {"c": Vector3(h.x, gz + 3.0, -h.y), "r": 40.0, "hgt": 10.0, "a0": deg_to_rad(-h.heading) - PI / 2 + 0.8, "rate": -0.25}
	_cap("Night: lit windows, the lamps are on at the villa.")


func _orbit_step() -> void:
	var a: float = orbit.a0 + orbit.rate * shot_t
	var c: Vector3 = orbit.c
	var pos := c + Vector3(cos(a) * orbit.r, orbit.hgt, sin(a) * orbit.r)
	var gz := s.world.ground(pos.x, -pos.z)
	pos.y = maxf(pos.y, gz + 4.0)
	app.cam.global_position = pos
	app.cam.look_at(c + Vector3(0, orbit.get("look_y", 0.0), 0), Vector3.UP)
	app.cam.fov = 55


func _process(dt: float) -> bool:
	t += dt
	shot_t += dt
	if shot < 0 or shot_t >= shots[shot][0]:
		shot += 1
		shot_t = 0.0
		if shot >= shots.size():
			return true
		shots[shot][1].call()
		if OS.get_environment("TOUR_DEBUG") != "":
			print("shot %d at %.1f s: menus %s" % [shot, t, app.menus.keys().filter(func(k): return app.menus[k].visible)])
	elif shots[shot][2].is_valid():
		shots[shot][2].call()
		# a walk is over when we get there (the menu shot follows straight on)
		if shots[shot][2] == _follow_path and path.is_empty() and shot_t > 0.5 and shot != 1:
			shot_t = shots[shot][0]
	return false
