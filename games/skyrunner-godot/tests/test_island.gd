extends TestCase
## Isla Soberana: the strip over the horizon, its cheap loads, the mules and the
## containers against customs, the General's passage and the MiGs, the purge,
## and the line where the task force's writ ends.


func after_each() -> void:
	World.use_map(0)


func _sess(opts := {}) -> Session:
	var o := {"seed": 4, "map_seed": MapCity.SEED, "location": "HAR", "features": Session.SANDBOX_FEATURES, "island": true}
	o.merge(opts, true)
	var s := Session.new(o)
	s.police.frozen = true
	s.update(1.0 / 30)
	return s


func test_the_island_is_over_the_horizon_and_landable() -> void:
	var s := _sess()
	var af := World.airfield(Island.CODE)
	check(af != null and af.kind == "foreign", "Aeropuerto Soberano")
	check(not s.world.airfields.has(af), "not one of the mainland's strips (their boards, AI and police are unchanged)")
	check(af.y < -World.HALF, "beyond the map's southern edge")
	check_eq(s.world.airfield_at(af.x, af.y), af, "you can land there")
	check_near(s.world.ground(af.x, af.y), 4.0, 0.01, "the runway")
	check(s.world.is_water(Island.C.x, -20000.0) and s.world.ground(Island.C.x, -20000.0) == 0.0, "the strait between")
	check(s.world.height(Island.C.x, Island.C.y) > 5.0, "hills inland")
	var km := Vector2(af.x, af.y).distance_to(MapCity.CITY_C) / 1000.0
	check(km > 20.0 and km < 30.0, "~25 km from San Telmo (%.0f)" % km)
	s.dispose()


func test_island_loads_are_bought_cheap_and_sold_dear() -> void:
	var s := _sess()
	s.refresh_board(Island.CODE)
	var loads: Array = s.boards[Island.CODE].filter(func(j): return j.cost > 0)
	check(loads.size() >= 4, "loads for sale")
	for j in loads:
		check(j.payout > 2 * j.cost, "worth over twice the island's price at home")
		check(j.hot() and World.airfield(j.dest).kind in ["shady", "bush"], "to a quiet strip")
	var j = loads[0]
	s.location = Island.CODE
	s.money = j.cost - 1
	check(s.accept_job(j) != null, "can't afford it")
	s.money = j.cost + 100
	check_eq(s.accept_job(j), null, "bought")
	check_eq(s.money, 100, "paid up front")
	s.dispose()


func test_mule_odds_move_with_perks_and_the_law() -> void:
	var s := _sess()
	var isl := s.island
	var p0: float = isl.mule_odds()[0]
	check_near(p0, 0.10, 0.001, "10% a mule, cold")
	s.upgrades.law["sniffer_dogs"] = true
	var p1: float = isl.mule_odds()[0]
	check(p1 > p0, "dogs")
	s.upgrades.law["passenger_profiling"] = true
	isl.crackdown_until = s.time + 600.0
	var p2: float = isl.mule_odds()[0]
	check(p2 > p1, "profiling and a crackdown")
	s.upgrades.runner["baggage_handlers"] = true
	s.upgrades.runner["forged_papers"] = true
	s.upgrades.runner["mule_school"] = true
	var p3: float = isl.mule_odds()[0]
	check(p3 < p2 / 3.0, "our handlers, papers and training (%.2f -> %.2f)" % [p2, p3])
	isl.airport_heat = 100.0
	check(isl.mule_odds()[0] > p3, "the heat after a catch")
	check(isl.mule_odds()[1].size() >= 6, "and every factor explained")
	s.dispose()


func test_container_odds_and_the_familys_docks() -> void:
	var s := _sess({"family": true})
	var isl := s.island
	var p0: float = isl.ship_odds()[0]
	s.upgrades.runner["false_bottoms"] = true
	check_near(isl.ship_odds()[0], p0 / 2.0, 0.001, "false bottoms halve it")
	s.family.docks_until = s.time + 600.0
	s.family.docks_honest = true
	check_near(isl.ship_odds()[0], p0 / 4.0, 0.001, "and the union halves it again")
	s.family.docks_honest = false
	check(isl.ship_odds()[0] > p0 / 2.0, "unless the union sold us out")
	s.upgrades.law["container_xray"] = true
	isl.inspections_until = s.time + 600.0
	check(isl.ship_odds()[0] > p0, "X-ray and inspections")
	s.dispose()


func test_mules_mostly_get_through_cold_and_mostly_dont_hot() -> void:
	var s := _sess()
	var isl := s.island
	s.money = 1000000
	check_eq(isl.ship("mules", 8), "", "eight mules")
	var m0 := s.money
	s.time += Island.MULE_ETA_S + 1.0
	isl.update(10.0)
	check(s.money > m0, "paid on arrival")
	check(isl.delivered >= 5, "most through (%d)" % isl.delivered)
	# now the law has everything and a crackdown on
	for id in Island.LAW_NODES:
		s.upgrades.law[id] = true
	isl.crackdown_until = s.time + 99999.0
	isl.airport_heat = 100.0
	var f0 := s.law_funds
	var c0 := isl.caught
	for k in 3:
		isl.ship("mules", 8)
	s.time += Island.MULE_ETA_S + 1.0
	isl.update(10.0)
	check(isl.caught - c0 >= 12, "most of 24 caught (%d)" % (isl.caught - c0))
	check(s.law_funds > f0, "forfeiture")
	s.dispose()


