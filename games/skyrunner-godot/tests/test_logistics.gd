extends TestCase
## Logistics: product and cash are somewhere. Loads land in a stash; dealers
## sell only what's in their own market; street money piles up in the stash
## until a truck (or the aircraft) takes it to the club; bulk buyers take
## delivery at their meet and the money rides back; the growers want cash on
## the strip; trucks get stopped and hijacked; raids and busts take what's there.


func after_each() -> void:
	World.use_map(0)


func _sess(opts := {}) -> Session:
	var o := {"seed": 21, "map_seed": MapCity.SEED, "location": "FRM", "features": Session.SANDBOX_FEATURES,
		"trade": true, "payroll": true, "logistics": true}
	o.merge(opts, true)
	var s := Session.new(o)
	s.police.frozen = true
	s.payroll.ai["org"] = false
	s.payroll.ai["rival"] = false
	s.update(1.0 / 30)
	return s


func _dealer(s: Session, m: String) -> Dictionary:
	var w: Dictionary = s.payroll._person("org", "dealer")
	w.skill = 0.8
	w.loyalty = 0.95
	s.payroll.candidates["org"].append(w)
	s.payroll.hire("org", w.id)
	w.status = "assigned"
	w.assigned = "corner-" + m
	return w


## Run the trucks (no police about) until nothing's on the road.
func _drive(s: Session, clear_roadblocks := true) -> void:
	for i in 1500:
		if clear_roadblocks:
			for t in s.stash_net.trucks:
				t.stop_at = -1.0
		s.time += 5.0
		s._update_stashes(5.0)
		if s.stash_net.trucks.is_empty():
			return


func test_a_load_lands_in_its_stash() -> void:
	var s := _sess()
	s.refresh_board("FRM")
	var j = Py.first(s.boards["FRM"], func(x): return x.own_good == "marijuana")
	var lb := Py.sum_by(j.items, func(i): return i.weight_lb)
	var site: String = s.logistics.site_at(j.dest)
	check(site != "" and site != Logistics.HQ, "bought for the stash at %s" % j.dest)
	s.trade.delivered(j)
	check_near(s.logistics.stock[site].marijuana, lb, 0.01, "into %s" % site)
	check_near(s.trade.stock.marijuana, lb, 0.01, "the trade's total follows")
	s.dispose()


func test_the_growers_want_cash_on_the_strip() -> void:
	var s := _sess()
	s.money = 50000
	s.refresh_board("FRM")
	var j = Py.first(s.boards["FRM"], func(x): return x.own_good == "marijuana")
	var err = s.accept_job(j)
	check(err is String and "cash on the strip" in err, "no bags aboard, no load: %s" % str(err))
	check_eq(s.money, 50000, "the club's safe isn't on the strip")
	s.logistics.aboard = j.cost + 100
	check(s.accept_job(j) == null, "paid from the bags")
	check_eq(s.logistics.aboard, 100, "the change")
	s.dispose()


func test_dealers_sell_only_what_is_in_their_market() -> void:
	var s := _sess()
	s.logistics.add("camp", "cocaine", 40.0)  # the jungle camp: north
	var money0 := s.money
	_dealer(s, "west")
	s.trade._sell_street("org", 600.0)
	check_near(s.logistics.stock.camp.cocaine, 40.0, 0.01, "a west-side dealer can't sell what's up north")
	_dealer(s, "north")
	s.trade._sell_street("org", 600.0)
	check(s.logistics.stock.camp.cocaine < 40.0, "the north dealer sells from the camp")
	check(s.logistics.cash.camp > 200.0, "and the money piles up at the camp ($%d)" % int(s.logistics.cash.camp))
	check(s.money <= money0, "not in the club's safe")
	s.dispose()


func test_cash_trucked_home() -> void:
	var s := _sess()
	s.logistics.cash["camp"] = 12000.0
	var money0 := s.money
	check_eq(s.command(Roles.BOSS, "move_cash", {"from": "camp", "to": "hq"})[0], true)
	check_eq(s.logistics.cash.camp, 0.0, "on the truck")
	check_eq(s.logistics.view().trucks.size(), 1, "one truck on the road")
	var fee := money0 - s.money  # no driver on the payroll: one off the street, a day's pay
	check(fee >= 0 and fee < 1000, "a day driver's fee ($%d)" % fee)
	_drive(s)
	check_eq(s.money, money0 - fee + 12000, "home in the safe")
	s.dispose()


