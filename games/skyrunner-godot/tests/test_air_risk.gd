extends TestCase
## AirRisk: the live-play simulator's flights roll what the tactical sweep
## measured (sim-results/tactical.json), against the session's police as they
## are, flying the tactic that did best - or not flying at all.


func after_each() -> void:
	World.use_map(0)


func _sess() -> Session:
	var s := Session.new({"seed": 5, "map_seed": MapCity.SEED, "location": "FRM", "features": Session.SANDBOX_FEATURES})
	s.police.frozen = true
	return s


func test_the_table_is_the_sweep() -> void:
	var t := AirRisk.table()
	for p in ["light", "standard", "heavy", "aerostat", "patrol", "tipped", "all_in"]:
		check(t.has(p), "posture %s measured" % p)
		for tac in AirRisk.TACTICS:
			var r: Array = t[p][tac]
			check(r[0] > 0.0 and r[0] < 1.0 and r[1] > 0.0 and r[2] > 0.0, "%s/%s smoothed, never 0 or 1" % [p, tac])
	# 30 flights high against standard police: none busted, 23 delivered
	check_near(t.standard.high[0], 1.0 / 32.0, 1e-6, "0 of 30 busts reads as 1 in 32")
	check_near(t.standard.high[2], 24.0 / 32.0, 1e-6, "23 of 30 delivered")


func test_the_police_pick_the_posture() -> void:
	var s := _sess()
	s.police.stock = {"heli": 1, "interceptor": 2, "cutter": 1}
	check_eq(AirRisk.posture(s), "standard")
	s.police.stock = {"heli": 2, "interceptor": 2, "cutter": 1}
	check_eq(AirRisk.posture(s), "heavy")
	s.police.stock = {"heli": 1, "interceptor": 0, "cutter": 1}
	check_eq(AirRisk.posture(s), "light")
	s.police.stock = {"heli": 2, "interceptor": 2, "cutter": 1}
	s.police.heli_grounded = true  # dense fog: only the interceptors are up
	check_eq(AirRisk.posture(s), "standard")
	s.police.case("runner").suspicion = 70.0
	check_eq(AirRisk.posture(s), "tipped", "they're expecting us")
	s.dispose()


func test_the_pilot_flies_the_best_way_in_or_stays_home() -> void:
	var s := _sess()
	s.police.stock = {"heli": 1, "interceptor": 2, "cutter": 1}
	var o := AirRisk.odds(s)
	check_eq(o.tactic, "high", "high beat low and evasive against standard police")
	check(o.fly and o.bust < 0.05, "and it's safe enough to fly")
	s.police.case("runner").suspicion = 80.0
	o = AirRisk.odds(s)
	check(not o.fly, "tipped off: every way in is busted more than a quarter of the time")
	check(o.bust > AirRisk.LIE_LOW)
	s.dispose()
