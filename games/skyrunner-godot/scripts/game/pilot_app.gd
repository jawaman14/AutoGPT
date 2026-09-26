class_name PilotApp
extends Node3D
## The pilot's seat: world scene, aircraft, cameras, keyboard/mouse/joystick
## input, HUD and ground menus (port of render/app.py SkyrunnerApp).
##
## A bot (AutoRunner) can fly instead of the keyboard (--watch). A HostServer,
## if given, is pumped before and published after each session update.

const CAM_MODES := ["chase", "cockpit", "tower"]

const HELD_KEYS := {
	"pitch_up": [KEY_S, KEY_DOWN],
	"pitch_down": [KEY_W, KEY_UP],
	"roll_left": [KEY_A, KEY_LEFT],
	"roll_right": [KEY_D, KEY_RIGHT],
	"yaw_left": [KEY_Q],
	"yaw_right": [KEY_E],
	"throttle_up": [KEY_R, KEY_PAGEUP],
	"throttle_down": [KEY_F, KEY_PAGEDOWN],
	"brake": [KEY_B, KEY_SPACE],
	"trim_up": [KEY_BRACKETRIGHT],
	"trim_down": [KEY_BRACKETLEFT],
}
const CREW_KEYS := {KEY_N: "transponder", KEY_U: "autopilot", KEY_K: "kick", KEY_O: "call_boat", KEY_V: "pump", KEY_I: "turn_around"}
const PRESS_KEYS := {KEY_G: "flaps_down", KEY_T: "flaps_up", KEY_X: "throttle_cut", KEY_Z: "throttle_full", KEY_ENTER: "confirm", KEY_KP_ENTER: "confirm"}
const MENU_KEYS := {KEY_UP: "up", KEY_DOWN: "down", KEY_LEFT: "left", KEY_RIGHT: "right", KEY_ENTER: "enter",
	KEY_KP_ENTER: "enter", KEY_A: "a", KEY_PLUS: "+", KEY_EQUAL: "+", KEY_KP_ADD: "+", KEY_MINUS: "-", KEY_KP_SUBTRACT: "-", KEY_F: "f", KEY_G: "g"}

const HELP_TEXT := """SKYRUNNER - controls

Flight   W/S or UP/DOWN pitch     A/D or LEFT/RIGHT roll     Q/E rudder / nosewheel
         R/F or PGUP/PGDN throttle   X cut throttle   Z full throttle
         G flaps down   T flaps up   [ / ] pitch trim   B or SPACE brakes
         Y toggle mouse yoke (mouse position = stick)   joystick / gamepad work too
View     C cycle camera (chase / cockpit / tower)    M big map    P pause   F2 time of day
Seats    F3 hand the aircraft to the AI (take another seat from a station) / take it back
On foot  TAB get out (parked) / back in    WASD walk  SHIFT run  SPACE jump  mouse look
         Guns (with a ground war): 1-4 pistol / rifle / machine gun / RPG from the armoury  H holster  R reload  LMB fire
         E use (job board, fuel, hangar, the boss's desk)   F torch
Ground   J job board   L load planner & fuel   H hangar, gear, crew (LEFT/RIGHT: upgrade trees)
Crew     N transponder on/off   7 squawk code (1200 VFR / 7700 / 7600 / 7500)   U autopilot
         K kick a bale   O call the boat (SHIFT+O: the 1 s codeword - harder to DF)
         V ferry fuel pump   I push aircraft round (stopped)   ENTER continue   ESC close menu / quit
Radar    fly across a radar's beam or slow and the MTI loses you; low over rough sea or in rain the
         clutter hides you; the detector shows who's painting you and from where

Goal: haul passengers & cargo between strips for money. Balance the load:
too heavy = long roll & weak climb, CG too far aft = pitch-up / stall,
too far forward = can't flare. Short strips pay more.
Hot jobs pay big. Squawking looks legit; flying dark (transponder off) is
invisible only below the radar floor - and a squawk that vanishes on radar
is a red flag. Airdrops: fly low and slow over the boat, K to kick
(solo: autopilot first). Police within 350 m for a few seconds = busted."""

