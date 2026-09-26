extends SceneTree
## A tour of the redesigned UI for the demo video (Movie Maker, fixed 30 fps):
##
##   xvfb-run godot --rendering-method gl_compatibility --resolution 1280x720 \
##       --write-movie ui.avi --fixed-fps 30 --script res://tools/ui_tour.gd
##
## Every screen is driven the way a player drives it (keys, key caps, clicks) at
## timed beats: the lobby, job board, load planner and hangar; a crewed airdrop
## on the HUD; the co-pilot's desk on the same flight; the boss's and the chief's
## HQ boards; the task-force desk; and the leave-seat confirm. UI_TOUR_DEBUG=1
## prints each beat and what changed, for a dry run without the render.

var shots: Array = []  ## [duration s, setup, [[t, callable], ...]]
var shot := -1
var shot_t := 0.0
var beat := 0
var app  ## the current screen's root node
var caption: Label
var cap_panel: PanelContainer
var sessions := {}  ## name -> Session, shared between shots
var debug := OS.get_environment("UI_TOUR_DEBUG") != ""


func _initialize() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 100
	root.add_child(layer)
	cap_panel = PanelContainer.new()
	cap_panel.theme = UIStyle.theme()
	cap_panel.add_theme_stylebox_override("panel", UIStyle.box(Color(0.02, 0.03, 0.05, 0.86), 8, UIStyle.ACCENT, 1, Vector4(16, 8, 16, 9)))
	cap_panel.anchor_left = 0.5
	cap_panel.anchor_right = 0.5
	cap_panel.anchor_top = 1.0
	cap_panel.anchor_bottom = 1.0
	cap_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	cap_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	cap_panel.offset_bottom = -58
	caption = UIStyle.label("", 19, UIStyle.WHITE)
	cap_panel.add_child(caption)
	layer.add_child(cap_panel)
	shots = [
		[5.5, _lobby, [[1.2, func(): app.players.grab_focus()], [2.0, func(): app.players.value = 6],
			[3.6, func(): app.go_btn.grab_focus()]]],
		[8.0, _jobs, [[1.2, _mkey.bind("down")], [2.0, _mkey.bind("down")], [2.8, _mkey.bind("down")], [3.8, _mkey.bind("up")],
			[4.8, _mkey.bind("up")], [5.8, _mkey.bind("enter")], [6.6, func(): app._toggle_menu("j")]]],
		[8.5, _load, [[1.2, _mkey.bind("right")], [2.2, _mkey.bind("down")], [3.0, _mkey.bind("right")], [4.2, func(): _menu()._route_fuel()],
			[5.6, _mkey.bind("+")], [6.6, _mkey.bind("-")]]],
		[5.5, _hangar, [[1.0, _mkey.bind("down")], [1.8, _mkey.bind("down")], [2.8, func(): _select_row("copilot")], [3.8, _mkey.bind("enter")]]],
		[12.0, _hud, [[1.5, func(): sessions.fly.command(Roles.COPILOT, "chat", {"text": "boat's on its way, two minutes"})],
			[4.0, func(): sessions.fly.command(Roles.COPILOT, "kick", {"count": 3})],
			[7.0, func(): sessions.fly.command(Roles.COPILOT, "chat", {"text": "two away, one to go"})]]],
		[13.0, _copilot, [[1.5, func(): app.hints.press("t")], [2.8, func(): app.hints.press("t")],
			[4.0, func(): app.chat.text = "Boat"], [4.4, func(): app.chat.text = "Boat in sight,"], [4.8, func(): app.chat.text = "Boat in sight, turning in"],
			[5.6, func(): app.chat.text_submitted.emit(app.chat.text)], [7.0, _click_strip.bind("VAL")],
			[8.6, func(): app._key("2")], [10.4, func(): app._key("3")], [12.0, func(): app._key("1")]]],
		[9.0, _boss, [[1.4, func(): _select_order("route")], [2.8, func(): app._key("right")], [4.2, func(): app._key("enter")],
			[5.6, func(): _select_order("lawyer")], [6.8, func(): app._key("enter")]]],
		[7.0, _chief, [[1.2, func(): _select_order("fund_heli")], [2.4, func(): app._key("right")], [3.6, func(): app._key("enter")],
			[5.0, func(): _select_order("aerostat")]]],
		[6.5, _desk, [[1.5, func(): app._key("i")], [3.2, func(): app._key("down")], [4.5, func(): app._key("down")]]],
		[5.0, _leave, [[1.2, func(): app._key("esc")], [3.6, func(): app.confirm.key("esc")]]],
	]