func test_a_container_clears_or_is_opened() -> void:
	var s := _sess()
	var isl := s.island
	s.money = 1000000
	isl.ship("ship", 600)
	var m0 := s.money
	s.time += Island.SHIP_ETA_S + 1.0
	isl.update(10.0)
	check(s.money > m0 or isl.caught == 1, "resolved")
	check(isl.shipments.is_empty(), "")
	# a hurricane holds the freighters
	isl.ship("ship", 600)
	isl.status = "hurricane"
	isl.status_until = s.time + 99999.0
	s.time += Island.SHIP_ETA_S + 1.0
	isl.update(10.0)
	check_eq(isl.shipments.size(), 1, "still in port")
	s.dispose()


func test_the_purge_closes_the_island() -> void:
	var s := _sess()
	var isl := s.island
	isl.purge()
	check(not isl.open(), "closed")
	s.refresh_board(Island.CODE)
	check(s.boards[Island.CODE].is_empty(), "nothing for sale")
	s.money = 100000
	check(isl.ship("mules", 2) != "", "no mules")
	check(isl.buy_passage() != "", "no passage")
	isl.on_arrive()
	check(s.money < 100000, "soldiers on the ramp")
	s.time += 1801.0
	isl.update(10.0)
	check(isl.open(), "open again after a while")
	# the 1989 headline does it too
	var t := _sess({"chronicle": true})
	var ids := Chronicle.HISTORY.map(func(h): return h[0])
	t.chronicle.history(ids.find("ochoa"))
	check_eq(t.island.status, "purge", "the Ochoa affair")
	s.dispose()
	t.dispose()


func test_passage_and_the_migs() -> void:
	var s := _sess()
	var isl := s.island
	s.money = 100000
	var cost := isl.passage_cost()
	check_eq(isl.buy_passage(), "", "bought")
	check(isl.has_passage() and s.money == 100000 - cost, "")
	isl.relations = 90.0
	check(isl.passage_cost() < cost, "cheaper for friends")
	s.dispose()


func test_the_task_force_breaks_off_at_the_line() -> void:
	var s := _sess()
	var ps := s.police
	ps.frozen = false
	ps.case("runner").wanted = 1
	var u := PoliceSystem.Pursuer.new("interceptor", 2000, -24000, 900, 180.0, [0, -9000],
		{"speed": 80, "id": "Falcon-1", "target_id": "runner"})
	ps.units.append(u)
	var sig := SensorNet.Signature.new("runner", 2000, -26000, 900, 900, 0.0, -40.0)
	ps.tick(0.1, 1.0, [PoliceSystem.Target.new(sig, true)])
	check(u.target_id == null and u.state == "return", "Soberana airspace: breaking off")
	s.dispose()


func test_a_defector_angers_the_general() -> void:
	var s := _sess()
	var r0 := s.island.relations
	var j := Jobs.Job.new(Jobs.new_id(), "defector", "fugitive", Island.CODE, "HAR", [], 9000)
	j.defector = true
	s.active_jobs.append(j)
	s._complete_delivery(j, World.airfield("HAR"))
	check(s.island.relations <= r0 - 20.0, "the General knows")
	s.dispose()


func test_commands_and_views() -> void:
	var s := _sess()
	s.money = 100000
	check(s.command(Roles.BOSS, "island_ship", {"method": "ship", "amount": 300})[0], "the boss ships a container")
	check(s.command(Roles.PILOT, "buy_passage")[0], "the pilot buys passage")
	check(not s.command(Roles.CONTROLLER, "island_ship", {"method": "mules", "amount": 1})[0], "not the law's")
	s.law_funds = 10000.0
	check(s.command(Roles.CONTROLLER, "airport_crackdown")[0] and s.island.crackdown_until > s.time, "a crackdown")
	check(s.command(Roles.CHIEF, "port_inspections")[0], "inspections")
	var v := s.island.view("runner")
	check(v.shipments.size() == 1 and v.has("mule_p") and v.passage_s > 0, "the runner's view")
	check(s.island.view("law").has("airport_heat"), "the law's")
	s.dispose()


func test_off_means_no_island() -> void:
	Island.ENABLED = false
	var s := _sess()
	check(s.island == null, "no island")
	s.dispose()
	Island.ENABLED = true
	var c := Session.new({"seed": 4, "map_seed": 0, "location": "HAR", "island": true})
	check(c.island == null, "not on the classic map")
	c.dispose()