var nerves: Nerves
var _weather_rev := -1
var s: Session
var quality: Quality
var bot = null  ## AutoRunner
var server = null  ## HostServer
var scene: WorldScene
var cam: Camera3D
var player: Node3D
var props: Array = []
var ac_lights := {}
var dust: GPUParticles3D
var _player_key := ""
var hud: Hud
var menus := {}
var help: Label
var briefing: Label
var glareshield: Control
var ui: CanvasLayer
var cam_mode := "chase"
var mouse_yoke := false
var paused := false
var _pressed := {}
var _cam_pos = null
var pursuer_nodes := {}  ## Pursuer (instance id) -> [node, spinners, lights]
var squads: SquadRender = null  ## the ground war's men and vehicles (sessions with one)
var boat_nodes := {}
var bale_nodes := {}
var beacons: Array = []  ## [key, [nodes]]
var _frame := 0
var on_foot := false
var walker: Walker = null
var gun: Gunplay = null
var _auto_bot := false  ## the AI took the stick because nobody's in the pilot seat  ## the walker's gun (sessions with a ground war)
var ground_body: StaticBody3D = null
var foot_prompt: Label
var aircraft_body: StaticBody3D = null


func setup(sess: Session, graphics := "high", bot_ = null, server_ = null) -> PilotApp:
	s = sess
	quality = Quality.get_preset(graphics)
	bot = bot_
	server = server_
	if server != null:
		server.attach(sess)
	name = "PilotApp"
	scene = WorldScene.new().setup(sess.world, quality)
	add_child(scene)
	if sess.ground != null:
		squads = SquadRender.new()
		squads.setup(sess.world, graphics)
		add_child(squads)
	nerves = Nerves.new().setup()
	nerves.layer = 0  # over the 3D view, under the HUD (layer 1) and menus
	add_child(nerves)
	cam = Camera3D.new()
	cam.near = 0.5
	cam.far = 60000.0
	cam.fov = 70
	add_child(cam)
	cam.current = true
	_build_player()
	ui = CanvasLayer.new()
	add_child(ui)
	glareshield = _build_glareshield()
	ui.add_child(glareshield)
	hud = Hud.new().setup(sess)
	ui.add_child(hud)
	for k in [["j", JobMenu], ["l", LoadMenu], ["h", HangarMenu], ["hq", HQMenu], ["intel", HQMenu]]:
		var m: GameMenu = k[1].new()
		ui.add_child(m)
		if k[0] == "intel":
			m.intel = true
		m.setup(sess)
		m.closed.connect(_menu_closed)
		menus[k[0]] = m
	foot_prompt = UIStyle.label("", 20, UIStyle.WHITE)
	foot_prompt.add_theme_stylebox_override("normal", UIStyle.panel_box(Color(0, 0, 0, 0.55)))
	foot_prompt.set_anchors_preset(Control.PRESET_CENTER)
	foot_prompt.grow_horizontal = Control.GROW_DIRECTION_BOTH
	foot_prompt.position += Vector2(0, 70)
	foot_prompt.visible = false
	ui.add_child(foot_prompt)
	help = _overlay(HELP_TEXT, UIStyle.WHITE)
	briefing = _overlay("", Color(1, 0.85, 0.5))
	sess.say("F1 for controls. [J] to see the job board.")
	return self


func _overlay(text: String, col: Color) -> Label:
	var l := UIStyle.label(text, 16, col, UIStyle.mono())
	l.add_theme_stylebox_override("normal", UIStyle.panel_box(Color(0, 0, 0, 0.82)))
	l.set_anchors_preset(Control.PRESET_CENTER)
	l.grow_horizontal = Control.GROW_DIRECTION_BOTH
	l.grow_vertical = Control.GROW_DIRECTION_BOTH
	l.visible = false
	ui.add_child(l)
	return l