# ------------------------------------------------------------ helpers
func _cap(text: String) -> void:
	caption.text = text


func _swap(node: Node) -> void:
	if app != null and is_instance_valid(app):
		app.queue_free()
	app = node
	root.add_child(node)
	root.move_child(node, 0)  # the caption layer stays on top


func _menu() -> GameMenu:
	for m in app.menus.values():
		if m.visible:
			return m
	return null


func _mkey(k: String) -> void:
	var m := _menu()
	if m != null:
		m.key(k)


func _select_row(kind: String) -> void:
	var m: HangarMenu = _menu()
	for i in m.rows.size():
		if m.rows[i][0] == kind:
			m.list.select(i)
			m._detail()
			return


func _select_order(key: String) -> void:
	var i: int = app.order_rows.map(func(r): return r.key).find(key)
	if i >= 0:
		app.list.select(i)
		app.board._detail()


func _click_strip(code: String) -> void:
	var af := World.airfield(code)
	app._on_map_click(MOUSE_BUTTON_LEFT, Vector2(af.x + 250, af.y))


func _ground_session() -> Session:
	if not sessions.has("ground"):
		var s := Session.new({"seed": 1, "location": "FRM"})
		s.update(1.0 / 30)
		sessions["ground"] = s
	return sessions["ground"]


func _pilot_app(s: Session, graphics := "low") -> PilotApp:
	var p := PilotApp.new()
	_swap(p)
	p.setup(s, graphics)
	return p


func _station(s: Session, role: String) -> StationApp:
	var st := StationApp.new()
	_swap(st)
	st.setup(LocalLink.new(s, role), role, s.world)
	return st


# ------------------------------------------------------------ shots
func _lobby() -> void:
	var l := Lobby.new()
	_swap(l)
	_cap("The lobby: one theme everywhere, and every screen works from the keyboard")


func _jobs() -> void:
	var p := _pilot_app(_ground_session())
	p.scene.set_hour(10.5)
	p._toggle_menu("j")
	_cap("Job board: a real table - the landing roll is coloured against the strip length")


func _load() -> void:
	var s := _ground_session()
	s.loadout.pending.clear()
	s.fm.apply_loadout(s.loadout)
	if app is PilotApp:
		app._toggle_menu("l")
	_cap("Load planner: stations table, W&B tiles, fuel presets and the CG envelope")


func _hangar() -> void:
	app._toggle_menu("h")
	_cap("Hangar: aircraft, gear and crew in one table - hire the co-pilot")


func _flight_session() -> Session:
	# over the rendezvous: ferry tank pumping, four bales aboard, the boat called
	var s := Session.new({"seed": 5, "location": "HAR", "mode": Roles.COOP})
	s.update(1.0 / 30)
	s.set_copilot("human")
	s.money = 20000
	s.buy_gear("ferry_tank")
	for i in 30 * 20:
		s.update(1.0 / 30)
	s.fill_ferry(150)
	var drop := Maritime.random_drop_point(s.world, s.rng, s.maritime.cove)
	var job := Jobs.airdrop_job(World.airfield("HAR"), drop, s.rng, 5)
	s.boards["HAR"].append(job)
	s.accept_job(job)
	for i in 30 * 30:
		s.update(1.0 / 30)
	s.spawn_airborne(drop[0] - 1400, drop[1] + 200, 95, 150, 88)
	s.fm.fdm.set_property("propulsion/tank[0]/contents-lbs", 60)
	s.fm.fdm.set_property("propulsion/tank[1]/contents-lbs", 60)
	s.mapper.controls.throttle = 0.65
	s.command(Roles.PILOT, "autopilot", {"on": true})
	s.command(Roles.COPILOT, "pump", {"on": true})
	s.police.case("runner").suspicion = 55.0
	return s


