extends TestCase
## The fourth pass over the free lists: fire, smoke, blasts and splashes (Kenney
## Particle Pack, CC0) and where the seat lights them; debris on the physics
## engine (Jolt); the weather soaking the world; KayKit's street furniture; the
## pack you carry on foot; reading aloud.


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func after_each() -> void:
	World.use_map(0)
	Speech.enabled = false
	Speech.spoken.clear()


func test_the_sprites_are_there() -> void:
	for f in ["fire_01", "fire_02", "smoke_04", "spark_01", "circle_05", "dirt_02"]:
		check(ResourceLoader.exists(FX.TEX % f), f)
	check(FileAccess.file_exists("res://assets/fx/kenney_particles/LICENSE.txt"), "with the licence")


func test_lasting_fires_and_one_shots() -> void:
	var fx := FX.new()
	_tree().root.add_child(fx)
	fx.burn("wreck", Vector3(10, 0, 10))
	fx.smoke("stash", Vector3(0, 5, 0))
	check(fx.lasting.has("wreck") and fx.lasting.wreck.get_node("flames") is CPUParticles3D, "a fire with flames")
	check(fx.lasting.wreck.get_node("smoke") is CPUParticles3D and fx.lasting.wreck.get_node("glow") is OmniLight3D, "smoke and a glow")
	fx.sweep()  # both were named since the last sweep
	fx.burn("wreck", Vector3(10, 0, 10))
	fx.sweep()
	check(fx.lasting.has("wreck") and not fx.lasting.has("stash"), "what nobody names any more goes out")
	var b := fx.blast(Vector3(0, 1, 0))
	var sp := fx.splash(Vector3(5, 0, 5))
	var pf := fx.puff(Vector3(-5, 0, 0))
	check(b.get_child_count() >= 3 and sp.get_child_count() >= 2 and pf.one_shot, "blast, splash, puff")
	for i in 20:
		await _tree().process_frame
	fx.queue_free()


func test_debris_lands_on_the_ground() -> void:
	check_eq(ProjectSettings.get_setting("physics/3d/physics_engine"), "Jolt Physics", "the physics engine is Jolt")
	var fx := FX.new()
	_tree().root.add_child(fx)
	check_eq(fx.throw_debris(Vector3(0, 1, 0), 5), 0, "nothing to land on: no debris")
	var floor := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(200, 1, 200)
	cs.shape = bs
	floor.add_child(cs)
	floor.position = Vector3(0, -0.5, 0)
	_tree().root.add_child(floor)
	for i in 2:
		await _tree().physics_frame
	check_eq(fx.throw_debris(Vector3(0, 1, 0), 5), 5, "five chunks")
	for i in 240:
		await _tree().physics_frame
	var ys: Array = fx.debris.filter(func(b): return is_instance_valid(b)).map(func(b): return b.global_position.y)
	check(ys.size() == 5 and ys.all(func(y): return y > -0.2 and y < 1.0), "they come down and lie on it: %s" % [ys])
	for i in 60:
		fx.throw_debris(Vector3(0, 1, 0), 1)
	check(fx.debris.filter(func(b): return is_instance_valid(b) and not b.is_queued_for_deletion()).size() <= FX.MAX_DEBRIS, "capped")
	fx.queue_free()
	floor.queue_free()