## Cockpit view: a dark glareshield along the bottom and a waterline marker
## showing where the nose points (the 3D airframe is hidden in this view).
func _build_glareshield() -> Control:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dash := ColorRect.new()
	dash.color = Color(0.08, 0.08, 0.09)
	dash.anchor_left = 0
	dash.anchor_right = 1
	dash.anchor_top = 0.81
	dash.anchor_bottom = 1
	dash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(dash)
	var mark := Line2D.new()
	mark.width = 3
	mark.default_color = Color(1, 0.8, 0.2)
	mark.points = PackedVector2Array([Vector2(-80, 0), Vector2(-33, 0), Vector2(-17, 20), Vector2(0, 0), Vector2(17, 20),
		Vector2(33, 0), Vector2(80, 0)])
	root.add_child(mark)
	root.resized.connect(func(): mark.position = root.size / 2)
	root.visible = false
	return root


# ------------------------------------------------------------ scene
func _build_player() -> void:
	if player != null:
		player.queue_free()
	var r := Models.build_aircraft(s.spec.visual, s.fm.mass.gear_height_ft * 0.3048, quality)
	player = r[0]
	props = r[1]
	ac_lights = r[2]
	dust = WorldScene.make_dust()
	dust.position = Vector3(0, -s.fm.mass.gear_height_ft * 0.3048, 1.5)
	player.add_child(dust)
	add_child(player)
	_player_key = s.spec.key


func _sync_beacons() -> void:
	var want := []
	for j in s.active_jobs:
		var key := [j.dest, j.drop_point]
		if not want.has(key):
			want.append(key)
	want.sort_custom(func(a, b): return str(a) < str(b))
	if want == beacons.map(func(b): return b[0]):
		return
	for b in beacons:
		for n in b[1]:
			n.queue_free()
	beacons.clear()
	for key in want:
		var nodes := []
		if key[1] != null:  # rendezvous at sea: one tall blue marker
			var b := Models.build_beacon(400, 10, Color(0.3, 0.6, 1.0, 0.35))
			b.position = MeshBuilder.to_godot([key[1][0], key[1][1], 0.0])
			add_child(b)
			nodes.append(b)
		else:
			var af := World.airfield(key[0])
			for end in [0, 1]:
				var t: Array = af.threshold(end)
				var b := Models.build_beacon()
				b.position = MeshBuilder.to_godot([t[0], t[1], s.world.airfield_elev(af)])
				add_child(b)
				nodes.append(b)
		beacons.append([key, nodes])


# ------------------------------------------------------------ input
func _active_menu() -> GameMenu:
	for m in menus.values():
		if m.visible:
			return m
	return null


