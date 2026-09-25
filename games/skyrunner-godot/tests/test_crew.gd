extends TestCase
## Crew mechanics: commands & permissions, loading time, ferry fuel, airdrops,
## transponder, autopilot, scanner, spotters, informants. Ported from tests/test_crew.py


func _sess() -> Session:
	return T.sess(5)


static func run(s: Session, secs: float, held: Array = [], pressed: Array = []) -> void:
	for i in int(secs * 60):
		s.update(1.0 / 60, T.inp(held, pressed))


static func _rng(seed: int) -> PyRandom:
	var r := PyRandom.new()
	r.seed(seed)
	return r


func test_permissions_gate_commands() -> void:
	var s := _sess()
	var r := s.command(Roles.CONTROLLER, "accept_job", {"job_id": 1})
	check(not r[0] and "can't" in r[1], "controller can't take jobs")
	check(not s.command(Roles.COPILOT, "transponder")[0], "pilot-only switch")
	r = s.command(Roles.PILOT, "transponder", {"on": false})
	check(r[0] and s.transponder == false, "pilot switches it off")


func test_copilot_loads_faster() -> void:
	var times := {}
	for crew in [null, "ai"]:
		var s := T.sess(5, {"location": "FRM"})  # bush strip: no ramp crew
		s.set_copilot(crew)
		run(s, 0.3)
		var job: Jobs.Job = T.first(s.boards["FRM"], func(j): return j.items.size() >= 2 \
			and not Py.any(j.items, func(i): return i.kind == "passenger"))
		s.accept_job(job)
		var t := 0.0
		while not s.loadout.pending.is_empty() and t < 120:
			run(s, 0.5)
			t += 0.5
		times[crew] = t
	check(times["ai"] < times[null] * 0.75, str(times))


func test_ferry_tank_fuel_moves_weight_and_cg() -> void:
	var s := _sess()
	run(s, 0.3)
	s.money = 20000
	check(s.command(Roles.PILOT, "buy_gear", {"name": "ferry_tank"})[0], "bought")
	run(s, 20)
	check(s.command(Roles.PILOT, "fill_ferry", {"lb": 200})[0], "filled")
	run(s, 0.2)
	check(s.fm.state().weight_lb > 1900, "heavier")
	s.spawn_airborne(0, -9000, 90, 600, 95)
	s.command(Roles.PILOT, "set_fuel", {"lb": 0})  # no-op in the air
	s.fm.fdm.set_property("propulsion/tank[0]/contents-lbs", 40)
	s.fm.fdm.set_property("propulsion/tank[1]/contents-lbs", 40)
	var ferry0 := s.loadout.ferry_fuel_lb()
	check(s.command(Roles.PILOT, "pump", {"on": true})[0], "pump on")
	run(s, 60)
	check(s.loadout.ferry_fuel_lb() < ferry0 - 20, "solo electric pump ~25 lb/min")
	check(s.state.fuel_lb > 80 - 10, "wings got fuel")
	var re := s.range_estimate()
	check(re[0] > 0 and re[1] > 50, "range estimate %s" % [re])


func test_airdrop_to_boat_pays_at_the_cove() -> void:
	var s := _sess()
	s.features.erase("cutters")
	run(s, 0.3)
	var drop := Maritime.random_drop_point(s.world, s.rng, s.maritime.cove)
	var job := Jobs.airdrop_job(World.airfield("HAR"), drop, s.rng, 3)
	s.boards["HAR"].append(job)
	s.set_copilot("ai")
	check(s.accept_job(job) == null, "accepted")
	run(s, 30)
	check(s.loadout.pending.is_empty(), "loaded")
	var boat := s.maritime.gofast_for(job.id)
	boat.x = drop[0] + 100
	boat.y = drop[1]
	boat.state = "waiting"  # skip the 5 min boat ride out
	# teleport the aircraft over the rendezvous, slow and low; the co-pilot auto-kicks
	s.spawn_airborne(drop[0] - 300, drop[1], 90, 120, 85)
	s.mapper.controls.throttle = 0.7
	s.command(Roles.PILOT, "autopilot", {"on": true})
	for i in 60 * 20:
		s.update(1.0 / 60, T.inp())
	check(s._droppables().is_empty(), "all kicked")
	check_eq(s.phase, "flying")
	var money := s.money
	for i in 30 * 60 * 15:  # boat collects, runs for the cove
		s.update(1.0 / 30, T.inp())
		if job.resolved:
			break
	check(job.resolved and boat.state == "delivered", "boat made the cove")
	check(s.money > money, "paid")


func test_solo_kick_needs_autopilot() -> void:
	var s := _sess()
	run(s, 0.3)
	var drop := Maritime.random_drop_point(s.world, s.rng, s.maritime.cove)
	var job := Jobs.airdrop_job(World.airfield("HAR"), drop, s.rng, 2)
	s.boards["HAR"].append(job)
	s.accept_job(job)
	run(s, 30)
	s.spawn_airborne(drop[0], drop[1], 90, 150, 85)
	var r := s.command(Roles.PILOT, "kick")
	check(not r[0] and "autopilot" in r[1].to_lower(), "needs AP")
	s.command(Roles.PILOT, "autopilot", {"on": true})
	check(s.command(Roles.PILOT, "kick", {"count": 2})[0], "kick queued")
	run(s, 5, ["roll_left"])  # pilot is aft: stick input ignored, AP stays on
	check(s.autopilot.engaged, "AP still on")
	run(s, 5)
	check(s._droppables().is_empty(), "all kicked")


