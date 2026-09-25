extends TestCase
## The co-pilot seat, end to end: what the gate lets it do, how much faster a
## second pair of hands makes the in-flight work, and that its radio chatter
## stays on the runner side.


const REFUSED := ["transponder", "autopilot", "buy_aircraft", "buy_gear", "confirm", "turn_around", "hq",
	"launch", "dispatch", "spotter_move", "boat_goto"]


static func _airdrop(s: Session, bales: int) -> Jobs.Job:
	var drop := Maritime.random_drop_point(s.world, s.rng, s.maritime.cove)
	var job := Jobs.airdrop_job(World.airfield("HAR"), drop, s.rng, bales)
	s.boards["HAR"].append(job)
	s.accept_job(job)
	T.idle(s, 30)
	return job


func test_the_gate_lets_the_copilot_crew_but_not_fly() -> void:
	var s := T.sess(5)
	T.idle(s, 0.3)
	for c in Roles.PERMISSIONS[Roles.COPILOT]:
		var r := s.command(Roles.COPILOT, c, {})
		check(r[0] or not ("can't" in r[1]), "copilot may '%s' (%s)" % [c, r[1]])
	for c in REFUSED:
		var r := s.command(Roles.COPILOT, c, {})
		check(not r[0] and "can't" in r[1], "copilot refused '%s'" % c)


## Seconds until every bale is out, with `role` doing the kicking.
static func _kick_time(copilot, role: String) -> float:
	var s := T.sess(5)
	s.features.erase("cutters")
	s.set_copilot(copilot)
	T.idle(s, 0.3)
	var job := _airdrop(s, 4)
	s.spawn_airborne(job.drop_point[0], job.drop_point[1], 90, 150, 85)
	s.mapper.controls.throttle = 0.6
	s.command(Roles.PILOT, "autopilot", {"on": true})
	var r := s.command(role, "kick", {"count": 4})
	assert(r[0], str(r))
	var t := 0.0
	while not s._droppables().is_empty() and t < 60.0:
		s.update(1.0 / 30, T.inp())
		t += 1.0 / 30
	s.dispose()
	return t


func test_a_copilot_kicks_twice_as_fast() -> void:
	var solo := _kick_time(null, Roles.PILOT)
	var crewed := _kick_time("human", Roles.COPILOT)
	check_near(solo, 4 * Session.KICK_TIME["pilot"], 0.2, "solo: 4 s a bale")
	check_near(crewed, 4 * Session.KICK_TIME["copilot"], 0.2, "co-pilot: 2 s a bale")


## Ferry fuel moved to the wings in one minute.
static func _pumped(copilot) -> float:
	var s := T.sess(5)
	s.set_copilot(copilot)
	T.idle(s, 0.3)
	s.money = 20000
	s.command(Roles.PILOT, "buy_gear", {"name": "ferry_tank"})
	T.idle(s, 20)
	s.command(Roles.PILOT, "fill_ferry", {"lb": 200})
	T.idle(s, 0.2)
	s.spawn_airborne(0, -9000, 90, 600, 95)
	s.fm.fdm.set_property("propulsion/tank[0]/contents-lbs", 30)
	s.fm.fdm.set_property("propulsion/tank[1]/contents-lbs", 30)
	var f0 := s.loadout.ferry_fuel_lb()
	var who := Roles.COPILOT if copilot else Roles.PILOT
	assert(s.command(who, "pump", {"on": true})[0])
	s.command(Roles.PILOT, "autopilot", {"on": true})
	T.idle(s, 60)
	var moved := f0 - s.loadout.ferry_fuel_lb()
	s.dispose()
	return moved


func test_a_copilot_hand_pumps_the_ferry_tank_faster() -> void:
	var solo := _pumped(null)
	var crewed := _pumped("human")
	check_near(solo, Session.PUMP_RATE_LB_MIN["pilot"], 3.0, "solo electric pump %.1f lb/min" % solo)
	check_near(crewed, Session.PUMP_RATE_LB_MIN["copilot"], 3.0, "co-pilot %.1f lb/min" % crewed)


func test_copilot_chat_stays_on_the_runner_side() -> void:
	var s := T.sess(5, {"mode": Roles.COOP})
	T.idle(s, 0.3)
	check(s.command(Roles.COPILOT, "chat", {"text": "boat's late, holding"})[0], "sent")
	var runner := Snapshot.build(s, Roles.PILOT)
	var law := Snapshot.build(s, Roles.CONTROLLER)
	check(runner["messages"].any(func(m): return "[copilot] boat's late" in m), "pilot hears it")
	check(not law["messages"].any(func(m): return "boat's late" in m), "the police don't")
	s.command(Roles.COPILOT, "chat", {"text": "x".repeat(500)})
	check_eq(s.messages.back()[1].length(), "[copilot] ".length() + 200, "long messages are cut at 200")


func test_copilot_hires_spotters() -> void:
	var s := T.sess(5)
	T.idle(s, 0.3)
	s.money = 5000
	check(s.command(Roles.COPILOT, "hire_spotter", {"code": "VAL"})[0], "by code")
	check(s.command(Roles.COPILOT, "hire_spotter", {})[0], "defaults to where we are (%s)" % s.location)
	check_eq(s.spotters.map(func(sp): return sp.code), ["VAL", s.location])
	check(not s.command(Roles.COPILOT, "hire_spotter", {"code": "VAL"})[0], "not twice")


func test_copilot_calls_the_boat_and_the_law_hears_it() -> void:
	var s := T.sess(5)
	T.idle(s, 0.3)
	var job := _airdrop(s, 2)
	s.spawn_airborne(job.drop_point[0], job.drop_point[1], 90, 150, 90)
	check(s.command(Roles.COPILOT, "call_boat")[0], "called")
	check(Py.any(s.law_log, func(e): return "DF" in e[1]), "the radio call gives DF bearings")


func test_copilot_loads_and_fuels_on_the_ground() -> void:
	var s := T.sess(5)
	T.idle(s, 0.3)
	var job: Jobs.Job = T.first(s.boards[s.location], func(j): return not j.is_airdrop())
	check(s.command(Roles.COPILOT, "accept_job", {"job_id": job.id})[0], "accepts a job")
	check(s.command(Roles.COPILOT, "set_fuel", {"lb": 150})[0], "sets fuel")
	T.idle(s, 1)
	check_near(s.state.fuel_lb, 150, 2, "fuel set")
	var item: int = s.loadout.items.keys()[0]
	check(s.command(Roles.COPILOT, "move_item", {"item_id": item, "direction": 1})[0], "moves cargo")


func test_the_pilot_is_calmer_with_a_copilot() -> void:
	var s := T.sess(5)
	T.idle(s, 0.3)
	s.spawn_airborne(0, -9000, 90, 600, 95)
	T.idle(s, 0.2)
	s.police.case("runner").wanted = 2
	var alone := Nerves.target(s)
	s.set_copilot("human")
	var crewed := Nerves.target(s)
	check(crewed < alone, "stress %.2f -> %.2f" % [alone, crewed])
	check_near(crewed / alone, 0.75, 0.01, "a co-pilot takes a quarter off")
