extends TestCase
## Pilot bot, route/approach/departure planners, live HQ nights, police pilot
## seat (ported from tests/test_bots.py).

var w: World


func before_each() -> void:
	if w == null:
		w = World.new()


func _sess(opts: Dictionary) -> Session:
	return Session.new(opts)


func test_every_strip_has_a_clear_approach() -> void:
	for af in World.AIRFIELDS:
		var ap := PilotBot.plan_approach(w, af, 1.2, 120.0)
		check(ap.clear_m >= 0, "%s: no approach path clears the terrain" % af.code)
		check(ap.gamma <= 9.5, "%s glide angle %.1f" % [af.code, ap.gamma])


func test_departures_leave_downhill() -> void:
	# the quarry only opens to the north-west (the haul road); Pine Ridge's uphill end is a hillside
	check_eq(PilotBot.plan_departure(w, World.airfield("QRY"), 160)[0], 340.0, "QRY")
	check_eq(PilotBot.plan_departure(w, World.airfield("PNR"), 160)[0], 45.0, "PNR")


func test_route_planner_threads_low_ground() -> void:
	var frm := World.airfield("FRM")
	var qry := World.airfield("QRY")
	var pts := RoutePlanner.plan_route(w, [frm.x, frm.y], [qry.x, qry.y])
	check(pts.size() >= 3, "waypoints: %d" % pts.size())
	check_eq(pts[-1], [qry.x, qry.y], "ends at the goal")
	var straight_max := -1e9
	for t in 21:
		straight_max = maxf(straight_max, w.height(frm.x + (qry.x - frm.x) * t / 20, frm.y + (qry.y - frm.y) * t / 20))
	var route_max := -1e9
	for p in pts:
		route_max = maxf(route_max, w.height(p[0], p[1]))
	check(route_max <= straight_max + 1, "route max %.0f vs straight %.0f" % [route_max, straight_max])


func test_route_distance_sanity() -> void:
	var har := World.airfield("HAR")
	var isl := World.airfield("ISL")
	var pts := RoutePlanner.plan_route(w, [har.x, har.y], [isl.x, isl.y])
	var length := 0.0
	var prev := [har.x, har.y]
	for p in pts:
		length += Py.dist2(prev, p)
		prev = p
	check(length < 2.0 * Py.dist2([har.x, har.y], [isl.x, isl.y]))


func test_bot_flies_and_lands_a_cessna() -> void:
	var s := _sess({"seed": 5, "location": "HAR", "features": []})
	s.police.frozen = true
	var val := World.airfield("VAL")
	var bot := PilotBot.new(s, [PilotBot.Leg.new("land", val.x, val.y, "VAL")])
	check_eq(PilotBot.fly(s, bot, 900), "landed", "outcome")
	check_eq(s.phase, "parked")
	check_eq(s.location, "VAL")
	check(s.log.max_touchdown_fpm < s.spec.gear_limit_fpm, "touchdown %.0f fpm" % s.log.max_touchdown_fpm)
	s.dispose()


func test_turn_around_pushes_the_aircraft_round() -> void:
	var s := _sess({"seed": 5, "location": "PNR", "features": []})
	var h0 := s.state.heading
	check_eq(s.command(Roles.PILOT, "turn_around", {}), [true, "ok"])
	for i in 21 * 30:
		s.update(1.0 / 30)
	check(absf(Py.fmod(s.state.heading - h0, 360) - 180) < 3, "heading turned %.1f" % (s.state.heading - h0))
	check(s.parked, "still parked")
	s.dispose()


func test_fuel_plan_is_route_plus_reserve() -> void:
	var s := _sess({"seed": 5, "location": "FRM", "features": []})
	var af := World.airfield("EGL")
	var fuel := PilotBot.plan_fuel_lb(s, [PilotBot.Leg.new("land", af.x, af.y, "EGL")])
	check_between(fuel, 30.0, s.loadout.mass.fuel_capacity_lb() * 0.6)
	s.dispose()


