extends TestCase
## Front-end smoke tests (the Godot counterpart of tests/test_render.py): build
## every screen headless (Godot's dummy renderer still builds all the nodes,
## meshes and materials) and drive a few frames and keys through it. Real
## pixels are checked by `tools/screenshots.sh` under Xvfb.

func _tree() -> SceneTree:
	return Engine.get_main_loop()


func test_world_scene_builds_at_every_preset() -> void:
	var w := World.new()
	for q in ["low", "medium", "high"]:
		var ws := WorldScene.new().setup(w, Quality.get_preset(q))
		check(ws.get_node("terrain") != null, q + " terrain")
		var n := 0
		for mm in ws.get_node("trees").get_children():
			n += mm.multimesh.instance_count
		check(n > 1000, "%s trees %d" % [q, n])
		ws.set_hour(21.0)
		check(ws.night > 0.9, "night at 21:00")
		check(ws.field_lights[0].visible, "runway lights on at night")
		ws.set_hour(12.0)
		check(ws.night < 0.05 and not ws.field_lights[0].visible, "day")
		ws.free()


func test_pilot_app_flies_a_frame_and_opens_menus() -> void:
	var s := Session.new({"seed": 1, "location": "FRM"})
	var app := PilotApp.new()
	_tree().root.add_child(app)
	app.setup(s, "low")
	for i in 5:
		app._process(1.0 / 30)
	check(app.player != null and app.player.position.y > 0, "aircraft placed")
	for k in ["j", "l", "h"]:
		app._toggle_menu(k)
		check(app._active_menu() == app.menus[k], k + " menu open")
		for key in ["down", "up", "right", "left", "+", "-"]:
			app.menus[k].key(key)
		app._process(1.0 / 30)
		app.menus[k].close()
	# accept a job from the board through the menu, then place its cargo by hand
	app._toggle_menu("j")
	var jm: JobMenu = app.menus["j"]
	jm.list.select(1)
	jm.key("enter")
	check(not s.active_jobs.is_empty(), "job accepted from the menu")
	jm.close()
	app._toggle_menu("l")
	var lm: LoadMenu = app.menus["l"]
	var item: Loadout.Item = s.loadout.items.values()[0]
	var st: int = s.loadout.valid_stations(item)[-1]
	lm._picked(item.id, st)
	check_eq(s.loadout.assignment.get(item.id), st, "placed at the chosen station")
	lm._set_fuel(s.loadout.mass.fuel_capacity_lb() * 0.5)
	check_near(s.fm.fuel_lb(), s.loadout.mass.fuel_capacity_lb() * 0.5, 1.0, "fuel preset")
	lm.close()
	app.queue_free()
	app.free()
	s.dispose()


func test_station_screens_for_every_seat() -> void:
	var s := Session.new({"seed": 9, "location": "FRM", "mode": Roles.VERSUS, "features": Session.SANDBOX_FEATURES + ["hq"]})
	s.update(1.0 / 30)
	for role in [Roles.COPILOT, Roles.SPOTTER, Roles.BOAT, Roles.CONTROLLER, Roles.BOSS, Roles.CHIEF]:
		var st := StationApp.new()
		_tree().root.add_child(st)
		st.setup(LocalLink.new(s, role), role, s.world)
		for i in 3:
			st._process(1.0 / 30)
		check(st.title.text != "" and not st.title.text.begins_with("Connecting"), role + ": " + st.title.text)
		for key in ["down", "right", "left", "up"]:
			st._key(key)
		st.free()
	s.dispose()


