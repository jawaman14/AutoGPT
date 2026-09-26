extends TestCase
## The soundscape: every synthesized sound is well formed (loops that loop,
## shots that decay), the aircraft's sounds follow the flight model, the world's
## follow the police, the boats and the fights, and the UI clicks are Kenney's.


func after_each() -> void:
	World.use_map(0)


static func _rms(w: AudioStreamWAV, from := 0, to := -1) -> float:
	var n := w.data.size() / 2
	if to < 0:
		to = n
	var acc := 0.0
	for i in range(from, to):
		var v := float(w.data.decode_s16(i * 2)) / 32000.0
		acc += v * v
	return sqrt(acc / maxf(1.0, to - from))


func test_the_loops_are_well_formed() -> void:
	var e := Soundscape.engine_loop()
	check_eq(e.data.size() / 2, Soundscape.RATE, "one second of engine")
	check_eq(e.loop_mode, AudioStreamWAV.LOOP_FORWARD, "looped")
	check(_rms(e) > 0.05, "and audible")
	for w in [Soundscape.noise_loop("wind", 0.08), Soundscape.surf_loop(), Soundscape.horn_loop(), Soundscape.rotor_loop(),
			Soundscape.siren_loop(), Soundscape.outboard_loop()]:
		check(w.loop_mode == AudioStreamWAV.LOOP_FORWARD and w.loop_end == w.data.size() / 2 and _rms(w) > 0.02, "a clean loop")
	var m := Soundscape.music_loop()
	check_near(m.data.size() / 2.0 / Soundscape.RATE, 16.0 * 60.0 / Soundscape.MUSIC_BPM, 0.01, "four bars at 112 bpm")
	check(_rms(m) > 0.05, "and it plays something")
	check(Soundscape.engine_loop() == e, "made once, cached")


func test_shots_crack_and_decay() -> void:
	for tier in ["pistol", "rifle", "mg", "rpg"]:
		var w := Soundscape.shot(tier)
		var n := w.data.size() / 2
		check(_rms(w, 0, n / 10) > 4.0 * _rms(w, n * 9 / 10, n), "%s: loud, then gone" % tier)
	check(Soundscape.shot("rpg").data.size() > 3 * Soundscape.shot("pistol").data.size(), "the RPG booms longer")


func test_the_aircraft_sounds_follow_the_flight() -> void:
	var s := Session.new({"seed": 1, "location": "HAR"})
	var app := PilotApp.new()
	Engine.get_main_loop().root.add_child(app)
	app.setup(s, "low")
	check(app.sound != null, "a soundscape in the 3D seat")
	s.spawn_airborne(0.0, -6000.0, 600.0, 90.0, 110.0)
	for i in 30:
		s.update(1.0 / 30)
	app.sound._process(1.0 / 30)
	var st := s.state
	check(app.sound.engine.volume_db > -30.0, "the engine, in flight (%.1f dB)" % app.sound.engine.volume_db)
	check_near(app.sound.engine.pitch_scale, clampf(st.rpm / 1200.0, 0.3, 3.0), 0.01, "pitched by RPM (%.0f)" % st.rpm)
	check(app.sound.wind.volume_db > -30.0, "the wind at %.0f kt" % st.ias_kts)
	check_eq(app.sound.horn.volume_db, -60.0, "no stall horn")
	st.stall_warning = true
	app.sound._process(1.0 / 30)
	check(app.sound.horn.volume_db > -10.0, "the stall horn")
	# a call on the radio: the squelch
	s.say("Tower, go ahead")
	app.sound._process(1.0 / 30)
	check(app.sound.radio.stream == Soundscape.squelch(), "a squelch")
	# F7
	check(app.sound.toggle_music(), "Radio Costa 88 on")
	check(not app.sound.toggle_music(), "and off")
	app.free()
	s.dispose()


func test_the_world_is_heard() -> void:
	var s := Session.new({"seed": 3, "map_seed": MapCity.SEED, "location": "HAR", "features": Session.SANDBOX_FEATURES, "ground_war": true})
	s.police.frozen = true
	s.ground._started = true
	for f in s.ground.commanders:
		s.ground.commanders[f].ai = false
	var app := PilotApp.new()
	Engine.get_main_loop().root.add_child(app)
	app.setup(s, "low")
	s.police.units.append(PoliceSystem.Pursuer.new("heli", -8000, -10000, 300, 0.0, [0, 0], {"id": "Hawk-2"}))
	var a = s.ground.recruit("org", "foot", MapCity.CITY_C, false)
	var b = s.ground.recruit("rival", "foot", MapCity.CITY_C + Vector2(40, 0), false)
	s.ground._open(a, b)
	var before := app.sound.get_child_count()
	for i in 10:
		app.sound._world_sounds(s)
	check(app.sound.world.has("rotor-Hawk-2"), "the police helicopter's rotor")
	check(app.sound.get_child_count() > before + 1, "and gunfire at the fight")
	s.police.units.clear()
	app.sound._world_sounds(s)
	check(not app.sound.world.has("rotor-Hawk-2"), "gone when it's gone")
	app.free()
	s.dispose()


func test_the_clicks_are_kenneys() -> void:
	for f in ["click1", "click3", "rollover2", "switch3", "switch7"]:
		check(ResourceLoader.exists("res://assets/audio/kenney_ui/%s.wav" % f), f)
	check(FileAccess.file_exists("res://assets/audio/kenney_ui/LICENSE.txt"), "with the licence")