func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed:
		var k: int = ev.physical_keycode if ev.physical_keycode else ev.keycode
		var m := _active_menu()
		if m != null:
			if k == KEY_ESCAPE:
				m.close()
			elif MENU_KEYS.has(k):
				m.key(MENU_KEYS[k])
			elif k in [KEY_J, KEY_L, KEY_H]:
				_toggle_menu(OS.get_keycode_string(k).to_lower())
			get_viewport().set_input_as_handled()
			return
		if ev.echo:
			return
		if k == KEY_TAB:
			_toggle_on_foot()
			get_viewport().set_input_as_handled()
			return
		if on_foot:
			if gun != null:
				var gk := OS.get_keycode_string(k).to_lower()
				if gk in ["1", "2", "3", "4", "h", "r"] and gun.key(gk):
					get_viewport().set_input_as_handled()
					return
			match k:
				KEY_E:
					walker.use()
				KEY_F:
					walker.toggle_torch()
				KEY_ESCAPE:
					if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
						Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
					else:
						s.save()
						get_tree().quit()
				KEY_M:
					hud.minimap.toggle()
				KEY_F1:
					help.visible = not help.visible
				KEY_F2:
					scene.set_hour(scene.hour + 3.0)
			get_viewport().set_input_as_handled()
			return
		if PRESS_KEYS.has(k):
			_pressed[PRESS_KEYS[k]] = true
		elif k == KEY_O and ev.shift_pressed:
			var r: Array = s.command(Roles.PILOT, "call_boat", {"brief": true})  # the codeword burst
			if not r[0]:
				s.say(r[1])
		elif CREW_KEYS.has(k):
			var r: Array = s.command(Roles.PILOT, CREW_KEYS[k], {})
			if not r[0]:
				s.say(r[1])
		elif k == KEY_7:
			# cycle the Mode A code: VFR, then the three emergency codes
			var codes := ["1200", "7700", "7600", "7500"]
			var r: Array = s.command(Roles.PILOT, "squawk", {"code": codes[(codes.find(s.squawk_code) + 1) % codes.size()]})
			if not r[0]:
				s.say(r[1])
		elif k in [KEY_J, KEY_L, KEY_H]:
			_toggle_menu(OS.get_keycode_string(k).to_lower())
		elif k == KEY_ESCAPE:
			if help.visible:
				help.visible = false
			else:
				s.save()
				get_tree().quit()
		elif k == KEY_C:
			cam_mode = CAM_MODES[(CAM_MODES.find(cam_mode) + 1) % CAM_MODES.size()]
			_cam_pos = null
		elif k == KEY_M:
			hud.minimap.toggle()
		elif k == KEY_Y:
			mouse_yoke = not mouse_yoke
			s.say("Mouse yoke %s" % ("ON - mouse position is the stick" if mouse_yoke else "OFF"))
		elif k == KEY_P:
			paused = not paused
		elif k == KEY_F1:
			help.visible = not help.visible
		elif k == KEY_F2:
			scene.set_hour(scene.hour + 3.0)
			s.say("Time %02d:00" % int(scene.hour))
		elif k == KEY_F3:
			toggle_ai_pilot()


func _unhandled_key_input(_ev: InputEvent) -> void:
	pass


func _input(ev: InputEvent) -> void:
	# click to grab the mouse again while walking
	if on_foot and ev is InputEventMouseButton and ev.pressed and _active_menu() == null:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _menu_closed() -> void:
	if on_foot:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		walker.look_enabled = true


# ------------------------------------------------------------ on foot
func _toggle_on_foot() -> void:
	_sync_scene(0.0)  # the aircraft node may not have been placed yet this frame
	if on_foot:
		var st: FlightModel.FlightState = s.state
		var d := walker.global_position.distance_to(player.global_position)
		if d > 9.0:
			s.say("Walk back to the aircraft to climb in (%.0f m away)." % d)
			return
		on_foot = false
		if gun != null:
			gun.teardown()
			gun.queue_free()
			gun = null
		walker.queue_free()
		walker = null
		if aircraft_body != null:
			aircraft_body.queue_free()
			aircraft_body = null
		cam.current = true
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		foot_prompt.visible = false
		s.say("Back in the %s." % s.spec.name)
		return
	if not s.parked:
		s.say("Stop at an airfield first.")
		return
	var st: FlightModel.FlightState = s.state
	if ground_body == null:
		ground_body = Walker.ground_body(s.world)
		add_child(ground_body)
	# the parked aircraft is solid
	aircraft_body = StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	var v := s.spec.visual
	bs.size = Vector3(v.span_m * 0.9, 2.2, v.length_m * 0.8)
	cs.shape = bs
	aircraft_body.add_child(cs)
	player.add_child(aircraft_body)
	walker = Walker.new().setup(s.world)
	add_child(walker)
	walker.used.connect(_on_use)
	# out of the left door, a couple of metres clear of the wing root
	var h := deg_to_rad(st.heading)
	var lx := -cos(h)
	var ly := sin(h)
	walker.place(st.x + lx * (v.span_m * 0.5 + 1.2), st.y + ly * (v.span_m * 0.5 + 1.2), st.heading)
	walker.cam.current = true
	on_foot = true
	if s.foot != null:
		gun = Gunplay.new().setup(s, walker, squads, ui)
		add_child(gun)
	for m in menus.values():
		m.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	s.say("On foot. TAB to climb back in, E to use things, F for the torch%s." % (", 1-4 for a gun" if s.foot != null else ""))