func test_boss_and_chief_order_menus_issue_orders() -> void:
	for role in [Roles.BOSS, Roles.CHIEF]:
		var s := Session.new({"seed": 9, "location": "FRM", "mode": Roles.VERSUS, "features": Session.SANDBOX_FEATURES + ["hq"]})
		s.nights.runner_ai = null  # humans hold both HQ seats (what HostServer.pump does on join)
		s.nights.law_ai = null
		s.update(1.0 / 30)
		var st := StationApp.new()
		_tree().root.add_child(st)
		st.setup(LocalLink.new(s, role), role, s.world)
		st._process(1.0 / 30)
		var key := "route" if role == Roles.BOSS else "fund_heli"
		var i := st.order_rows.map(func(r): return r.key).find(key)
		st.list.select(i)
		st._key("right")  # route west -> north / heli 0 -> 1
		st._process(1.0 / 30)
		st._key("enter")
		check(st.status == "", role + ": " + st.status)
		var ss: HQ.Season = s.nights.season
		if role == Roles.BOSS:
			check_eq(ss.org.route, "north", "route changed through the menu")
		else:
			check_eq(ss.law.funded["heli"], 1, "heli funded through the menu")
		st.free()
		s.dispose()


func test_remote_seat_interpolates_snapshots() -> void:
	var s := Session.new({"seed": 4, "mode": Roles.VERSUS})
	var seat := RemoteSeat.new()
	_tree().root.add_child(seat)
	seat.setup(LocalLink.new(s, Roles.COPILOT), Roles.COPILOT, "low", s.world)
	for i in 3:
		seat._process(1.0 / 30)
	check(seat.nodes.size() >= 1, "own aircraft drawn")
	check("CO-PILOT" in seat.hud.text, seat.hud.text)
	var a := {"x": 0.0, "y": 0.0, "z": 0.0, "heading": 350.0}
	var b := {"x": 10.0, "y": 0.0, "z": 0.0, "heading": 10.0}
	seat.buf = [[0.0, {"seq": 1, "p": a}], [1e9, {"seq": 2, "p": b}]]
	var p = seat.pose(func(snap): return snap.p)
	check(p != null and p.x >= 0 and p.x < 1e-3, "interpolated between snapshots")
	check_near(RemoteSeat._lerp_angle(350, 10, 0.5), 360.0, 1e-9, "angles wrap the short way")
	seat.free()
	s.dispose()


func test_data_table_keyboard_skips_sections() -> void:
	var t := DataTable.new().setup([{"title": "A", "expand": true}, {"title": "B", "align": "right", "mono": true}])
	_tree().root.add_child(t)
	t.section("group one")
	t.add_row(["x", "1"])
	t.add_row(["y", "2"])
	t.section("group two")
	t.add_row(["z", "3"])
	t.select_near(0)
	check_eq(t.selected_row(), 1, "first selectable row")
	t.move(1)
	t.move(1)
	check_eq(t.selected_row(), 4, "skips the section heading")
	t.move(1)
	check_eq(t.selected_row(), 1, "wraps round, skipping the top heading")
	var hit := [-1]
	t.row_activated.connect(func(i): hit[0] = i)
	t.item_activated.emit()
	check_eq(hit[0], 1, "activation reports the row")
	t.free()


func test_hud_regions_never_overlap_at_any_size() -> void:
	var s := Session.new({"seed": 4})
	s.update(1.0 / 30)
	var hud := Hud.new()
	_tree().root.add_child(hud)
	hud.setup(s)
	for sz in [Vector2(1024, 768), Vector2(1280, 720), Vector2(1920, 1080), Vector2(2560, 1080)]:
		hud.set_anchors_preset(Control.PRESET_TOP_LEFT)
		hud.size = sz
		var names: Array = hud.zones.keys()
		for i in names.size():
			var a: Rect2 = hud.zones[names[i]].get_rect()
			check(a.position.x >= 0 and a.end.x <= sz.x + 0.5 and a.position.y >= 0 and a.end.y <= sz.y + 0.5,
				"%s on screen at %s: %s" % [names[i], sz, a])
			for j in range(i + 1, names.size()):
				var b: Rect2 = hud.zones[names[j]].get_rect()
				check(not a.intersects(b), "%s and %s overlap at %s" % [names[i], names[j], sz])
	hud.free()
	s.dispose()
