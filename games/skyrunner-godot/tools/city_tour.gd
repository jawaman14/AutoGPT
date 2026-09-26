extends SceneTree
## A tour of Costa Brava with the new radar, radio, stash runs, markets and
## upgrade trees, for the demo video (Movie Maker, fixed 30 fps):
##
##   xvfb-run godot --rendering-method gl_compatibility --resolution 1280x720 \
##       --write-movie city.avi --fixed-fps 30 --script res://tools/city_tour.gd
##
## Shots: fly-overs of the city, the estuary and the farm plain; a crewed
## airdrop run on the HUD (the detector naming the radar that paints it, a 7700
## squawk); the task-force desk (radar sweeps and trails, the coverage overlay,
## DF bearings and their error ellipse after the crew talks, a jammer van); a
## stash run's truck on the co-pilot's map; the market and the upgrade trees;
## the port at night. CITY_TOUR_DEBUG=1 prints each beat for a dry run.

var shots: Array = []  ## [duration s, setup, [[t, callable], ...], camera path or null]
var shot := -1
var shot_t := 0.0
var beat := 0
var app  ## the current screen's root node
var caption: Label
var sessions := {}
var debug := OS.get_environment("CITY_TOUR_DEBUG") != ""
var path = null  ## [[pos, look], [pos, look]] for the current fly-over


func _initialize() -> void:
	World.use_map(MapCity.SEED)
	var layer := CanvasLayer.new()
	layer.layer = 100
	root.add_child(layer)
	var cap := PanelContainer.new()
	cap.theme = UIStyle.theme()
	cap.add_theme_stylebox_override("panel", UIStyle.box(Color(0.02, 0.03, 0.05, 0.86), 8, UIStyle.ACCENT, 1, Vector4(16, 8, 16, 9)))
	cap.anchor_left = 0.5
	cap.anchor_right = 0.5
	cap.anchor_top = 1.0
	cap.anchor_bottom = 1.0
	cap.grow_horizontal = Control.GROW_DIRECTION_BOTH
	cap.grow_vertical = Control.GROW_DIRECTION_BEGIN
	cap.offset_bottom = -58
	caption = UIStyle.label("", 19, UIStyle.WHITE)
	cap.add_child(caption)
	layer.add_child(cap)
	var C := MapCity.CITY_C
	shots = [
		[8.0, _aerial.bind(15.5, "Costa Brava, the new default map: the port city of San Telmo, the docks, the harbour"), [],
			[[Vector3(C.x + 2600, 420, -(C.y - 2600)), Vector3(C.x, 0, -C.y)], [Vector3(C.x - 1400, 260, -(C.y - 1500)), Vector3(C.x - 200, 10, -(C.y + 400))]]],
		[7.0, _aerial.bind(16.0, "The Rio Negro winds down to a mangrove estuary; the strip on the sand bar is Barra del Rio"), [],
			[[Vector3(-7600, 520, 8200), Vector3(-11500, 0, 7600)], [Vector3(-9600, 380, 10400), Vector3(-12600, 0, 8600)]]],
		[7.0, _aerial.bind(16.5, "The farm plain's patchwork, the jungle range behind it, the mesa strip on top"), [],
			[[Vector3(2500, 600, 6500), Vector3(-1000, 150, 1500)], [Vector3(-1500, 700, 6800), Vector3(-4000, 400, -3000)]]],
		[11.0, _flight, [[2.0, func(): _cmd(Roles.COPILOT, "chat", {"text": "two minutes out, boat's at the mark"})],
			[5.5, func(): _cmd(Roles.PILOT, "squawk", {"code": "7700"})],
			[8.0, func(): _cmd(Roles.COPILOT, "kick", {"count": 2})]], null],
		[13.0, _desk, [[1.5, func(): app._key("g")], [4.0, func(): app._key("g")], [6.0, func(): app._key("g"); app._key("g")],
			[7.0, func(): sessions.fly.command(Roles.COPILOT, "chat", {"text": "boat, boat, we're over the reef, bales in the water now"})],
			[10.0, func(): _jam()]], null],
		[9.0, _stash, [[3.0, func(): _advance(sessions.stash, 90.0)], [6.0, func(): _advance(sessions.stash, 90.0)]], null],
		[7.0, _market, [], null],
		[6.0, _upgrades, [[2.5, func(): _menu().key("down")], [3.2, func(): _menu().key("down")], [4.0, func(): _menu().key("down")]], null],
		[8.0, _aerial.bind(20.8, "San Telmo after dark: windows, street lamps, the club's neon"), [],
			[[Vector3(C.x + 1800, 300, -(C.y - 2200)), Vector3(C.x - 200, 10, -C.y)], [Vector3(C.x + 400, 180, -(C.y - 1300)), Vector3(C.x - 600, 10, -(C.y + 300))]]],
	]


# ------------------------------------------------------------ helpers
func _cap(text: String) -> void:
	caption.text = text


func _swap(node: Node) -> void:
	if app != null and is_instance_valid(app):
		app.queue_free()
	app = node
	root.add_child(node)
	root.move_child(node, 0)


func _cmd(role: String, name: String, args := {}) -> void:
	var r: Array = sessions.fly.command(role, name, args)
	if debug:
		print("    %s %s -> %s" % [role, name, r])


func _menu() -> GameMenu:
	for m in app.menus.values():
		if m.visible:
			return m
	return null


func _advance(s: Session, secs: float) -> void:
	for i in int(secs * 10):
		s.update(0.1)