func test_scanner_and_spotter_intel() -> void:
	var s := _sess()
	run(s, 0.3)
	s.money = 20000
	s.command(Roles.PILOT, "buy_gear", {"name": "scanner"})
	s.command(Roles.PILOT, "hire_spotter", {"code": "VAL"})
	s.police.launch("heli", "VAL", null, [2500, -3000])
	run(s, 15)
	check(Py.any(s.scanner_log, func(e): return "Hawk" in e[1]), "scanner heard Hawk")
	check(Py.any(s.intel.keys(), func(k): return k.begins_with("Hawk")), "intel on Hawk")


func test_informant_tip_marks_the_runner() -> void:
	var s := _sess()
	s.features["informants"] = true
	s.police.features["informants"] = true
	s.rng.seed(1)
	run(s, 0.3)
	var tipped := false
	for i in 20:
		s.location = "COV"
		s.refresh_board("COV")
		s.spawn_at("COV")
		var hot = T.first(s.boards["COV"], func(j): return j.hot())
		if hot == null:
			continue
		s.accept_job(hot)
		if not s.police.tips.is_empty():
			tipped = true
			break
		s.drop_job(hot)
	check(tipped, "an informant talked")
	check(s.police.case("runner").tipped, "runner case tipped")


func test_police_mode_ai_runs_and_controller_commands() -> void:
	var s := T.sess(9, {"mode": Roles.POLICE, "humans": {Roles.CONTROLLER: "me"}})
	check_eq(s.police.controller, "human")
	for i in 25 * 20:
		s.update(1.0 / 20)
	check(not s.smugglers.is_empty(), "an AI run should have been scheduled")
	check(s.command(Roles.CONTROLLER, "launch", {"kind": "interceptor", "base": "HAR"})[0], "launch interceptor")
	check(s.command(Roles.CONTROLLER, "launch", {"kind": "cutter", "x": s.maritime.cove[0], "y": s.maritime.cove[1]})[0], "launch cutter")
	for i in 10 * 20:
		s.update(1.0 / 20)
	var falcon = T.first(s.police.units, func(u): return u.kind == "interceptor")
	var r := s.command(Roles.CONTROLLER, "dispatch", {"unit": falcon.id, "target": s.smugglers[0].id})
	check(r[0] and falcon.target_id == s.smugglers[0].id, "dispatched")
	check(not s.command(Roles.PILOT, "launch", {"kind": "heli"})[0], "pilot can't launch police")


func test_transponder_off_gets_you_noticed() -> void:
	var s := _sess()
	run(s, 0.3)
	var har := World.airfield("HAR")
	s.spawn_airborne(har.x + 2000, har.y - 4000, 90, 500, 100)
	s.mapper.controls.throttle = 0.8
	s.command(Roles.PILOT, "autopilot", {"on": true})
	run(s, 8)
	check_eq(s.police.suspicion, 0.0, "squawking: just traffic")
	s.command(Roles.PILOT, "transponder", {"on": false})
	run(s, 4)
	check(s.police.suspicion >= 50 or s.police.wanted, "squawk lost")
	check(s.police.detector() in ["LOCK", "PAINT"], "detector lit")


func test_fuel_caches_at_shady_strips() -> void:
	var s := _sess()
	s.spawn_at("QRY")
	var before := s.fm.fuel_lb()
	s.set_fuel(before + 100)
	run(s, 0.1)  # JSBSim totals the tanks on its next step
	check_near(s.fm.fuel_lb(), before, 1, "nothing for sale at the quarry")
	s.fuel_caches["QRY"] = 150.0
	var money := s.money
	s.set_fuel(before + 100)
	run(s, 0.1)
	check_near(s.fm.fuel_lb(), before + 100, 1, "cache used")
	check(s.money == money, "already paid for")
	check_near(s.fuel_caches["QRY"], 50, 0.5, "cache drawn down")


func test_police_units_go_home_at_bingo_fuel() -> void:
	var ps := PoliceSystem.new(World.new(), _rng(1))
	var u := PoliceSystem.Pursuer.new("heli", 0, -6000, 500, 0.0, [-9000, -9500],
		{"speed": 50, "id": "Hawk-1", "goal": [0.0, -6000.0], "state": "goto"})
	u.fuel_s = 2.0
	ps.units.append(u)
	var t := 0.0
	for i in 100:
		t += 0.05
		ps.tick(0.05, t, [])
	check_eq(u.state, "return")
	check(PoliceSystem.ENDURANCE_S["heli"] > 600)


func test_calling_the_boat_gives_df_bearings() -> void:
	var s := _sess()
	run(s, 0.3)
	var drop := Maritime.random_drop_point(s.world, s.rng, s.maritime.cove)
	var job := Jobs.airdrop_job(World.airfield("HAR"), drop, s.rng, 2)
	s.boards["HAR"].append(job)
	s.accept_job(job)
	s.spawn_airborne(drop[0], drop[1], 90, 150, 90)
	check(s.command(Roles.PILOT, "call_boat")[0], "called")
	check(Py.any(s.law_log, func(e): return "DF" in e[1]), "DF bearings logged")
