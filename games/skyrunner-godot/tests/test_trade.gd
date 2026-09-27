extends TestCase
## The product business (Trade): our own loads into the stash, dealers on the
## corners, bulk buyers (the Morettis, the Company, Los Cuervos for guns) and
## what each sale does to the markets and the wars; grass first and the
## Colombian connection later; the law's sweeps and following the money.


func after_each() -> void:
	World.use_map(0)
	Trade.ENABLED = true


func _sess(opts := {}) -> Session:
	var o := {"seed": 21, "map_seed": MapCity.SEED, "location": "FRM", "features": Session.SANDBOX_FEATURES, "trade": true, "payroll": true}
	o.merge(opts, true)
	var s := Session.new(o)
	s.police.frozen = true
	if s.payroll != null:
		s.payroll.ai["org"] = false
		s.payroll.ai["rival"] = false
	if s.ground != null:
		s.ground._started = true
		for f in s.ground.commanders:
			s.ground.commanders[f].ai = false
	s.update(1.0 / 30)
	return s


func _hire_dealers(s: Session, o: String, n: int, skill := 0.7) -> Array:
	var ids := []
	for i in n:
		var w: Dictionary = s.payroll._person(o, "dealer")
		w.skill = skill
		w.loyalty = 0.9
		s.payroll.candidates[o].append(w)
		s.payroll.hire(o, w.id)
		ids.append(w.id)
	return ids


func test_own_grass_into_the_stash() -> void:
	var s := _sess()
	s.money = 20000
	s.refresh_board("FRM")
	var j = Py.first(s.boards["FRM"], func(x): return x.own_good == "marijuana")
	check(j != null, "our own grass on the farm strip's board")
	check(j.cost > 0 and j.payout == 0, "bought, not paid for: $%d up front" % j.cost)
	var lb := Py.sum_by(j.items, func(i): return i.weight_lb)
	check(lb > 150.0, "bulky: %d lb" % int(lb))
	check(j.cost < lb * 3.0, "and cheap ($%.2f a pound)" % (j.cost / lb))
	var m0 := s.money
	s.trade.delivered(j)
	check_near(s.trade.stock.marijuana, lb, 1e-6, "delivered: into the stash")
	check_eq(s.money, m0, "no pay - it's ours to sell")
	s.dispose()


func test_the_career_starts_with_grass() -> void:
	var s := _sess({"career": true, "island": true})
	check(not s.trade.connected, "no cocaine connection at the start")
	for code in ["QRY", "MGR", "FRM", "EGL", "COV"]:
		if World.AIRFIELD_BY_CODE.has(code):
			s.refresh_board(code)
			check(not s.boards[code].any(func(j): return Economy.good_of(j) == "cocaine"), "no cocaine work at %s yet" % code)
	s.money = 100000
	check(s.island.ship("mules", 2).begins_with("The General"), "nor the island")
	s.trade.stock.marijuana = 2000.0
	for i in 8:
		s.trade.appetite.family.marijuana = 600.0
		if s.family != null:
			s.trade.sell("family", "marijuana", 600.0)
	if s.family == null:
		s.trade.sold.marijuana = Trade.CONNECT_LB
		s.trade._check_connection()
	check(s.trade.connected, "grass moved: the Colombians call")
	check(s.messages.any(func(m): return "Colombians" in m[1]), "and the news says so")
	s.dispose()


func test_moving_weight_brings_the_call_even_when_the_corners_are_slow() -> void:
	var s := _sess({"career": true})
	s.trade.landed.marijuana = Trade.CONNECT_MOVED - 1.0
	s.trade._check_connection()
	check(not s.trade.connected, "not quite two tons yet")
	s.trade.landed.marijuana = Trade.CONNECT_MOVED
	s.trade._check_connection()
	check(s.trade.connected, "a pilot who moves weight gets the call, sold or not")
	check_near(s.trade.sold.marijuana, 0.0, 0.01, "nothing had to be sold")
	s.dispose()


func test_dealers_work_the_corners() -> void:
	var s := _sess()
	s.trade.stock.cocaine = 200.0
	var ids := _hire_dealers(s, "org", 3)
	var m0 := s.money
	var sup0 := {}
	for m in Economy.MARKETS:
		sup0[m] = s.econ.market.supply.cocaine[m]
	for i in 10:
		s.trade.update(60.0)
	check_eq(s.payroll.of("org", "dealer", "assigned").size() + s.payroll.jail.size(), 3, "all three on a corner (or picked up)")
	check(s.trade.stock.cocaine < 190.0, "product moved: %d lb left" % int(s.trade.stock.cocaine))
	check(s.money > m0 + 150, "and the money came in (+$%d)" % (s.money - m0))
	var corner := str(s.payroll.get_worker(ids[0]).assigned).trim_prefix("corner-") if s.payroll.get_worker(ids[0]) != null else "town"
	check(s.econ.market.supply.cocaine[corner] > sup0[corner], "our sales put product on the %s's street" % corner)
	check(s.trade.view("runner").corners[corner].ours >= 1, "the desk sees our corner")
	s.dispose()