func _on_use(action: String, area: Area3D) -> void:
	match action:
		"jobs", "load", "hangar":
			var field: String = area.get_meta("field", s.location)
			if field != s.location:
				s.say("That's %s's %s - your aircraft is at %s." % [World.airfield(field).name, area.get_meta("label"), World.airfield(s.location).name])
				return
			_open({"jobs": "j", "load": "l", "hangar": "h"}[action])
		"hq_org":
			_open("hq")
		"hq_rival":
			_open("intel")
		"hq_law":
			s.say("Task Force HQ: restricted. (Play the task force from the lobby, or --police.)")


func _open(key: String) -> void:
	for other in menus.values():
		other.visible = false
	menus[key].open()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if walker != null:
		walker.look_enabled = false


func _toggle_menu(k: String) -> void:
	var m: GameMenu = menus[k]
	if m.visible:
		m.close()
		return
	if not s.parked:
		s.say("Come to a full stop at an airfield first.")
		return
	for other in menus.values():
		other.visible = false
	m.open()


func _gather_input() -> ControlMapper.InputFrame:
	var inp := ControlMapper.InputFrame.new()
	inp.pressed = _pressed
	_pressed = {}
	var menu_open := _active_menu() != null
	if not menu_open:
		for action in HELD_KEYS:
			for key in HELD_KEYS[action]:
				if Input.is_physical_key_pressed(key):
					inp.held[action] = true
					break
	else:
		inp.pressed.erase("confirm")
	if mouse_yoke and not menu_open:
		var vp := get_viewport()
		var m := vp.get_mouse_position() / vp.get_visible_rect().size * 2.0 - Vector2.ONE
		var dz := func(v: float) -> float: return 0.0 if absf(v) < 0.04 else v
		inp.stick = [clampf(dz.call(m.x) * 1.3, -1, 1), clampf(dz.call(m.y) * 1.3, -1, 1)]
	if not menu_open:
		_poll_stick(inp)
	return inp


## First joystick/gamepad, if any. Keyboard still works.
func _poll_stick(inp: ControlMapper.InputFrame) -> void:
	var pads := Input.get_connected_joypads()
	if pads.is_empty():
		return
	var dev: int = pads[0]
	var dz := func(v: float) -> float: return 0.0 if absf(v) < 0.06 else v
	# stick forward reads negative on Godot's Y axis; our stick +1 = pull back
	inp.stick = [dz.call(Input.get_joy_axis(dev, JOY_AXIS_LEFT_X)), dz.call(Input.get_joy_axis(dev, JOY_AXIS_LEFT_Y))]
	inp.rudder_axis = dz.call(Input.get_joy_axis(dev, JOY_AXIS_RIGHT_X))
	if Input.get_joy_axis(dev, JOY_AXIS_TRIGGER_RIGHT) > 0.3:
		inp.held["throttle_up"] = true
	if Input.get_joy_axis(dev, JOY_AXIS_TRIGGER_LEFT) > 0.3:
		inp.held["throttle_down"] = true


