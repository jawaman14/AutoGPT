extends TestCase
## The outfits' payrolls: hiring, paydays and loyalty; the disloyal; soldiers
## for the ground war, drivers for the trucks, mules for the island, lookouts
## at the stash houses, the accountant; the arrested and their cases; contract
## pilots; Los Cuervos doing all of it too; the hiring hall's conversation.


func after_each() -> void:
	World.use_map(0)


func _sess(opts := {}) -> Session:
	var o := {"seed": 12, "map_seed": MapCity.SEED, "location": "HAR", "features": Session.SANDBOX_FEATURES, "payroll": true}
	o.merge(opts, true)
	var s := Session.new(o)
	s.police.frozen = true
	s.payroll.ai["org"] = false
	s.payroll.ai["rival"] = false
	if s.ground != null:
		s.ground._started = true
		for f in s.ground.commanders:
			s.ground.commanders[f].ai = false
	s.update(1.0 / 30)
	return s


## Hire `n` of `role` for the organisation (candidates made to order).
func _hire(s: Session, role: String, n: int, loyalty := 0.8, skill := 0.6) -> Array:
	var ids := []
	for i in n:
		var w: Dictionary = s.payroll._person("org", role)
		w.loyalty = loyalty
		w.skill = skill
		s.payroll.candidates.org.append(w)
		check_eq(s.payroll.hire("org", w.id), "", "hired a %s" % role)
		ids.append(w.id)
	return ids


func test_hire_pay_and_loyalty() -> void:
	var s := _sess()
	s.money = 10000
	check_eq(s.payroll.candidates.org.size(), Payroll.CANDIDATES, "a hall full of candidates")
	var c: Dictionary = s.payroll.candidates.org[0]
	var m0 := s.money
	check(s.command(Roles.BOSS, "hire_worker", {"id": c.id})[0], "the boss hires")
	check_eq(s.money, m0 - int(c.wage) * 2, "a signing fee: two wages")
	var l0: float = s.payroll.get_worker(c.id).loyalty
	var m1 := s.money
	s.payroll._payday()
	check_eq(s.money, m1 - int(c.wage), "payday")
	check(s.payroll.get_worker(c.id).loyalty > l0, "paid: a little more loyal")
	s.money = 0
	s.payroll._payday()
	check(s.payroll.get_worker(c.id).loyalty < l0 - 0.2 or s.payroll.get_worker(c.id) == null, "unpaid: much less")
	check(s.payroll.unpaid.org > 0, "and it shows")
	s.dispose()


func test_the_disloyal_skim_walk_or_talk() -> void:
	var s := _sess()
	s.money = 1000000
	var what := {}
	for i in 200:
		var ids := _hire(s, "soldier", 1, 0.1)
		var w = s.payroll.get_worker(ids[0])
		var m0 := s.money
		var sus := s.police.case("runner").suspicion
		s.payroll._disloyal("org", w)
		if s.money < m0:
			what["skim"] = true
		elif s.payroll.get_worker(ids[0]) == null:
			what["walk"] = true
		elif s.police.case("runner").suspicion > sus:
			what["talk"] = true
	check_eq(what.size(), 3, "all three happen: %s" % [what.keys()])
	s.dispose()


func test_squads_need_soldiers_on_the_payroll() -> void:
	var s := _sess({"ground_war": true})
	s.money = 100000
	var q = s.ground.recruit("org", "foot", null)
	check(q is String and "payroll" in q, "no soldiers, no squad: %s" % [q])
	_hire(s, "soldier", 4)
	q = s.ground.recruit("org", "foot", null)
	check(q is GroundWar.Squad, "four soldiers: a squad")
	check_eq(s.payroll.of("org", "soldier", "assigned").size(), 4, "all on the street")
	# two men lost in a fight: arrested or dead
	q.men = 2
	s.payroll._reconcile_squads()
	check_eq(s.payroll.of("org", "soldier", "assigned").size(), 2, "two left")
	check_eq(s.payroll.lost.org, 2, "two lost")
	s.ground.disband(q)
	s.payroll._reconcile_squads()
	check_eq(s.payroll.of("org", "soldier", "free").size(), 2, "the survivors come home")
	check(s.ground.recruit("org", "foot", null, false) is GroundWar.Squad, "a free crew (an event, the Family's) needs nobody")
	s.dispose()