func test_the_seat_lights_fires_where_things_burn() -> void:
	var s := Session.new({"seed": 3, "map_seed": MapCity.SEED, "location": "HAR", "features": Session.SANDBOX_FEATURES})
	var app := PilotApp.new()
	_tree().root.add_child(app)
	app.setup(s, "low")
	s.police.frozen = true
	s.police.units.append(PoliceSystem.Pursuer.new("heli", s.state.x + 400.0, s.state.y, 0, 0.0, [0, 0], {"id": "Hawk-3"}))
	s.police.units.back().state = "crashed"
	var st: Dictionary = s.stash_net.stashes[0]
	st.burned = true
	app._sync_pursuers(0.1)
	app._sync_effects(0.1)
	check(app.effects.lasting.keys().any(func(k): return k.begins_with("wreck-")), "the crashed helicopter burns")
	check(app.effects.lasting.has("stash-%s" % st.id) or Vector2(st.x, st.y).distance_to(Vector2(s.state.x, s.state.y)) > 6000.0,
		"a burned stash house smokes (when it's in sight)")
	# a bale into the sea: a splash
	var bl = s.maritime.drop_bale(0, 0.0, -20000.0, 60.0, 0, 0, -20, 60.0)
	app._sync_maritime()
	var before := app.effects.get_children().filter(func(n): return n.name.begins_with("splash")).size()
	bl.state = "floating"
	app._sync_maritime()
	check(app.effects.get_children().filter(func(n): return n.name.begins_with("splash")).size() > before, "a splash when it hits the water")
	app.free()
	s.dispose()


func test_the_storm_soaks_the_world_and_it_dries() -> void:
	var s := Session.new({"seed": 1, "map_seed": MapCity.SEED, "location": "HAR"})
	var scene := WorldScene.new()
	_tree().root.add_child(scene)
	scene.setup(s.world, Quality.get_preset("low"))
	scene.set_weather({"sky": "storm", "wind_kt": 20, "wind_dir": 90})
	var wfx: WeatherFX = scene.fx
	wfx.set_wet(0.0)
	for i in 30:
		wfx._process(5.0)
	check(wfx.wet > 0.9, "soaked after a few minutes of storm (%.2f)" % wfx.wet)
	check(CityRender._road_mat == null or CityRender._road_mat.roughness < 0.4, "the roads shine")
	scene.set_weather({"sky": "clear"})
	for i in 60:
		wfx._process(5.0)
	check(wfx.wet < 0.75 and wfx.wet > 0.4, "drying slowly (%.2f after 5 min)" % wfx.wet)
	scene.queue_free()
	s.dispose()


func test_kaykit_street_furniture() -> void:
	var s := Session.new({"seed": 1, "map_seed": MapCity.SEED, "location": "HAR"})
	var city := CityRender.build(s.world, Quality.get_preset("low"))
	var lamps := city.get_node("lamps")
	var poles: MultiMeshInstance3D = lamps.get_node("poles")
	check(poles.multimesh.instance_count > 100, "a lamp post every 45 m in town (%d)" % poles.multimesh.instance_count)
	check_eq(lamps.get_node("heads").multimesh.instance_count, poles.multimesh.instance_count, "each with its head")
	var h: float = CityRender.KIT_SCALE.streetlight * poles.multimesh.mesh.get_aabb().size.y  # (headless keeps no instance transforms)
	check_near(h, 7.2, 0.3, "a 7 m lamp post")
	var props := city.get_node("street-props")
	for part in ["trafficlight_A", "firehydrant", "bench", "dumpster", "trash_A"]:
		check(props.has_node(part), part)
	city.free()
	s.dispose()


func _foot() -> Session:
	var s := Session.new({"seed": 3, "map_seed": MapCity.SEED, "location": "HAR", "features": Session.SANDBOX_FEATURES, "ground_war": true})
	s.police.frozen = true
	s.arsenals.org.stock.merge({"pistol": 4, "rifle": 4, "mg": 2, "rpg": 2}, true)
	s.arsenals.org.ammo = 2000
	s.foot.enter(0, 0)
	return s