# ------------------------------------------------------------ loop
func _process(delta: float) -> void:
	var dt := minf(delta, 0.1)
	_frame += 1
	var camp = s.campaign
	if camp != null and camp.show_briefing:
		var ch: Campaign.Chapter = camp.chapter
		briefing.text = "CHAPTER %d  -  %d  -  %s\n\n%s\n\n%s\n\nPress ENTER" % [ch.num, ch.year, ch.title, ch.briefing,
			"\n".join(camp.objective_lines())]
		briefing.visible = true
		if _pressed.has("confirm"):
			camp.show_briefing = false
			briefing.visible = false
		_pressed.clear()
	elif not paused:
		if _player_key != s.aircraft_key:
			_build_player()
		if server != null:
			server.pump(s)
		_pilot_seat()
		var inp := _gather_input() if not on_foot else _foot_input()
		var remote: bool = s.seats.human(Roles.PILOT) and s.seats.seats[Roles.PILOT].token != ""
		var bc = bot.step(dt) if bot != null and not on_foot else (s.remote_controls() if remote else null)
		s.update(dt, inp, bc)
		nerves.update(s, dt)
		if server != null:
			server.publish(s)
	if _weather_rev != s.weather_rev:
		_weather_rev = s.weather_rev
		scene.set_weather(s.weather)
	_sync_scene(dt)
	hud.pulse = nerves.bpm if nerves.stress > 0.3 else 0.0
	hud.cam_mode = cam_mode
	hud.mouse_yoke = mouse_yoke
	var m := _active_menu()
	hud.visible = m == null and not on_foot
	if on_foot and s.foot != null and s.foot.down != "":
		_foot_down()
	if on_foot:
		_foot_hud()
	if m == null:
		hud.refresh()
	elif not s.parked:
		m.close()
	elif _frame % 10 == 0:
		m.refresh()


## Who flies: the host, a remote pilot, or (nobody in the seat) the AI.
func _pilot_seat() -> void:
	var who := s.seats.who(Roles.PILOT)
	if who == "ai" and bot == null:
		bot = AutoRunner.new(s)
		_auto_bot = true
		s.say("The AI has the controls. [F3] to take them back.")
	elif who != "ai" and _auto_bot:
		bot = null
		_auto_bot = false


## F3: hand the aircraft to the AI (so you can take another seat's job), or take it back.
func toggle_ai_pilot() -> void:
	if s.seats.who(Roles.PILOT) == "ai":
		s.seats.claim(Roles.PILOT, "host", "")
		s.say("You have the controls.")
	elif s.seats.human(Roles.PILOT) and s.seats.seats[Roles.PILOT].token == "":
		s.seats.release(Roles.PILOT)


## Down on foot: arrested (the bust takes over) or back at the aircraft.
func _foot_down() -> void:
	var how := s.foot.down
	s.foot.down = ""
	if how == "arrested":
		walker.global_position = player.global_position + Vector3(2, 0, 2)
		_toggle_on_foot()
		return
	var st: FlightModel.FlightState = s.state
	var h := deg_to_rad(st.heading)
	walker.place(st.x - cos(h) * (s.spec.visual.span_m * 0.5 + 1.2), st.y + sin(h) * (s.spec.visual.span_m * 0.5 + 1.2), st.heading)
	gun._refresh_viewmodel()


## While walking the aircraft just sits: parking brake on, nothing else.
func _foot_input() -> ControlMapper.InputFrame:
	var inp := ControlMapper.InputFrame.new()
	inp.held["brake"] = true
	inp.pressed = _pressed
	_pressed = {}
	return inp


func _foot_hud() -> void:
	var lines := []
	if walker.focus != null:
		lines.append("[E] " + str(walker.focus.get_meta("label")))
	if walker.global_position.distance_to(player.global_position) < 9.0:
		lines.append("[TAB] Climb into the %s" % s.spec.name)
	var ml := []
	for msg in s.messages:
		if s.time - msg[0] < 8:
			ml.append(msg[1])
	foot_prompt.text = "\n".join(lines + ml.slice(-2))
	foot_prompt.visible = not foot_prompt.text.is_empty() and _active_menu() == null


static func _basis(heading: float, pitch := 0.0, roll := 0.0) -> Basis:
	return Basis.from_euler(Vector3(deg_to_rad(pitch), -deg_to_rad(heading), -deg_to_rad(roll)), EULER_ORDER_YXZ)