func test_a_stopped_truck_forfeits_the_lot() -> void:
	var s := _sess()
	s.logistics.cash["camp"] = 30000.0
	var law0 := s.law_funds
	var susp0: float = s.police.case("runner").suspicion
	s.logistics.send("camp", Logistics.HQ, "cash", 30000.0)
	s.stash_net.trucks[0].stop_at = 0.3
	_drive(s, false)
	check_eq(s.logistics.lost.cash, 30000, "gone")
	check(s.law_funds > law0 + 10000.0, "the task force keeps half")
	check(s.police.case("runner").suspicion > susp0, "and learns something")
	s.dispose()


func test_product_moved_between_stashes() -> void:
	var s := _sess()
	s.logistics.add("barn", "marijuana", 500.0)
	var r: Array = s.command(Roles.PILOT, "move_goods", {"from": "barn", "to": "camp", "good": "marijuana", "lb": 200})
	check(r[0], str(r[1]))
	check_near(s.logistics.stock.barn.marijuana, 300.0, 0.01)
	check_near(s.trade.stock.marijuana, 300.0, 0.01, "on the road doesn't count as held")
	_drive(s)
	check_near(s.logistics.stock.camp.marijuana, 200.0, 0.01, "arrived up north")
	check_near(s.trade.stock.marijuana, 500.0, 0.01)
	s.dispose()


func test_a_buyer_takes_delivery_and_the_money_rides_back() -> void:
	var s := _sess({"family": true})
	s.family.respect = 60.0
	s.logistics.add("lockup", "marijuana", 300.0)
	var err := s.trade.sell("family", "marijuana", 200.0, "rifle", "lockup")
	check_eq(err, "", "on the truck to the Morettis")
	check_near(s.logistics.stock.lockup.marijuana, 100.0, 0.01, "200 lb out")
	check_eq(s.trade.sold.marijuana, 0.0, "not sold until it's there")
	for i in 400:
		for t in s.stash_net.trucks:
			t.stop_at = -1.0
		s.time += 5.0
		s._update_stashes(5.0)
		if s.trade.sold.marijuana > 0.0:
			break
	check_near(s.trade.sold.marijuana, 200.0, 0.01, "the Morettis took it at their club")
	check_eq(s.logistics.view().trucks.size(), 1, "and the money's on its way back")
	_drive(s)
	check(s.logistics.cash.lockup > 500.0, "the cash is in the lock-up ($%d)" % int(s.logistics.cash.lockup))
	s.dispose()


func test_cash_bags_in_the_aircraft() -> void:
	var s := _sess({"location": "HAR"})
	var site: String = s.logistics.site_at("HAR")
	check_eq(site, "docks", "the docks warehouse by the harbour strip")
	s.logistics.cash["docks"] = 45000.0
	check(s.command(Roles.PILOT, "load_cash", {})[0], "loaded")
	check_eq(s.logistics.aboard, 45000)
	var bags = Py.first(s.loadout.items.values(), func(i): return i.label == "Cash bags")
	check(bags != null and absf(bags.weight_lb - 10.0) < 0.01, "ten pounds of street money")
	check(bags.hot, "and the police would call it evidence")
	var money0 := s.money
	s.location = s.logistics.hq_strip()
	check(s.command(Roles.PILOT, "unload_cash", {})[0], "into the safe")
	check_eq(s.money, money0 + 45000, "at the club's strip (%s) the bags go to the safe" % s.location)
	check(Py.first(s.loadout.items.values(), func(i): return i.label == "Cash bags") == null, "bags off")
	s.dispose()


func test_a_raid_takes_what_is_there() -> void:
	var s := _sess()
	s.logistics.add("barn", "cocaine", 30.0)
	s.logistics.cash["barn"] = 8000.0
	s.logistics.add("camp", "cocaine", 10.0)
	s.stash_net.get_stash("barn").heat = 80.0
	s._raid("barn")
	check_eq(s.logistics.stock.barn.cocaine, 0.0, "product gone")
	check_eq(s.logistics.cash.barn, 0.0, "cash gone")
	check_near(s.trade.stock.cocaine, 10.0, 0.01, "the other stashes untouched")
	s.dispose()


func test_a_bust_takes_the_bags() -> void:
	var s := _sess()
	s.logistics.aboard = 20000
	s._bust("test")
	check_eq(s.logistics.aboard, 0, "evidence")
	check_eq(s.logistics.lost.cash, 20000)
	s.dispose()


