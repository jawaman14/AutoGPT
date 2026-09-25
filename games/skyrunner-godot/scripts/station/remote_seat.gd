class_name RemoteSeat
extends Node3D
## Remote 3D seats (port of render/remote.py): a co-pilot in the right seat,
## or a police pilot flying a unit, on another machine.
##
## The host runs the only simulation. This client builds the same procedural
## world (same seed, so only entity state crosses the wire) and draws aircraft,
## units and boats from role-filtered snapshots:
##   * interpolated 100 ms behind the newest snapshot (20 Hz over TCP)
##   * fog of war: the police pilot only gets another aircraft's position while
##     their own unit can actually see it; radar tracks are listed on the HUD
##   * crew keys (kick, pump, call boat, auto-kick) are ordinary commands; the
##     police pilot's stick goes up as fire-and-forget input

const INTERP_DELAY_S := 0.10
const CREW_KEYS := {KEY_K: "kick", KEY_O: "call_boat", KEY_V: "pump", KEY_T: "auto_kick"}

var link
var role := ""
var quality: Quality
var scene: WorldScene
var cam: Camera3D
var hud: Label
var msg: Label
var buf: Array = []  ## [arrival_s, snap]
var nodes := {}  ## key -> Node3D
var cam_mode := "cockpit"
var look := Vector2(0, -5)  ## head yaw, pitch
var throttle := 0.6
var _last_input := 0.0


func setup(link_, role_: String, graphics := "medium", world: World = null) -> RemoteSeat:
	link = link_
	role = role_
	quality = Quality.get_preset(graphics)
	scene = WorldScene.new().setup(world if world != null else World.new(), quality)
	add_child(scene)
	cam = Camera3D.new()
	cam.near = 0.5
	cam.far = 60000.0
	cam.fov = 75
	add_child(cam)
	cam.current = true
	var ui := CanvasLayer.new()
	add_child(ui)
	hud = UIStyle.label("Connecting...", 17, Color(0.6, 1, 0.6), UIStyle.mono())
	hud.position = Vector2(14, 10)
	ui.add_child(hud)
	msg = UIStyle.label("", 16)
	msg.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	msg.grow_vertical = Control.GROW_DIRECTION_BEGIN
	msg.position += Vector2(14, -20)
	ui.add_child(msg)
	return self


static func _lerp_angle(a: float, b: float, t: float) -> float:
	return a + (fposmod(b - a + 180.0, 360.0) - 180.0) * t


func _push(snap) -> void:
	if not (snap is Dictionary):
		return
	if not buf.is_empty() and buf.back()[1].get("seq") == snap.get("seq"):
		return
	buf.append([Time.get_ticks_msec() / 1000.0, snap])
	if buf.size() > 8:
		buf = buf.slice(-8)


## extract(snap) -> {x, y, z, heading[, pitch, roll]} or null, interpolated.
func pose(extract: Callable):
	if buf.is_empty():
		return null
	var t := Time.get_ticks_msec() / 1000.0 - INTERP_DELAY_S
	var older = null
	var newer = null
	for it in buf:
		if it[0] <= t:
			older = it
		elif newer == null:
			newer = it
	if older == null:
		return extract.call(buf[0][1])
	if newer == null:
		return extract.call(older[1])
	var a = extract.call(older[1])
	var b = extract.call(newer[1])
	if a == null or b == null:
		return b if b != null else a
	var f: float = (t - older[0]) / maxf(1e-6, newer[0] - older[0])
	var out: Dictionary = b.duplicate()
	for k in ["x", "y", "z"]:
		out[k] = a[k] + (b[k] - a[k]) * f
	for k in ["heading", "pitch", "roll"]:
		if a.has(k) and b.has(k):
			out[k] = _lerp_angle(a[k], b[k], f)
	return out


func _unhandled_input(ev: InputEvent) -> void:
	if not (ev is InputEventKey and ev.pressed and not ev.echo):
		return
	var k: int = ev.physical_keycode if ev.physical_keycode else ev.keycode
	if k == KEY_ESCAPE:
		get_tree().quit()
	elif k == KEY_C:
		cam_mode = "chase" if cam_mode == "cockpit" else "cockpit"
	elif role == Roles.INTERCEPTOR:
		if k == KEY_SPACE:
			link.send_command("claim_unit", {"kind": "interceptor"})
		elif k == KEY_H:
			link.send_command("claim_unit", {"kind": "heli"})
		elif k == KEY_X:
			link.send_command("release_unit", {})
	elif CREW_KEYS.has(k):
		link.send_command(CREW_KEYS[k], {})