func _jam() -> void:
	var s: Session = sessions.fly
	var fix = null
	for d in s.radio.df_log:
		if d.fix != null:
			fix = d.fix
	var at: Array = fix if fix != null else [s.state.x, s.state.y]
	s.command(Roles.CONTROLLER, "jam", {"x": at[0], "y": at[1]})
	_cap("J: the jammer van (a Signals upgrade) blacks out 5 km around the last fix for three minutes")


## The pilot's app with its own processing off: a camera we move ourselves.
func _aerial(hour: float, text: String) -> void:
	var s := _parked()
	var p := PilotApp.new()
	_swap(p)
	p.setup(s, "medium")
	p.scene.set_hour(hour)
	p.hud.visible = false
	_cap(text)


func _parked() -> Session:
	if not sessions.has("stash"):
		var s := Session.new({"seed": 3, "map_seed": MapCity.SEED, "location": "FRM", "features": Session.SANDBOX_FEATURES,
			"upgrades": {"runner": ["bug_sweep", "detector", "dark_paint"]}})
		s.update(1.0 / 30)
		s.police.frozen = true
		s.money = 14000
		sessions["stash"] = s
	return sessions["stash"]


func _fly_session() -> Session:
	# an airdrop run off the cove, crewed, with a detector that names the radar painting it
	var s := Session.new({"seed": 5, "map_seed": MapCity.SEED, "location": "COV", "mode": Roles.COOP,
		"upgrades": {"runner": ["scanner", "detector", "bearing_detector"], "law": ["heli_df", "intercept", "jammer"]}})
	s.update(1.0 / 30)
	s.set_copilot("human")
	var drop := Maritime.random_drop_point(s.world, s.rng, s.maritime.cove)
	var job := Jobs.airdrop_job(World.airfield("COV"), drop, s.rng, 4)
	s.boards["COV"].append(job)
	s.accept_job(job)
	s.loadout.pending.clear()
	for i in 30 * 25:
		s.update(1.0 / 30)
	s.transponder = true
	s.spawn_airborne(drop[0] - 3200, drop[1] + 800, 100, 420, 95)
	s.mapper.controls.throttle = 0.7
	s.command(Roles.PILOT, "autopilot", {"on": true})
	s.police.case("runner").suspicion = 40.0
	return s


func _flight() -> void:
	sessions["fly"] = _fly_session()
	var p := PilotApp.new()
	_swap(p)
	p.setup(sessions.fly, "medium")
	p.scene.set_hour(17.2)
	_cap("A crewed airdrop off the cove: the detector names the radar painting you and where it is")


func _desk() -> void:
	var st := StationApp.new()
	_swap(st)
	st.setup(LocalLink.new(sessions.fly, Roles.CONTROLLER), Roles.CONTROLLER, sessions.fly.world)
	_cap("The task-force desk: radar beams turning, trails, Mode C; G shades where each radar is blind")


func _stash() -> void:
	var s := _parked()
	var job = null
	for i in 20:
		job = Py.first(s.boards["FRM"], func(j): return j.stash != "")
		if job != null:
			break
		s.refresh_board("FRM")
	if job != null:
		job.dest = "FRM"
		job.stash = "barn"
		s.accept_job(job)
		s.loadout.pending.clear()
		s._arrive(s.airfield, s.state)
		for t in s.stash_net.trucks:
			t.stop_at = -1.0
	var st := StationApp.new()
	_swap(st)
	st.setup(LocalLink.new(s, Roles.COPILOT), Roles.COPILOT, s.world)
	st.map.set_process(true)
	_cap("A stash run: land at the farm strip, the crew trucks it to the barn - squares are stash houses, the dot is the truck")


func _market() -> void:
	var s := _parked()
	s.econ.events.append({"good": "cocaine", "mult": 1.35, "until": 1e9, "text": Economy.EVENTS[0][3]})
	s.econ.record_seizure("marijuana", "sea")
	var p := PilotApp.new()
	_swap(p)
	p.setup(s, "low")
	p._toggle_menu("j")
	p.menus["j"].key("right")
	_cap("Markets: rival turf, police presence, seizures, gluts, fuel and the news move every price")


func _upgrades() -> void:
	app._toggle_menu("j")
	app._toggle_menu("h")
	app.menus["h"].key("right")
	_cap("Upgrade trees: counter-surveillance, espionage, the airframe, weaponry - and the task force has its own")


# ------------------------------------------------------------ driver
func _process(dt: float) -> bool:
	shot_t += dt
	if shot < 0 or shot_t >= shots[shot][0]:
		shot += 1
		shot_t = 0.0
		beat = 0
		if shot >= shots.size():
			for s in sessions.values():
				s.dispose()
			return true
		path = shots[shot][3]
		shots[shot][1].call()
		if debug:
			print("shot %d: %s" % [shot, caption.text])
		return false
	if path != null and app is PilotApp:
		var f := smoothstep(0.0, 1.0, shot_t / shots[shot][0])
		app.set_process(false)
		app.cam.global_position = path[0][0].lerp(path[1][0], f)
		app.cam.look_at(path[0][1].lerp(path[1][1], f), Vector3.UP)
		app.cam.fov = 62
	var beats: Array = shots[shot][2]
	while beat < beats.size() and shot_t >= beats[beat][0]:
		beats[beat][1].call()
		beat += 1
		if debug:
			print("  beat %.1f s" % shot_t)
	return false