func test_drivers_trucks_and_the_street_driver() -> void:
	var s := _sess()
	s.money = 100000
	var d: Array = s.payroll.driver_for("1")
	check(d[0] != "" and s.payroll.get_worker(d[0]).street, "no driver hired: a day driver off the street")
	var m0 := s.money
	_hire(s, "driver", 1, 0.9, 1.0)
	var waved := 0
	for i in 200:
		var r: Array = s.payroll.driver_for(str(i + 2))
		waved += int(r[1])
		s.payroll.release([r[0]])
	check(waved > 40 and waved < 120, "a sharp driver talks his way past about 40%% of the time (%d/200)" % waved)
	s.dispose()


func test_mules_come_off_the_payroll_and_the_caught_are_arrested() -> void:
	var s := _sess({"island": true})
	s.money = 1000000
	_hire(s, "mule", 4, 0.9, 0.9)
	check_eq(s.island.ship("mules", 4), "", "four mules on the airliner")
	check_eq(s.payroll.of("org", "mule", "assigned").size(), 4, "our four")
	s.island.airport_heat = 100.0
	for id in Island.LAW_NODES:
		s.upgrades.law[id] = true
	s.island.crackdown_until = s.time + 9999.0
	s.time += Island.MULE_ETA_S + 1.0
	s.island.update(10.0)
	var caught := s.payroll.jail.size()
	check_eq(s.payroll.of("org", "mule", "free").size() + caught, 4, "home, or in custody")
	check(caught > 0, "some caught in a crackdown (%d)" % caught)
	s.dispose()


func test_a_lookout_saves_the_stash() -> void:
	var s := _sess()
	s.money = 100000
	var saved := 0
	for i in 40:
		var ids := _hire(s, "lookout", 1, 0.9, 0.9)
		var st: Dictionary = s.stash_net.live()[0]
		st.burned = false
		st.heat = 80.0
		check_eq(s.payroll.post_lookout(ids[0], st.id), "", "posted")
		s._raid(st.id)
		if not st.burned:
			saved += 1
		st.burned = false
		s.payroll.get_worker(ids[0]).status = "gone"
		s.payroll.workers.erase(s.payroll.get_worker(ids[0]))
	check(saved > 20, "a good lookout usually sees them coming (%d/40)" % saved)
	s.dispose()


func test_the_jail_lawyers_deals_and_flips() -> void:
	var rate := func(lawyer: bool, deal: bool) -> float:
		var s := _sess()
		s.money = 10000000
		s.law_funds = 10000000.0
		var flipped := 0
		for i in 150:
			var ids := _hire(s, "accountant", 1, 0.3)
			s.payroll.lose(ids[0], "arrested")
			if lawyer:
				s.payroll.pay_lawyer("org", ids[0])
			if deal:
				s.payroll.offer_deal(ids[0])
			var f0: int = s.payroll.flips.org
			s.time += Payroll.JAIL_S + 1.0
			s.payroll._trials()
			flipped += s.payroll.flips.org - f0
		s.dispose()
		return flipped / 150.0
	var plain: float = rate.call(false, false)
	var lawyered: float = rate.call(true, false)
	var dealt: float = rate.call(false, true)
	check(lawyered < plain and plain < dealt, "a lawyer keeps them quiet, a deal loosens tongues (%.2f < %.2f < %.2f)" % [lawyered, plain, dealt])


func test_a_flip_costs_the_outfit() -> void:
	var s := _sess({"ground_war": true})
	s.money = 100000
	var st: Dictionary = s.stash_net.live()[0]
	var i0 := Py.sum_by(s.stash_net.live(), func(x): return float(x.intel))
	var w: Dictionary = s.payroll._person("org", "accountant")
	s.payroll._tip("org", w, "a test")
	check(Py.sum_by(s.stash_net.live(), func(x): return float(x.intel)) > i0, "the organisation: a stash house named")
	var c0: float = s.ground.commanders.rival.cash
	s.payroll._tip("rival", s.payroll._person("rival", "driver"), "a test")
	check(s.ground.commanders.rival.cash < c0, "Los Cuervos: cash seized")
	s.dispose()


