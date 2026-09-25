extends TestCase
## The realism layer (docs/BALANCE.md 14-19): weather and moon, pattern-of-life
## analysis, the canary trap, rival tempers and endgame betrayal, the police's
## predictive stake-out, and the pilot's nerves.


func _season(seed := 5, rules := {}) -> HQ.Season:
	var r := PyRandom.new()
	r.seed(seed)
	return HQ.Season.new(r, rules)


func test_parity_rules_have_no_realism_stream() -> void:
	var ss := _season(1, HQ.PYTHON_RULES)
	check(ss.xrng == null, "Python rules: no extra random stream")
	check(ss.forecast.is_empty(), "no forecast")
	var p := ss.start_operation()
	check(not p.has("weather") and not p.has("pattern"), "plan unchanged")


func test_every_night_has_a_forecast_and_the_moon_turns() -> void:
	var ss := _season(3)
	check(ss.forecast.has("sky") and ss.forecast.has("wind_kt") and ss.forecast.has("moon"), "forecast %s" % ss.forecast)
	var moons := []
	for n in range(1, 11):
		moons.append(ss.moon(n))
	# ten nights is a third of a lunar month: the moon must visibly change
	check(absf(moons[0] - moons[9]) > 0.2 or absf(moons[0] - moons[5]) > 0.2, "moon changes %s" % [moons])
	var skies := {}
	for s in 60:
		var t := _season(100 + s)
		skies[t.forecast["sky"]] = true
	check(skies.size() == 3, "clear, cloud and storm all happen: %s" % [skies.keys()])


func test_storm_winches_the_aerostat_down() -> void:
	var ss := _season(4)
	ss.forecast = {"sky": "storm", "wind_kt": 28, "wind_dir": 90, "moon": 0.5}
	check(ss.law_cmd("aerostat") == null, "the chief can still order it")
	var p := ss.start_operation()
	if p["weather"]["sky"] == "storm":  # a quarter of forecasts are wrong
		check(not p["aerostat"], "balloon down in the storm")
		check(ss.law_log.back().begins_with("Aerostat winched down"), "the chief is told")
	else:
		check(p["aerostat"] == (int(p["weather"]["wind_kt"]) <= HQ.AEROSTAT_MAX_WIND), "only the wind decides then")


func _detect_rate(pattern: Dictionary, weather: Dictionary, n := 3000) -> float:
	var ss := _season(7)
	var rng := PyRandom.new()
	rng.seed(11)
	var hits := 0
	for i in n:
		var plan := {"route": "west", "runs": 1, "crews": 0, "decoys": 0, "funded": {"heli": 0, "interceptor": 0, "cutter": 0},
			"cutters": 0, "aerostat": false, "patrol": null, "encryption": false, "tip": false, "pattern": pattern}
		if not weather.is_empty():
			plan["weather"] = weather
		var runs := HQ.resolve_abstract(ss, plan, rng)
		if runs[0].detected:
			hits += 1
	return float(hits) / n


func test_a_routine_gets_you_seen() -> void:
	var ss := _season(8)
	ss.sightings = ["west", "west", "", "west"]
	var ex := ss.pattern_exposure()
	check_near(ex["west"], HQ.RULES["pattern_k"] * 3 / 4.0, 1e-9, "three of four sightings in the west")
	check_eq(ex["north"], 0.0, "never seen in the north")
	var base := _detect_rate({}, {})
	var seen := _detect_rate({"west": 0.3}, {})
	check(seen > base + 0.2, "expected on the route: %.2f vs %.2f" % [seen, base])


func test_dark_and_stormy_nights_hide_you() -> void:
	var clear_full := _detect_rate({}, {"sky": "clear", "moon": 1.0})
	var storm_new := _detect_rate({}, {"sky": "storm", "moon": 0.0})
	check(storm_new < clear_full * 0.65, "storm + new moon: %.2f vs %.2f" % [storm_new, clear_full])