func _hud() -> void:
	sessions["fly"] = _flight_session()
	var p := _pilot_app(sessions.fly, "medium")
	p.scene.set_hour(16.5)
	_cap("In flight: status chips, radio toasts, and the crew strip - what the co-pilot is doing")


func _copilot() -> void:
	_station(sessions.fly, Roles.COPILOT)
	_cap("The co-pilot's desk: live tiles, crew jobs, chat - click a strip to hire a spotter")


func _hq_session() -> Session:
	if not sessions.has("hq"):
		var s := Session.new({"seed": 9, "location": "FRM", "mode": Roles.VERSUS, "features": Session.SANDBOX_FEATURES + ["hq"]})
		s.nights.runner_ai = null
		s.nights.law_ai = null
		s.update(1.0 / 30)
		sessions["hq"] = s
	return sessions["hq"]


func _boss() -> void:
	_station(_hq_session(), Roles.BOSS)
	_cap("The boss: headline tiles, tonight's weather, routine and rival, then the orders")


func _chief() -> void:
	_station(_hq_session(), Roles.CHIEF)
	_cap("The chief: the same board for the task force - fund, patrol, wiretap, audit")


func _desk() -> void:
	var s := Session.new({"seed": 9, "mode": Roles.POLICE, "humans": {Roles.CONTROLLER: "me"}})
	for i in 30 * 90:
		s.update(1.0 / 30)
	s.police.launch("heli", "HAR")  # one already up, so the units table has a row to pick
	for i in 30 * 8:
		s.update(1.0 / 30)
	sessions["desk"] = s
	_station(s, Roles.CONTROLLER)
	_cap("The task-force desk: units in a table, key caps for every order")


func _leave() -> void:
	_station(sessions.fly, Roles.COPILOT)
	_cap("ESC asks before you leave a seat")


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
		shots[shot][1].call()
		if debug:
			print("shot %d: %s" % [shot, caption.text])
		return false
	var beats: Array = shots[shot][2]
	while beat < beats.size() and shot_t >= beats[beat][0]:
		beats[beat][1].call()
		beat += 1
		if debug:
			print("  beat %.1f s: %s" % [shot_t, _state()])
	return false


## A one-line summary of what the current screen shows, for the dry run.
func _state() -> String:
	if app is PilotApp:
		var m := _menu()
		var s: Session = app.s
		if m is JobMenu:
			return "jobs row %d, active %d" % [m.list.selected_row(), s.active_jobs.size()]
		if m is LoadMenu:
			return "load sel %d fuel %.0f" % [m.sel, s.fm.fuel_lb()]
		if m is HangarMenu:
			return "hangar row %d copilot %s" % [m.list.selected_row(), s.copilot]
		return "flying: kick %d pump %s msgs %s" % [s.kick_queue, s.pumping, s.messages.slice(-1)]
	if app is StationApp:
		var s: Session = app.link.sess
		if app.role in [Roles.BOSS, Roles.CHIEF]:
			var ss: HQ.Season = s.nights.season
			return "%s row %d route %s funded %s status '%s'" % [app.role, app.list.selected_row(), ss.org.route, ss.law.funded, app.status]
		if app.role == Roles.CONTROLLER:
			return "desk units %d sel %s" % [s.police.units.size() + s.police._launches.size(), app.sel_unit]
		return "copilot tab %d auto_kick %s spotters %s confirm %s last '%s'" % [app.tabs.current_tab, s.auto_kick,
			s.spotters.map(func(sp): return sp.code), app.confirm.visible, s.messages.back()[1] if not s.messages.is_empty() else ""]
	if app is Lobby:
		return "lobby players %d" % int(app.players.value)
	return ""