func test_contract_pilots_fly_runs() -> void:
	var s := _sess()
	s.money = 100000
	_hire(s, "pilot", 3, 0.9, 0.9)
	var m0 := s.money
	for i in 12:
		s.time += 1201.0
		s.payroll._pilot_runs()
	check(s.money > m0 or s.payroll.lost.org > 0, "runs flown")
	check(s.payroll.lost.org < 3 * 12, "")
	s.dispose()


func test_the_accountant_cleans_or_skims() -> void:
	var s := _sess()
	s.money = 100000
	var good := _hire(s, "accountant", 1, 0.95, 0.9)
	s.police.case("runner").suspicion = 50.0
	s.payroll._accountant("org")
	check(s.police.case("runner").suspicion < 50.0, "clean books: the case cools")
	s.payroll.get_worker(good[0]).loyalty = 0.1
	var skimmed := false
	for i in 40:
		var m0 := s.money
		s.payroll._accountant("org")
		skimmed = skimmed or s.money < m0
	check(skimmed, "a sour accountant skims")
	s.dispose()


func test_the_ai_runs_both_payrolls() -> void:
	var s := _sess({"ground_war": true, "island": true})
	s.payroll.ai["org"] = true
	s.payroll.ai["rival"] = true
	s.money = 80000
	s.ground.commanders.rival.cash = 60000.0
	for i in 12:
		s.payroll._refresh("org")
		s.payroll._refresh("rival")
		s.payroll._think("org")
		s.payroll._think("rival")
	var roles := {}
	for w in s.payroll.of("org"):
		roles[w.role] = true
	check(roles.has("soldier") and roles.has("driver") and roles.has("mule") and roles.has("lookout"), "the organisation hires to its needs: %s" % [roles.keys()])
	check(s.payroll.of("org", "lookout", "assigned").size() > 0, "and posts its lookouts")
	check(s.payroll.of("rival", "soldier").size() > 0, "Los Cuervos hire soldiers too")
	var rc: float = s.ground.commanders.rival.cash
	s.payroll._payday()
	check(s.ground.commanders.rival.cash < rc, "and pay them from the cartel's cash")
	s.dispose()


func test_los_cuervos_trade_with_the_island() -> void:
	var s := _sess({"ground_war": true, "island": true})
	s.ground.commanders.rival.cash = 1000000.0
	for i in 30:
		s.island._rival_trade()
	check_eq(s.island.rival_shipped, 30, "a container at a time")
	check(s.island.rival_caught > 0 and s.island.rival_caught < 15, "customs catch some (%d)" % s.island.rival_caught)
	s.dispose()


func test_the_hiring_hall() -> void:
	var s := _sess()
	s.money = 50000
	var n0 := s.payroll.of("org").size()
	var b := TalkBalloon.new()
	Engine.get_main_loop().root.add_child(b)
	await b.start(Talk.resource("crew"), "start", Talk.State.new(func(): return LocalLink.new(s, Roles.PILOT, false).snapshot(),
		func(n: String, a: Dictionary) -> Array: return s.command(Roles.PILOT, n, a)))
	for i in 6:
		if not b._answers.is_empty():
			break
		await b.advance()
	var answers: Array = b._answers.map(func(r): return str(r.text))
	check(answers.filter(func(a): return a.begins_with("Hire ")).size() == 4, "four candidates, with their hints: %s" % [answers])
	await b.choose(0)
	check_eq(s.payroll.of("org").size(), n0 + 1, "hired through the talk")
	b.queue_free()
	s.dispose()


func test_off_means_no_payroll() -> void:
	Payroll.ENABLED = false
	var s := Session.new({"seed": 12, "map_seed": MapCity.SEED, "location": "HAR", "payroll": true, "ground_war": true})
	check(s.payroll == null, "no payroll")
	s.money = 100000
	s.ground._started = true
	check(s.ground.recruit("org", "foot", null) is GroundWar.Squad, "squads as before")
	s.dispose()
	Payroll.ENABLED = true