func _axis(neg: Array, pos: Array) -> float:
	var v := 0.0
	for key in pos:
		if Input.is_physical_key_pressed(key):
			v += 1.0
			break
	for key in neg:
		if Input.is_physical_key_pressed(key):
			v -= 1.0
			break
	return v


func _process(delta: float) -> void:
	var dt := minf(delta, 0.1)
	link.tick(dt)
	var snap = link.snapshot()
	if not (snap is Dictionary):
		hud.text = "Connecting..." if link.error == null else "Disconnected: %s" % link.error
		return
	_push(snap)
	if role == Roles.INTERCEPTOR:
		var roll := _axis([KEY_A, KEY_LEFT], [KEY_D, KEY_RIGHT])
		var pitch := _axis([KEY_W, KEY_UP], [KEY_S, KEY_DOWN])
		throttle = clampf(throttle + _axis([KEY_F], [KEY_R]) * 0.5 * dt, 0.0, 1.0)
		var now := Time.get_ticks_msec() / 1000.0
		if now - _last_input > 1.0 / 30:
			_last_input = now
			link.send_input(roll, pitch, throttle)
	else:
		look.x += _axis([KEY_D, KEY_RIGHT], [KEY_A, KEY_LEFT]) * 90 * dt
		look.y = clampf(look.y + _axis([KEY_S, KEY_DOWN], [KEY_W, KEY_UP]) * 60 * dt, -60, 40)
	var me := _sync(snap)
	_camera(me)
	_hud(snap)


func _node(key: String, factory: Callable) -> Node3D:
	if not nodes.has(key):
		var n: Node3D = factory.call()
		add_child(n)
		nodes[key] = n
	return nodes[key]


func _place(n: Node3D, p: Dictionary) -> void:
	n.position = MeshBuilder.to_godot([p.x, p.y, p.z])
	n.basis = PilotApp._basis(p.heading, p.get("pitch", 0.0), p.get("roll", 0.0))


func _pursuer(kind: String) -> Node3D:
	return Models.build_pursuer(kind if kind in ["heli", "interceptor", "rival"] else "heli", quality)[0]


func _aircraft(key: String) -> Node3D:
	var spec: Aircraft.Spec = Aircraft.ROSTER.get(key, Aircraft.ROSTER["c172p"])
	return Models.build_aircraft(spec.visual, 1.2, quality)[0]


func _sync(snap: Dictionary) -> Node3D:
	var seen := {}
	var me: Node3D = null
	if Roles.side(role) == "runner":
		var ac = snap.get("aircraft")
		if ac is Dictionary:
			var key := "me:" + str(ac.get("key", "c172p"))
			me = _node(key, func(): return _aircraft(ac.get("key", "c172p")))
			var p = pose(func(s):
				var a = s.get("aircraft")
				return {"x": a.x, "y": a.y, "z": a.alt, "heading": a.heading, "pitch": a.get("pitch", 0.0), "roll": a.get("roll", 0.0)} if a is Dictionary else null)
			if p != null:
				_place(me, p)
			seen[key] = true
		for it in snap.get("intel", []):
			if it.get("source") == "visual" and it.has("z"):
				var key := "u:" + str(it.unit)
				var n := _node(key, func(): return _pursuer(it.get("kind", "heli")))
				var uid = it.unit
				var p = pose(func(s):
					for i in s.get("intel", []):
						if i.unit == uid and i.has("z"):
							return {"x": i.x, "y": i.y, "z": i.z, "heading": i.heading, "roll": i.get("bank", 0.0)}
					return null)
				if p != null:
					_place(n, p)
				seen[key] = true
		for b in snap.get("boats", []):
			var key := "b:" + str(b.id)
			var n := _node(key, func(): return Models.build_boat("gofast")[0])
			n.position = MeshBuilder.to_godot([b.x, b.y, 0.1])
			n.basis = PilotApp._basis(b.heading)
			seen[key] = true
	else:
		var m = snap.get("me")
		if m is Dictionary:
			var key := "me:" + str(m.kind)
			me = _node(key, func(): return _pursuer(m.kind))
			var p = pose(func(s): return s.get("me"))
			if p != null:
				_place(me, p)
			seen[key] = true
		for v in snap.get("visual", []):
			var key := "v:" + str(v.id)
			var n: Node3D
			if v.kind in ["runner", "ai"]:
				n = _node(key, func(): return _aircraft(v.get("type", "c172p")))
			else:
				n = _node(key, func(): return _pursuer(v.kind))
			var vid = v.id
			var p = pose(func(s):
				for x in s.get("visual", []):
					if x.id == vid:
						return x
				return null)
			if p != null:
				_place(n, p)
			seen[key] = true
	for key in nodes.keys():
		if not seen.has(key):
			nodes[key].queue_free()
			nodes.erase(key)
	return me