func test_the_organisations_ai_runs_the_trucks() -> void:
	var s := _sess()
	s.payroll.ai["org"] = true
	s.logistics.cash["camp"] = 9000.0
	s.logistics.add("barn", "cocaine", 60.0)
	_dealer(s, "north")
	s.logistics.update(61.0)
	var views: Array = s.logistics.view().trucks
	check(Py.any(views, func(t): return "cash" in t.what), "cash heading home")
	check(Py.any(views, func(t): return "cocaine" in t.what and "camp" in t.to.to_lower() or "Jungle" in t.to), "product going where the dealer is")
	s.dispose()


func test_off_means_one_pool() -> void:
	var s := _sess({"logistics": false})
	check(s.logistics == null)
	check_eq(s.command(Roles.BOSS, "move_cash", {"from": "camp"})[1], "No logistics in this game: money is money.")
	s.dispose()


func test_guns_are_trucked_to_the_buyer() -> void:
	var s := _sess({"family": true})
	s.family.respect = 60.0
	var ars: Arsenal = s.arsenals["org"]
	ars.add("rifle", 10)
	var have: int = int(ars.stock.rifle)
	var money0 := s.money
	check_eq(s.trade.sell("family", "guns", 4, "rifle"), "", "on the truck to the Morettis")
	check_eq(int(ars.stock.rifle), have - 4, "out of the rack")
	check(s.logistics.view().trucks[0].what.contains("rifle") or s.logistics.view().trucks[0].what.contains("Rifle"), "a truck of rifles")
	var fee := money0 - s.money
	_drive(s)
	check(s.money > money0 - fee + 1000, "the money came back to the club, where the armoury is ($%d)" % (s.money - money0 + fee))
	check(s.trade.bulk_log.size() > 0, "a bulk sale on the books (follow-the-money sees it)")
	s.dispose()


func test_a_seized_gun_truck_arms_the_police() -> void:
	var s := _sess({"family": true})
	s.family.respect = 60.0
	s.arsenals["org"].add("mg", 3)
	var law0: int = s.arsenals["law"].count()
	s.logistics.send_guns("family", {"mg": 3})
	s.stash_net.trucks[0].stop_at = 0.3
	_drive(s, false)
	check(s.arsenals["law"].count() >= law0 + 3, "three machine guns into the police armoury")
	s.dispose()


func test_the_armoury_moves_with_its_guns() -> void:
	var s := _sess()
	var ars: Arsenal = s.arsenals["org"]
	ars.add("rifle", 6)
	var n := ars.count()
	check_eq(s.logistics.armoury_site(), Logistics.HQ, "at the club to start")
	check(s.command(Roles.BOSS, "move_armoury", {"to": "barn"})[0], "ordered")
	check_eq(ars.count(), 0, "on the road: nothing in the rack")
	_drive(s)
	check_eq(ars.count(), n, "all of it arrived")
	check_eq(s.logistics.armoury_site(), "barn", "the armoury is at the barn now")
	check(s.logistics.view().armoury.at.contains("barn"), "and the panel says so")
	s.dispose()


func test_an_escort_rides_with_a_truck() -> void:
	var s := _sess({"ground_war": true})
	s.ground._started = true
	for f in s.ground.commanders:
		s.ground.commanders[f].ai = false
	var sq = s.ground.recruit("org", "car", Vector2(-700, -3350), false)
	check(sq is GroundWar.Squad, "a squad of ours")
	s.logistics.cash["barn"] = 9000.0
	s.logistics.send("barn", Logistics.HQ, "cash", 9000.0)
	var id: int = s.stash_net.trucks[0].job_id
	var r: Array = s.command(Roles.PILOT, "escort_truck", {"job_id": id})
	check(r[0], str(r[1]))
	check_eq(int(sq.order.get("job_id", -1)), id, "the squad rides with it")
	check(s.logistics.view().trucks[0].escort, "the panel shows it escorted")
	check_eq(s.command(Roles.PILOT, "escort_truck", {"job_id": id})[1], "It already has an escort.")
	s.dispose()


func test_the_maps_know_what_a_truck_carries() -> void:
	var s := _sess({"family": true})
	s.family.respect = 60.0
	s.logistics.cash["barn"] = 5000.0
	s.logistics.add("lockup", "marijuana", 200.0)
	s.logistics.send("barn", Logistics.HQ, "cash", 5000.0)
	s.logistics.send("lockup", "family", "marijuana", 100.0)
	var snap := Snapshot.build(s, Roles.BOSS)
	var kinds: Array = snap.trucks.map(func(t): return t.kind)
	check("cash" in kinds and "buyer" in kinds, "cash and a buyer's lot (%s)" % str(kinds))
	check(snap.trucks.all(func(t): return t.has("tx")), "each with where it's going")
	s.dispose()