## A whole night in the real Session: AI chief plans, the bot flies an
## airdrop, the season scores it and moves to night 2.
func test_live_night_with_hq() -> void:
	var s := _sess({"seed": 9, "location": "FRM", "features": Session.SANDBOX_FEATURES + ["hq"]})
	s.set_copilot("ai")
	s.update(1.0 / 30)
	check_eq(s.nights.season.night, 1)
	check_eq(s.nights.phase, "planning")
	check_eq(s.command(Roles.PILOT, "hq", {"order": "route", "zone": "sea"}), [true, "ok"])
	var job: Jobs.Job = Py.first(s.boards["FRM"], func(j): return j.hot())
	check_eq(s.accept_job(job), null, "accept")
	s.loadout.pending.clear()
	s.fm.apply_loadout(s.loadout)
	var legs := PilotBot.mission_for(s, job)
	s.set_fuel(PilotBot.plan_fuel_lb(s, legs))
	PilotBot.fly(s, PilotBot.new(s, legs), 2400)
	var t := s.time
	while s.nights.phase != "planning" and s.time - t < 900:
		s.update(0.1)
	check(s.nights.season.night == 2 or s.nights.season.phase == "over", "night %d" % s.nights.season.night)
	var snap := Snapshot.build(s, Roles.PILOT)
	check(snap["season"]["night"] >= 1 and snap["season"].has("org"), "runner season view")
	check(not Snapshot.build(s, Roles.CONTROLLER)["season"].has("org"), "law can't see the org")
	s.dispose()


func test_police_pilot_claims_flies_and_sees_only_what_is_in_sight() -> void:
	var s := _sess({"mode": Roles.VERSUS, "seed": 4, "humans": {Roles.INTERCEPTOR: "Evelyn"}})
	check_eq(s.command(Roles.INTERCEPTOR, "claim_unit", {"kind": "interceptor"}), [true, "ok"])
	for i in 30 * 12:
		s.update(1.0 / 30)
	var me = Py.first(s.police.units, func(u): return u.pilot == "interceptor")
	check(me != null, "unit launched")
	if me == null:
		return
	s.set_pilot_input("interceptor", 0.6, 0.5, 1.0)
	var h0: float = me.heading
	var z0: float = me.z
	for i in 30 * 5:
		s.update(1.0 / 30)
	check(Py.fmod(me.heading - h0, 360) > 5, "turned")
	check(me.z > z0 + 20, "climbed")
	var snap := Snapshot.build(s, Roles.INTERCEPTOR)
	check_eq(snap["me"]["id"], me.id)
	# the runner is parked miles away behind terrain: not in the visual list
	check(not Py.any(snap["visual"], func(v): return v["kind"] == "runner"), "runner not visible")
	check_eq(s.command(Roles.INTERCEPTOR, "release_unit", {}), [true, "ok"])
	check_eq(me.pilot, null)
	s.dispose()


func test_pilot_cannot_claim_police_units() -> void:
	var s := _sess({"mode": Roles.VERSUS, "seed": 4})
	var r: Array = s.command(Roles.PILOT, "claim_unit", {})
	check(not r[0] and "can't" in r[1], str(r))
	s.dispose()


func _landed_at_quarry() -> Array:
	var s := _sess({"seed": 3, "location": "QRY", "features": Session.SANDBOX_FEATURES})
	s.update(1.0 / 30)
	var job: Jobs.Job = Py.first(s.boards["QRY"], func(j): return j.hot() and not j.is_airdrop())
	job.dest = "QRY"  # pretend we just flew it in
	s.accept_job(job)
	s.loadout.pending.clear()
	s._arrive(s.airfield, s.state)
	return [s, job]


func test_hot_load_unloads_slowly_and_can_be_raided() -> void:
	var r := _landed_at_quarry()
	var s: Session = r[0]
	var job: Jobs.Job = r[1]
	check(s.unloading == [job] and job in s.active_jobs, "unloading")
	var money = s.money
	for i in 62 * 10:
		s.update(0.1)
	check(s.unloading.is_empty() and not (job in s.active_jobs) and s.money > money, "unloaded and paid")
	s.dispose()
	# same again, but a police helicopter turns up
	r = _landed_at_quarry()
	s = r[0]
	var af := World.airfield("QRY")
	s.police.units.append(PoliceSystem.Pursuer.new("heli", af.x + 800, af.y, s.state.alt + 150, 0.0, [0, 0], {"id": "Hawk-9"}))
	for i in 20:
		s.update(0.1)
	check_eq(s.phase, "busted")
	check("raided" in s.last_outcome, s.last_outcome)
	s.dispose()


## The career bot on its own: accepts, fuels, flies and gets paid.
func test_autorunner_completes_a_flight() -> void:
	var s := _sess({"seed": 5, "location": "HAR", "features": []})
	s.police.frozen = true
	var ar := AutoRunner.new(s, false)
	var money = s.money
	var dt := 1.0 / 30
	while s.time < 1500 and (ar.flights == 0 or ar.bot.phase != "done" or not s.parked or not s.unloading.is_empty()):
		s.update(dt, null, ar.step(dt))
	check(ar.flights >= 1, "flew")
	check_eq(ar.bot.outcome if ar.bot else null, "landed")
	check(s.money > money, "paid: %s -> %s" % [money, s.money])
	s.dispose()