func _camera(me: Node3D) -> void:
	if me == null:
		cam.global_position = MeshBuilder.to_godot([0.0, -20000.0, 3000.0])
		cam.look_at(Vector3.ZERO, Vector3.UP)
		return
	if cam_mode == "cockpit":
		me.visible = false
		var side := 0.35 if role == Roles.COPILOT else 0.0  # right seat
		cam.global_transform = me.global_transform * Transform3D(
			Basis.from_euler(Vector3(deg_to_rad(look.y), deg_to_rad(look.x), 0), EULER_ORDER_YXZ), MeshBuilder.to_godot([side, 1.2, 1.1]))
	else:
		me.visible = true
		cam.global_transform = me.global_transform * Transform3D(Basis.from_euler(Vector3(deg_to_rad(-10), 0, 0)),
			MeshBuilder.to_godot([0.0, -22.0, 6.0]))


func _hud(snap: Dictionary) -> void:
	var lines := []
	if Roles.side(role) == "runner":
		var ac: Dictionary = snap.get("aircraft") if snap.get("aircraft") is Dictionary else {}
		var wb: Dictionary = snap.get("loadout", {}).get("wb", {})
		lines = [
			"CO-PILOT  %s  %s" % [ac.get("type", ""), ac.get("phase", "")],
			"IAS %.0f  ALT %.0f ft  HDG %.0f" % [ac.get("ias", 0), ac.get("alt", 0) / 0.3048, ac.get("heading", 0)],
			"FUEL %.0f + ferry %.0f lb  pump %s" % [ac.get("fuel", 0), ac.get("ferry_fuel", 0), "ON" if ac.get("pumping") else "off"],
			"W&B %.0f lb  CG %.1f  %s" % [wb.get("weight", 0), wb.get("cg", 0), "OK" if wb.get("ok") else "OUT"],
			"XPDR %s  RADAR %s  WANTED %s" % ["on" if ac.get("transponder") else "OFF", ac.get("detector") if ac.get("detector") else "-", "*".repeat(int(ac.get("wanted", 0)))],
			"kick queue %d  auto-kick %s" % [int(ac.get("kick_queue", 0)), "on" if ac.get("auto_kick") else "off"],
			"K kick  V pump  O call boat  T auto-kick  arrows look  C camera",
		]
		var ss = snap.get("season")
		if ss is Dictionary:
			lines.append("NIGHT %d/%d  heat %d" % [int(ss.night), int(ss.nights), int(ss.public.heat)])
	else:
		var m = snap.get("me")
		if m is Dictionary:
			var vis := []
			for v in snap.get("visual", []):
				if v.kind in ["runner", "ai"]:
					vis.append("%s %.1fkm" % [v.id, v.dist / 1000])
			lines = [
				"%s (%s)  %.0f kt  ALT %.0f ft  AGL %.0f" % [m.id, m.kind, m.speed_kts, m.z / 0.3048, m.agl / 0.3048],
				"HDG %.0f  bank %.0f  throttle %d%%  fuel %.1f min" % [m.heading, m.roll, int(throttle * 100), m.fuel_s / 60],
				"BUST %.0f%%   visual: %s" % [snap.get("bust_meter", 0), ", ".join(vis) if vis else "none"],
				"WASD fly  R/F throttle  X hand back to AI  C camera",
			]
		else:
			lines = ["POLICE PILOT - no aircraft", "SPACE launch an interceptor   H a helicopter" + ("   (launching...)" if snap.get("claim_pending") else "")]
		var tracks: Array = snap.get("tracks", []).map(func(t): return "%s %s %.0fs" % [t.id, t.source, t.age])
		lines.append("RADAR: " + (", ".join(tracks) if tracks else "no tracks"))
	hud.text = "\n".join(lines)
	msg.text = "\n".join(snap.get("messages", []).slice(-4))