func test_storms_crash_more_planes() -> void:
	var ss := _season(9)
	var rng := PyRandom.new()
	rng.seed(3)
	var crashes := {"clear": 0, "storm": 0}
	for sky in crashes:
		for i in 4000:
			var plan := {"route": "west", "runs": 1, "crews": 0, "decoys": 0, "funded": {"heli": 0, "interceptor": 0, "cutter": 0},
				"cutters": 0, "aerostat": false, "patrol": null, "encryption": false, "tip": false,
				"weather": {"sky": sky, "moon": 0.5}}
			if HQ.resolve_abstract(ss, plan, rng)[0].crashed:
				crashes[sky] += 1
	check(crashes["storm"] > crashes["clear"] * 1.8, "crashes %s" % crashes)


func test_canary_trap_exposes_the_dispatcher() -> void:
	var ss := _season(12)
	ss.org.dirty = 50000
	check(ss.runner_cmd("bribe", {"who": "dispatcher"}) == null, "bribe")
	check(ss.law_cmd("canary") != null, "needs a patrol first")
	ss.law_cmd("patrol", {"zone": "north"})
	check(ss.law_cmd("canary") == null, "canary set")
	var fake = ss.law.canary_zone
	check(fake != null and fake != "north", "the lie isn't the truth: %s" % fake)
	check_eq(ss.view("runner")["patrol_leak"], fake, "the dispatcher passes the lie on")
	# the organisation plans to fly exactly where the fake patrol is: the leak makes them swerve
	ss.runner_cmd("route", {"zone": fake})
	var ev0 := ss.law.evidence
	var plan := ss.start_operation()
	check_eq(plan["leak_patrol"], fake, "plan carries the fake")
	var rng := PyRandom.new()
	rng.seed(2)
	var runs := HQ.resolve_abstract(ss, plan, rng)
	var main = runs.filter(func(r): return r.kind == "main")[0]
	check(main.zone != fake, "they swerved (%s)" % main.zone)
	ss.finish_night(runs)
	check(not ss.org.bribes.has("dispatcher"), "the dispatcher is burned")
	check(ss.law.evidence >= ev0 + HQ.RULES["evidence_bribe"] - 3.0, "and it's evidence")


func test_canary_stays_quiet_without_a_leak() -> void:
	var ss := _season(13)
	ss.law_cmd("patrol", {"zone": "west"})
	ss.law_cmd("canary")
	var fake = ss.law.canary_zone
	ss.runner_cmd("route", {"zone": fake})
	var plan := ss.start_operation()
	check(plan["leak_patrol"] == null, "no dispatcher, nothing leaks")
	var rng := PyRandom.new()
	rng.seed(2)
	var rep := ss.finish_night(HQ.resolve_abstract(ss, plan, rng))
	check(rep.law_lines.has("The canary stayed quiet."), "no signal: %s" % [rep.law_lines])


func _betrayals(temper: String, night: int, n := 400) -> int:
	var count := 0
	for i in n:
		var ss := _season(1000 + i)
		ss.rival.temper = temper
		ss.night = night
		ss.rival.truce_nights = 2
		ss.start_operation()
		if ss.rival.betrayed:
			count += 1
	return count


func test_opportunists_defect_as_the_season_runs_out() -> void:
	var early := _betrayals("opportunist", 3)
	var late := _betrayals("opportunist", 9)
	check(late > early * 3, "backward induction: night 9 %d vs night 3 %d (of 400)" % [late, early])
	check_eq(_betrayals("grudger", 9), 0, "grudgers keep their word")
	check(_betrayals("tit_for_tat", 9) < 30, "tit-for-tat keeps it unless provoked")


func test_betrayal_sells_your_route() -> void:
	var ss := _season(21)
	ss.rival.temper = "opportunist"
	ss.night = 10
	ss.rival.truce_nights = 2
	var plan := {}
	for i in 50:
		ss = _season(21 + i)
		ss.rival.temper = "opportunist"
		ss.night = 10
		ss.rival.truce_nights = 2
		plan = ss.start_operation()
		if ss.rival.betrayed:
			break
	check(ss.rival.betrayed, "someone betrayed within 50 seasons")
	check(plan["tip"] and plan["tip_zone"] == ss.org.route, "they sold the route")
	check(ss.rival.revealed and ss.view("runner")["rival"]["reputation"].begins_with("opportunists"), "and now you know them")