func test_competition_and_arrests_on_the_corners() -> void:
	var take := func(rivals: int) -> float:
		var s := _sess({"ground_war": true})
		s.trade.stock.cocaine = 500.0
		_hire_dealers(s, "org", 2)
		s.trade.update(60.0)
		var m: String = str(s.payroll.of("org", "dealer", "assigned")[0].assigned).trim_prefix("corner-")
		for w in _hire_dealers(s, "rival", rivals).map(func(id): return s.payroll.get_worker(id)):
			w.status = "assigned"
			w.assigned = "corner-" + m
		var before: float = s.trade.stock.cocaine
		for i in 10:
			s.trade.update(60.0)
		var sold: float = before - s.trade.stock.cocaine
		s.dispose()
		return sold
	var alone: float = take.call(0)
	var crowded: float = take.call(4)
	check(crowded < alone * 0.8, "Los Cuervos on the same corners: we sell less (%.1f vs %.1f lb)" % [crowded, alone])
	# the police pick dealers up
	var s := _sess()
	s.trade.stock.marijuana = 100000.0
	_hire_dealers(s, "org", 6)
	for m in Economy.MARKETS:
		s.econ.heat[m] = 1.5
	for i in 180:
		s.trade.update(60.0)
	check(s.payroll.jail.size() + s.payroll.lost.org > 0, "three hours on hot corners: dealers arrested (%d)" % (s.payroll.jail.size() + s.payroll.lost.org))
	s.dispose()


func test_bulk_buyers_and_what_their_buying_does() -> void:
	var s := _sess({"family": true, "agency": true, "ground_war": true})
	s.trade.connected = true
	s.trade.stock.cocaine = 300.0
	s.trade.stock.marijuana = 1000.0
	# the Morettis: a bulk discount, and it floods the town
	var q := s.trade.quote("family", "cocaine")
	check(q.why == "" and q.price < s.trade.street_price("cocaine", "town"), "the Family pays under the street ($%d a lb)" % int(q.price))
	var town0: float = s.econ.market.supply.cocaine.town
	var r0: float = s.family.respect
	var m0 := s.money
	check_eq(s.trade.sell("family", "cocaine", 30.0), "", "sold to the Morettis")
	check(s.money > m0 and s.trade.stock.cocaine < 300.0, "paid, and out of the stash")
	check(s.econ.market.supply.cocaine.town > town0, "they sell it on in town: more on its street")
	check(s.family.respect > r0, "and they like us better")
	check(s.trade.sell("family", "cocaine", 30.0) != "" or s.trade.appetite.family.cocaine < 11.0, "they only take so much at once")
	# the Company: cocaine for its pipeline
	var chest: float = s.agency.war_chest
	check_eq(s.trade.sell("agency", "cocaine", 60.0), "", "sold to the Company")
	check(s.agency.war_chest > chest and s.agency.extra_lots >= 1, "into its pipeline: a bigger load north next time")
	# no deal when the Family's gone cold
	s.family.respect = 10.0
	check(s.trade.sell("family", "marijuana", 100.0).begins_with("The Morettis won't"), "respect too low: no deal")
	s.dispose()


func test_guns_arm_the_wars() -> void:
	var s := _sess({"family": true, "agency": true, "ground_war": true})
	s.arsenals.org.add("rifle", 40)
	# to Los Cuervos: they fight better - us included - and it's noticed
	var r0: int = s.arsenals.rival.stock.rifle
	var sus: float = s.police.case("runner").suspicion
	s.ground.commanders.rival.cash = 100000.0
	check_eq(s.trade.sell("rival", "guns", 10.0), "", "rifles to Los Cuervos")
	check_eq(s.arsenals.rival.stock.rifle, r0 + 10, "their armoury grows")
	check(s.police.case("runner").suspicion > sus, "guns to a gang get noticed")
	# to the Morettis: they go after Los Cuervos
	var cash: float = s.ground.commanders.rival.cash
	check_eq(s.trade.sell("family", "guns", 10.0), "", "rifles to the Family")
	check(s.ground.commanders.rival.cash < cash, "and Los Cuervos pay for it")
	# to the Company: south, out of circulation - scarcer and dearer here
	var src: float = s.econ.market.source.guns
	var p := s.trade.quote("agency", "guns")
	check(p.price > s.trade.quote("family", "guns").price, "the Company pays a premium for the war down south")
	check_eq(s.trade.sell("agency", "guns", 15.0), "", "rifles to the Company")
	check(s.econ.market.source.guns < src, "guns leave the island: scarcer here")
	s.dispose()