func _sync_scene(dt: float) -> void:
	var st: FlightModel.FlightState = s.state
	if st == null:
		return
	player.position = MeshBuilder.to_godot([st.x, st.y, st.alt])
	player.basis = _basis(st.heading, st.pitch, st.roll)
	var thr: float = s.fm.controls.throttle if st.engine_running else 0.0
	var spin := TAU * 2400 / 60 * dt * maxf(0.15, thr)
	for p in props:
		p.rotate_object_local(Vector3.FORWARD, spin)
		p.get_node("disc").visible = st.engine_running and thr > 0.35
	# night: nav lights, strobe blink, landing light below 300 m AGL
	var night := scene.night > 0.3
	for n in ac_lights["nav"]:
		n.visible = night or not st.on_ground
	ac_lights["strobe"].visible = st.engine_running and int(s.time * 1.2) % 2 == 0 and fmod(s.time * 1.2, 1.0) < 0.12
	if ac_lights["landing"] != null:
		ac_lights["landing"].visible = night and st.agl < 300
	# dust on the take-off roll and landing rollout, off pavement
	var af: Airfield = s.world.airfield_at(st.x, st.y)
	dust.emitting = st.on_ground and st.gs_kts > 15 and (af == null or af.surface != "asphalt")
	_sync_beacons()
	_sync_pursuers(dt)
	_sync_squads(dt)
	_sync_maritime()
	var aer = s.police.sensors.site("AER")
	scene.show_aerostat(aer != null and aer.active)
	if not on_foot:
		_update_camera(st, dt)
	else:
		for c in player.get_children():
			if c is MeshInstance3D:
				c.visible = true
		glareshield.visible = false


func _sync_maritime() -> void:
	var mar: Maritime = s.maritime
	var live := {}
	for b in mar.boats:
		if b.state != "delivered":
			live[b.id] = b
	for bid in boat_nodes.keys():
		if not live.has(bid) and not str(bid).begins_with("ai:"):
			boat_nodes[bid][0].queue_free()
			boat_nodes.erase(bid)
	var blink := int(s.time * 3) % 2
	for bid in live:
		var b = live[bid]
		if not boat_nodes.has(bid):
			var r := Models.build_boat(b.kind)
			if quality.shaded:
				var w := WorldScene.make_wake()
				w.position = Vector3(0, 0.2, 6)
				r[0].add_child(w)
			add_child(r[0])
			boat_nodes[bid] = r
		var node: Node3D = boat_nodes[bid][0]
		var bob := sin(s.time * 2 + hash(bid) % 7) * 0.15
		node.position = MeshBuilder.to_godot([b.x, b.y, bob])
		node.basis = _basis(b.heading, minf(8.0, b.speed * 0.25))
		for ln in boat_nodes[bid][1]:
			ln.visible = blink == 1
		var wake = node.get_node_or_null("wake")
		if wake != null:
			wake.emitting = b.speed > 2.0
	var live_bales := {}
	for bl in mar.bales:
		if bl.state in ["falling", "floating", "landed"]:
			live_bales[bl.id] = bl
	for blid in bale_nodes.keys():
		if not live_bales.has(blid):
			bale_nodes[blid].queue_free()
			bale_nodes.erase(blid)
	for blid in live_bales:
		if not bale_nodes.has(blid):
			var n := Models.build_bale()
			add_child(n)
			bale_nodes[blid] = n
		var bl = live_bales[blid]
		bale_nodes[blid].position = MeshBuilder.to_godot([bl.x, bl.y, bl.z])
	# AI runs (police-vs-AI games, rival gangs)
	for a in s.smugglers:
		var key := "ai:%s" % a.id
		if not boat_nodes.has(key) and a.active():
			var v := Aircraft.Visual.new("low", 2, 11.0, 12.5, Color(0.07, 0.07, 0.07), Color(0.6, 0.1, 0.6))
			var r := Models.build_aircraft(v, 1.2, quality)
			add_child(r[0])
			boat_nodes[key] = [r[0], []]
		if boat_nodes.has(key):
			boat_nodes[key][0].position = MeshBuilder.to_godot([a.x, a.y, a.z])
			boat_nodes[key][0].basis = _basis(a.heading)
			boat_nodes[key][0].visible = a.active()