func test_grudgers_never_forgive() -> void:
	var ss := _season(30)
	ss.rival.temper = "grudger"
	ss.org.dirty = 60000
	ss.runner_cmd("hit_rival")
	ss.rival.grudge = 0  # long after
	var err = ss.runner_cmd("truce")
	check(err != null and "never" in str(err), "no truce: %s" % err)
	check(ss.rival.revealed, "their nature is now known")


func _quarry_track(s: Session, dist := 2000.0) -> SensorNet.Signature:
	var q := World.airfield("QRY")
	var f := World.airfield("FRM")
	var d := Vector2(q.x - f.x, q.y - f.y).normalized()
	return SensorNet.Signature.new("runner", f.x + d.x * dist, f.y + d.y * dist, 200.0, 60.0, d.x * 60, d.y * 60)


func _launched_for(ps: PoliceSystem, kind: String, tid: String) -> int:
	return ps._launches.filter(func(l): return l[1] == kind and l[3] == tid).size()


func test_heavy_police_surge_every_helicopter_into_the_chase() -> void:
	var s := Session.new({"seed": 2, "location": "FRM", "features": ["contraband", "interceptors"]})
	var ps := s.police
	ps.stock = {"heli": 2, "interceptor": 2, "cutter": 0}
	var c := ps.case("runner")
	ps._ai_escalate(c, 1, _quarry_track(s))
	check_eq(_launched_for(ps, "heli", "runner"), 2, "both helicopters are sent after the track")
	check_eq(ps._launches.filter(func(l): return l.size() > 5).size(), 1, "the spare one flies as a flanker")
	check_eq(ps.stock["heli"], 0, "nothing left in the hangar")
	check(ps.law_events.any(func(e): return "Surge" in e), "the desk hears about it")
	s.dispose()


func test_standard_police_launch_as_before() -> void:
	var s := Session.new({"seed": 2, "location": "FRM", "features": ["contraband", "interceptors"]})
	var ps := s.police
	ps.stock = {"heli": 1, "interceptor": 1, "cutter": 0}
	var c := ps.case("runner")
	var sig := _quarry_track(s)
	ps._ai_escalate(c, 1, sig)
	ps._ai_escalate(c, 2, sig)
	check_eq(_launched_for(ps, "heli", "runner"), 1, "one helicopter")
	check_eq(_launched_for(ps, "interceptor", "runner"), 1, "one interceptor")
	check(not ps.law_events.any(func(e): return "Surge" in e), "no spare, no surge")
	s.dispose()


func test_an_idle_helicopter_joins_the_pursuit() -> void:
	var s := Session.new({"seed": 2, "location": "FRM", "features": ["contraband", "interceptors"]})
	var ps := s.police
	ps.stock = {"heli": 2, "interceptor": 0, "cutter": 0}
	var sig := _quarry_track(s)
	var u := ps._spawn_now("heli", ps.police_bases()[0].code, null, [sig.x, sig.y])  # on patrol
	ps.stock["heli"] -= 1
	var c := ps.case("runner")
	ps._ai_escalate(c, 1, sig)
	check_eq(u.target_id, "runner", "the patrol helicopter is re-tasked")
	check_eq(u.state, "pursuit", "and chases, as the primary")
	check_eq(ps._launches.filter(func(l): return l.size() > 5).size(), 1, "the one left in the hangar flies out to cut them off")
	s.dispose()