func test_the_street_war_hits_the_corners() -> void:
	var s := _sess({"ground_war": true})
	s.trade.stock.cocaine = 1000.0
	_hire_dealers(s, "org", 4)
	s.trade.update(60.0)
	var m: String = str(s.payroll.of("org", "dealer", "assigned")[0].assigned).trim_prefix("corner-")
	var c: Array = Economy.centre(m)
	var a = s.ground.recruit("org", "foot", Vector2(c[0], c[1]), false)
	var b = s.ground.recruit("rival", "foot", Vector2(c[0] + 40, c[1]), false)
	s.ground._open(a, b)
	var here0 := s.trade.dealers("org", m).size()
	for i in 60:
		s.trade.update(60.0)
		if s.ground.fights.is_empty():
			break
	check(s.trade.dealers("org", m).size() < here0 or s.payroll.lost.org > 0, "a gunfight on our corners costs us dealers")
	# Los Cuervos come for corners where we sell (where they're strong)
	var s2 := _sess({"ground_war": true})
	s2.trade.stock.cocaine = 1000.0
	for w in _hire_dealers(s2, "org", 3).map(func(id): return s2.payroll.get_worker(id)):
		w.status = "assigned"
		w.assigned = "corner-west"
	s2.ground.control.west = {"org": 10.0, "rival": 30.0, "police": 0.0}
	s2.ground.commanders.rival.ai = true
	s2.ground.recruit("rival", "foot", null, false)
	s2.trade._war_t = 600.0
	s2.trade._street_war(0.0)
	check(s2.messages.any(func(x): return "coming for our corners" in x[1]), "Los Cuervos move on our corners in the west")
	s.dispose()
	s2.dispose()


func test_a_raid_takes_part_of_the_stash() -> void:
	var s := _sess()
	s.trade.stock.cocaine = 100.0
	s.trade.stock.marijuana = 1000.0
	var st: Dictionary = s.stash_net.stashes[0]
	st.heat = 90.0
	s._raid(st.id)
	check_near(s.trade.stock.cocaine, 70.0, 1e-6, "30% of the cocaine to evidence")
	check_near(s.trade.stock.marijuana, 700.0, 1e-6, "and the grass")
	s.dispose()


func test_the_law_sweeps_and_follows_the_money() -> void:
	var s := _sess({"agency": true, "family": true})
	s.trade.connected = true
	s.trade.stock.cocaine = 500.0
	_hire_dealers(s, "org", 6)
	s.trade.update(60.0)
	var m: String = str(s.payroll.of("org", "dealer", "assigned")[0].assigned).trim_prefix("corner-")
	s.law_funds = 50000.0
	var here := s.trade.dealers("org", m).size()
	var ok := false
	for i in 4:
		s.command(Roles.CHIEF, "street_sweep", {"market": m})
	check(s.trade.dealers("org", m).size() < here, "a sweep picks up dealers (%d -> %d)" % [here, s.trade.dealers("org", m).size()])
	check(s.econ.market.disruption[m] > 0.2, "and breaks the corner")
	# following the money
	s.agency.prng = Session._rng(9)
	s.agency._pipe_t = Agency.PIPE_S
	s.agency._pipeline(0.0)
	s.trade.sell("agency", "cocaine", 40.0)
	var e0: float = s.agency.exposure
	var chest: float = s.agency.war_chest
	var sus: float = s.police.case("runner").suspicion
	var r := s.command(Roles.CONTROLLER, "trace_money")
	check(r[0], "the controller follows the money")
	check(s.agency.exposure > e0 and s.agency.war_chest < chest, "the Company's pipeline: exposure up, part of its war chest forfeited")
	check(s.police.case("runner").suspicion > sus, "and our bulk sale is in the trail")
	check(s.law_log.any(func(x): return "next load lands in the" in x[1]), "the task force learns where the next load lands")
	s.dispose()


func test_the_buyers_talk() -> void:
	var s := _sess({"family": true})
	s.trade.stock.marijuana = 500.0
	var b := TalkBalloon.new()
	Engine.get_main_loop().root.add_child(b)
	await b.start(Talk.resource("buyers"), "start", Talk.State.new(func(): return LocalLink.new(s, Roles.PILOT, false).snapshot(),
		func(n: String, a: Dictionary) -> Array: return s.command(Roles.PILOT, n, a)))
	for i in 6:
		if not b._answers.is_empty():
			break
		await b.advance()
	var answers: Array = b._answers.map(func(r): return str(r.text))
	check(answers.any(func(a): return a.begins_with("Sell the Morettis 200 lb of grass")), "the Morettis will take grass: %s" % [answers])
	var m0 := s.money
	await b.choose(answers.find(answers.filter(func(a): return a.begins_with("Sell the Morettis 200 lb of grass"))[0]))
	check(s.money > m0 and s.trade.stock.marijuana < 500.0, "sold through the talk")
	b.queue_free()
	s.dispose()


func test_off_means_no_trade() -> void:
	Trade.ENABLED = false
	var s := Session.new({"seed": 21, "map_seed": MapCity.SEED, "location": "FRM", "trade": true, "payroll": true})
	check(s.trade == null, "no trade")
	for i in 20:
		s.payroll._refresh("org")
		check(not s.payroll.candidates.org.any(func(w): return w.role == "dealer"), "and no dealers in the hall")
	s.dispose()
	Trade.ENABLED = true