func test_the_company_collects_at_the_nearest_strip() -> void:
	var s := _sess({"agency": true})
	s.arsenals["org"].add("rifle", 6)
	var mp: Vector2 = s.logistics.meet_pos("agency", s.logistics.armoury_site())
	var club: Vector2 = s.logistics.hq_pos()
	var hangar: Vector2 = s.logistics.pos("agency")
	check(mp.distance_to(club) < hangar.distance_to(club), "its plane lands nearer than the hangar up north (%d m vs %d m)" % [int(mp.distance_to(club)), int(hangar.distance_to(club))])
	var af = Py.first(s.world.airfields, func(a): return Vector2(a.x, a.y).distance_to(mp) < 1.0)
	check(af != null and not af.police, "at a strip, and not a police one")
	check_eq(s.logistics.send_guns("agency", {"rifle": 4}), "", "four rifles out to the plane")
	var t = s.stash_net.trucks[0]
	check(Vector2(t.x1, t.y1).distance_to(mp) < 1.0, "the truck drives to the strip")
	s.dispose()


func test_a_trucked_gun_sale_still_moves_the_contra_pipeline() -> void:
	var s := _sess({"agency": true})
	var a = s.agency
	a.war_chest = 50000.0
	var trust0: float = a.trust
	var chest0: float = a.war_chest
	s.arsenals["org"].add("rifle", 6)
	check_eq(s.trade.sell("agency", "guns", 4, "rifle"), "", "rifles out to the Company's plane")
	check_near(a.trust, trust0, 0.001, "nothing happens until the plane has them")
	for i in 1500:
		for t in s.stash_net.trucks:
			t.stop_at = -1.0
		s.time += 5.0
		s._update_stashes(5.0)
		if s.trade.bulk_log.size() > 0:
			break
	check(a.trust > trust0, "the Company trusts us more (%.1f -> %.1f)" % [trust0, a.trust])
	check(a.war_chest < chest0, "and its war chest paid for the guns")
	s.dispose()


func _island_sess() -> Session:
	var s := _sess({"island": true})
	s.trade.connected = true
	s.money = 200000
	return s


func test_an_island_container_lands_in_the_docks_warehouse() -> void:
	var s := _island_sess()
	var money0 := s.money
	var sh := {"id": "S1", "method": "ship", "n": 1, "lb": 500.0, "cost": 0, "value": 27500, "eta": s.time, "p": 0.0}
	s.island.inspections_until = -1.0
	s.island.port_heat = 0.0
	# force it through customs: odds floor is 2%, so seed-check the outcome
	var cleared := false
	for i in 20:
		var before: float = s.logistics.stock.docks.cocaine
		s.island._resolve(sh)
		if s.logistics.stock.docks.cocaine > before:
			cleared = true
			break
	check(cleared, "a container cleared customs")
	check_near(fmod(s.logistics.stock.docks.cocaine, 500.0), 0.0, 0.01, "500 lb into Warehouse 7")
	check_eq(s.money, money0, "no instant cash: it has to be sold")
	s.dispose()


func test_island_mules_land_by_the_airport_or_the_nearest_stash() -> void:
	var s := _island_sess()
	s.stash_net.get_stash("docks").burned = true
	var sh := {"id": "M1", "method": "mules", "n": 4, "lb": 4 * 2.2046, "cost": 0, "value": 4 * 2600, "eta": s.time, "p": 0.0, "mules": []}
	var money0 := s.money
	s.island._resolve(sh)
	check_near(s.logistics.stock.docks.cocaine, 0.0, 0.01, "not into a burned warehouse")
	check(s.trade.stock.cocaine > 0.0 or s.island.caught >= 4, "the swallowers' kilos went into another stash")
	check_eq(s.money, money0, "and no instant cash")
	s.dispose()


func test_without_logistics_the_island_still_pays_cash() -> void:
	var s := _sess({"island": true, "logistics": false})
	var money0 := s.money
	var sh := {"id": "M1", "method": "mules", "n": 4, "lb": 4 * 2.2046, "cost": 0, "value": 4 * 2600, "eta": s.time, "p": 0.0, "mules": []}
	s.island._resolve(sh)
	check(s.money > money0 or s.island.caught >= 4, "cash at the street price, as before")
	s.dispose()