func _bust_rate(n_units: int, surge: bool) -> float:
	var s := Session.new({"seed": 2, "location": "FRM", "features": ["contraband"]})
	var ps := s.police
	ps.surge = surge
	var sig := _quarry_track(s)
	sig.z = s.world.ground(sig.x, sig.y) + 300.0
	for i in n_units:
		var u := ps._spawn_now("heli", ps.police_bases()[0].code, "runner", null)
		u.x = sig.x + 100.0 * (i + 1)
		u.y = sig.y
		u.z = sig.z
	var c := ps.case("runner")
	c.wanted = 1
	ps.tick(0.1, 100.0, [PoliceSystem.Target.new(sig, true)])
	var m := c.bust_meter
	s.dispose()
	return m


func test_a_flanker_aims_ahead_of_the_runner() -> void:
	var s := Session.new({"seed": 2, "location": "FRM", "features": ["contraband"]})
	var sig := _quarry_track(s)
	sig.x = 0.0
	sig.y = 0.0
	sig.vx = 60.0
	sig.vy = 0.0
	var headings := {}
	for flank in [false, true]:
		# 6 km south of a runner heading east
		var u := PoliceSystem.Pursuer.new("heli", 0.0, -6000.0, 400.0, 0.0, [0.0, -6000.0], {"target_id": "runner", "flank": flank, "speed": 40.0})
		for i in 12:
			u.update(0.5, sig, s.world)
		headings[flank] = u.heading
	check(headings[true] > headings[false] + 5, "the flanker turns further east to cut them off (%.1f vs %.1f)" % [headings[true], headings[false]])
	s.dispose()


func test_two_aircraft_on_your_tail_box_you_in() -> void:
	var one := _bust_rate(1, true)
	var two := _bust_rate(2, true)
	check(one > 0.0, "one close unit starts the bust (%.2f)" % one)
	check_near(two / one, 1.5, 1e-6, "two close units bust 1.5x faster")
	check_near(_bust_rate(2, false), one, 1e-9, "surge off: Python's rule, any number of units counts once")


func test_course_made_good_beats_the_heading() -> void:
	var s := Session.new({"seed": 2, "location": "FRM", "features": ["contraband"]})
	var ps := s.police
	var q := World.airfield("QRY")
	var f := World.airfield("FRM")
	check(q.kind in ["bush", "shady"], "QRY is off the books")
	var d := Vector2(q.x - f.x, q.y - f.y).normalized()
	check_eq(ps.predict_destination(_quarry_track(s)).code, "QRY", "predicted destination")
	# mid dog-leg the heading points east, but the course made good since first contact is the quarry
	var mid := SensorNet.Signature.new("runner", f.x + d.x * 5000, f.y + d.y * 5000, 60.0, 60.0, 60.0, 0.0)
	check(ps.predict_destination(mid) == null or ps.predict_destination(mid).code != "QRY", "heading alone misleads")
	check_eq(ps.predict_destination(mid, [f.x, f.y]).code, "QRY", "course made good finds the quarry")
	s.dispose()


func test_weather_reaches_jsbsim_and_the_police() -> void:
	var s := Session.new({"seed": 1, "location": "HAR", "weather": {"sky": "storm", "wind_kt": 28, "wind_dir": 270, "moon": 0.1}})
	check(s.police.visibility < 0.6, "storm and new moon: crews see %.2f as far" % s.police.visibility)
	var east: float = s.fm.fdm.get_property("atmosphere/wind-east-fps")
	check(east > 40.0, "a westerly blows east at %.0f fps" % east)
	check_eq(int(s.fm.fdm.get_property("atmosphere/turb-type")), 4, "Dryden turbulence")
	s.spawn_at("VAL")  # a new spawn keeps the weather
	check(float(s.fm.fdm.get_property("atmosphere/wind-east-fps")) > 40.0, "wind survives a respawn")
	var calm := Session.new({"seed": 1, "location": "HAR"})
	check_eq(calm.police.visibility, 1.0, "no weather, no change (the tactical sims fly this)")
	s.dispose()
	calm.dispose()