func test_the_pack() -> void:
	var s := _foot()
	var f := s.foot
	check_eq(f.draw("rifle"), "", "a rifle")
	check_eq(f.draw("pistol"), "", "then a pistol")
	check_eq(int(f.pack.get("rifle", 0)), 1, "the rifle's in the pack, not back on the rack")
	check(int(f.pack.get("ammo", 0)) > 0, "with its rounds")
	check_near(f.weight(), FootCombat.KG.pistol + FootCombat.KG.rifle + FootCombat.KG.ammo * (f.mag + f.reserve + int(f.pack.ammo)), 1e-6, "weighed")
	check_eq(f.speed_factor(), 1.0, "light: full speed")
	check_eq(f.pack_add("mg"), "", "a machine gun too")
	check(f.speed_factor() < 1.0, "heavy: slower (%.2f)" % f.speed_factor())
	check(f.pack_add("rpg") != "", "no room for an RPG as well")
	check(f.draw("rpg").begins_with("Too heavy"), "nor to draw one off the rack")
	check_eq(f.pack_drop("mg"), "", "leave the machine gun")
	check_eq(f.draw("rpg"), "", "now the RPG")
	var m0 := s.money
	check_eq(f.pack_add("medkit"), "", "a medkit")
	check_eq(s.money, m0 - FootCombat.MEDKIT_COST, "bought")
	f.hp = 30.0
	check_eq(f.use_medkit(), "", "used")
	check_near(f.hp, 30.0 + FootCombat.MEDKIT_HP, 1e-6, "patched up")
	var r0: int = s.arsenals.org.stock.rifle
	var a0: int = s.arsenals.org.ammo
	var carried := int(f.pack.get("ammo", 0)) + f.mag + f.reserve
	f.pack_add("medkit")
	f.leave()
	check_eq(s.arsenals.org.stock.rifle, r0 + 1, "climbing in: the guns go back on the rack")
	check_eq(s.arsenals.org.ammo, a0 + carried, "and the rounds")
	check_eq(f.pack, {"medkit": 1}, "the medkit stays with you")
	s.dispose()


func test_arrested_the_pack_is_evidence() -> void:
	var s := _foot()
	var f := s.foot
	f.draw("rifle")
	f.pack_add("pistol")
	var l0: int = s.arsenals.law.stock.rifle + s.arsenals.law.stock.pistol
	f._down("arrested")
	check_eq(s.arsenals.law.stock.rifle + s.arsenals.law.stock.pistol, l0 + 2, "the guns go to the task force")
	check(f.pack.is_empty() and f.tier == "", "and you have nothing")
	f.enter(0, 0)
	f.draw("pistol")
	f._down("hospital")
	check(f.pack.is_empty(), "in hospital: the pack's gone")
	s.dispose()


func test_the_pack_panel() -> void:
	var s := _foot()
	var m := PackMenu.new()
	m.foot = s.foot
	_tree().root.add_child(m)
	check_eq(m.rows.get_child_count(), 6, "a row per thing you can carry")
	m._act(s.foot.pack_add("pistol"))
	m.refresh()
	check(m.weight_bar.value > 0.0, "the weight shows")
	m.queue_free()
	s.dispose()


func test_read_aloud() -> void:
	var said := []
	var real = Speech.speaker
	Speech.speaker = func(text: String, _i: bool) -> void: said.append(text)
	Speech.say("not while it's off")
	check(said.is_empty(), "off: silent")
	Speech.enabled = true
	Speech.say("[b]Tower[/b], go ahead")
	check_eq(said.back(), "Tower, go ahead", "on: said, without the markup")
	Speech.line("Sal Moretti", "You look tired, kid.", ["Take it", "Leave it"])
	check_eq(said.back(), "Sal Moretti: You look tired, kid.. 1, Take it. 2, Leave it", "the line and the numbered answers")
	# radio calls are read as they come, past the log's eighth line too (the squelch used to stop there)
	var s := Session.new({"seed": 1, "location": "HAR"})
	var snd := Soundscape.new()
	var n0 := said.size()
	snd._last_msg_set = true
	for i in 12:
		s.say("call %d" % i)
		snd._radio(s, false)
	check_eq(said.size() - n0, 12, "every call read (%d)" % (said.size() - n0))
	Speech.speaker = real
	snd.free()
	s.dispose()