func _sync_pursuers(dt: float) -> void:
	var live := {}
	for u in s.police.units:
		live[u.get_instance_id()] = u
	for uid in pursuer_nodes.keys():
		if not live.has(uid):
			pursuer_nodes[uid][0].queue_free()
			pursuer_nodes.erase(uid)
	var blink := int(s.time * 4) % 2
	for uid in live:
		var u = live[uid]
		if not pursuer_nodes.has(uid):
			var r := Models.build_pursuer(u.kind, quality)
			add_child(r[0])
			pursuer_nodes[uid] = r
		var node: Node3D = pursuer_nodes[uid][0]
		node.position = MeshBuilder.to_godot([u.x, u.y, u.z])
		if u.state == "crashed":
			node.basis = _basis(u.heading, -25, 70)
			continue
		node.basis = _basis(u.heading, 0.0, u.bank)
		for sp in pursuer_nodes[uid][1]:
			if u.kind == "heli":
				sp.rotate_y(deg_to_rad(1500) * dt)
			else:
				sp.rotate_object_local(Vector3.FORWARD, deg_to_rad(2000) * dt)
		var lights: Array = pursuer_nodes[uid][2]
		for k in lights.size():
			lights[k].visible = k == blink
		var search = node.get_node_or_null("searchlight")
		if search != null:
			search.visible = scene.night > 0.3 and u.target_id != null


func _sync_squads(dt: float) -> void:
	if squads == null:
		return
	var g := s.ground
	squads.sync(g.squads.map(func(q): return q.dict()),
		g.fights.map(func(f): return {"x": f.x, "y": f.y, "a": f.a.id, "b": f.b.id}), cam.global_position, s.time, dt)


func _update_camera(st: FlightModel.FlightState, dt: float) -> void:
	var h := deg_to_rad(st.heading)
	var fwd := MeshBuilder.to_godot([sin(h), cos(h), 0.0])
	var L := s.spec.visual.length_m
	var cockpit := cam_mode == "cockpit"
	for c in player.get_children():
		if c is MeshInstance3D:
			c.visible = not cockpit
	glareshield.visible = cockpit
	var target := MeshBuilder.to_godot([st.x, st.y, st.alt])
	if cockpit:
		cam.global_transform = player.global_transform * Transform3D(Basis.from_euler(Vector3(deg_to_rad(-4), 0, 0)),
			MeshBuilder.to_godot([-0.3, L * 0.14, 0.25 + L * 0.085 * 0.75]))
		cam.fov = 80
		return
	if cam_mode == "tower":
		var af: Airfield = s.world.nearest_airfield(st.x, st.y)[0]
		var tower := MeshBuilder.to_godot([af.x + af.uy * (af.width / 2 + 55), af.y - af.ux * (af.width / 2 + 55),
			s.world.airfield_elev(af) + 24])
		cam.global_position = tower
		if tower.distance_to(target) > 1.0:
			cam.look_at(target, Vector3.UP)
		cam.fov = clampf(rad_to_deg(atan2(L * 3, (target - tower).length())) * 2, 8, 70)
		return
	cam.fov = 70
	var want := target - fwd * (L * 2.6 + 6) + Vector3(0, L * 0.55 + 1.5, 0)
	if _cam_pos == null or (_cam_pos - want).length() > 400:
		_cam_pos = want  # respawn / teleport: don't sweep across the map
	var k := 1 - exp(-dt * 4.0)
	_cam_pos = _cam_pos + (want - _cam_pos) * k
	var ground := s.world.ground(_cam_pos.x, -_cam_pos.z) + 1.5
	if _cam_pos.y < ground:
		_cam_pos.y = ground
	cam.global_position = _cam_pos
	cam.look_at(target + fwd * L * 1.5 + Vector3(0, 0.5, 0), Vector3.UP)