func test_nerves_follow_the_danger() -> void:
	var s := Session.new({"seed": 1, "location": "HAR"})
	var af := World.airfield("HAR")
	s.spawn_airborne(af.x, af.y - 3000, 0.0, 400.0, 100.0)
	s.update(1.0 / 30)
	var calm := Nerves.target(s)
	var c := s.police.case("runner")
	c.wanted = 3
	var scared := Nerves.target(s)
	check(scared > calm + 0.4, "wanted: %.2f vs %.2f" % [scared, calm])
	s.copilot = "ai"
	check(Nerves.target(s) < scared, "a crew calms you")
	s.copilot = null
	var n := Nerves.new().setup()
	for i in 90:
		n.update(s, 0.1)
	check(n.stress > 0.5, "stress builds in seconds: %.2f" % n.stress)
	check(n.bpm > 120, "heart rate %.0f" % n.bpm)
	c.wanted = 0
	var high := n.stress
	for i in 30:
		n.update(s, 0.1)
	check(n.stress > high * 0.6, "but calm comes slowly: %.2f" % n.stress)
	n.free()
	s.dispose()


func test_tremor_only_on_human_hands() -> void:
	var s := Session.new({"seed": 1, "location": "HAR"})
	var af := World.airfield("HAR")
	s.spawn_airborne(af.x, af.y - 3000, 0.0, 400.0, 100.0)
	s.hand_tremor = Vector2(0.1, -0.05)
	s.update(1.0 / 30)
	check_near(s.fm.controls.aileron, s.mapper.controls.aileron + 0.1, 1e-6, "human: aileron shakes")
	var bot := FlightModel.Controls.make({"throttle": 0.8})
	s.update(1.0 / 30, null, bot)
	check_eq(s.fm.controls.aileron, 0.0, "bot: steady hands")
	check_eq(s.mapper.controls.aileron, s.mapper.controls.aileron, "")
	s.dispose()


func test_spare_helicopters_patrol_before_the_run() -> void:
	var s := Session.new({"seed": 2, "location": "FRM", "features": ["contraband"]})
	var ps := s.police
	ps.stock = {"heli": 3, "interceptor": 1, "cutter": 0}
	var zones := ps.patrol_spares(["north", "west", "sea"])
	check_eq(zones, ["north", "west"], "two spares out, most likely zone first")
	check_eq(ps.stock["heli"], 1, "one stays in the hangar for the chase")
	var goals: Array = ps._launches.map(func(l): return l[4])
	check_eq(goals, [HQ.ZONE_CENTRE["north"], HQ.ZONE_CENTRE["west"]], "flown to the zone centres")
	check(ps.law_events.any(func(e): return "on patrol over the north" in e), "the desk hears about it")
	s.dispose()


func test_one_helicopter_stays_home() -> void:
	var s := Session.new({"seed": 2, "location": "FRM", "features": ["contraband"]})
	var ps := s.police
	ps.stock = {"heli": 1, "interceptor": 1, "cutter": 0}
	check_eq(ps.patrol_spares(["north"]), [], "no spare, no patrol")
	ps.stock = {"heli": 3, "interceptor": 1, "cutter": 0}
	ps.controller = "human"
	check_eq(ps.patrol_spares(["north"]), [], "a human controller decides for themselves")
	s.dispose()


func test_a_patrolling_helicopter_takes_the_chase() -> void:
	var s := Session.new({"seed": 2, "location": "FRM", "features": ["contraband", "interceptors"]})
	var ps := s.police
	ps.stock = {"heli": 2, "interceptor": 0, "cutter": 0}
	ps.patrol_spares(["west"])
	ps.tick((PoliceSystem.LAUNCH_DELAY_S + 1.0), ps.now + (PoliceSystem.LAUNCH_DELAY_S + 1.0), [])
	var u: PoliceSystem.Pursuer = Py.first(ps.units, func(u): return u.kind == "heli")
	check(u != null and u.state == "goto" and u.target_id == null, "out on patrol")
	ps._ai_escalate(ps.case("runner"), 1, _quarry_track(s))
	check_eq(u.target_id, "runner", "the patrol is re-tasked to the flagged track")
	check_eq(_launched_for(ps, "heli", "runner"), 1, "and the reserve launches after it")
	s.dispose()
