extends TestCase
## The Chronicle: random breaks and bad luck for the three outfits, and
## milestones that fire once, each changing something real and making the news.


func after_each() -> void:
	World.use_map(0)


func _sess(seed := 3, ground := true) -> Session:
	var s := Session.new({"seed": seed, "map_seed": MapCity.SEED, "location": "QRY",
		"features": Session.SANDBOX_FEATURES, "ground_war": ground, "chronicle": true})
	s.police.frozen = true
	if s.ground != null:
		s.ground._started = true
		for f in s.ground.commanders:
			s.ground.commanders[f].ai = false
	s.update(1.0 / 30)
	return s


func test_every_event_applies_and_makes_the_news() -> void:
	var s := _sess()
	s.ground.recruit("org", "foot", null, false)
	s.ground.recruit("police", "car", null, false)
	s.ground.recruit("rival", "foot", null, false)
	for id in Chronicle.EVENTS:
		var n0: int = s.chronicle.entries.size()
		var text: String = s.chronicle.fire(id)
		check(text != "" and not "{" in text, "%s: '%s'" % [id, text])
		check_eq(s.chronicle.entries.size(), n0 + 1, id + " is in the chronicle")
	s.dispose()


func test_events_change_real_state() -> void:
	var s := _sess()
	var m0 := s.money
	s.chronicle.fire("windfall")
	check(s.money > m0, "a windfall pays")
	var f0 := s.law_funds
	s.chronicle.fire("federal_grant")
	check(s.law_funds > f0, "a grant funds the task force")
	var r0: int = s.arsenals.org.stock.rifle
	s.chronicle.fire("surplus_rifles")
	check(s.arsenals.org.stock.rifle > r0, "rifles in the armoury")
	var law_r: int = s.arsenals.law.stock.rifle
	var riv_r: int = s.arsenals.rival.stock.rifle
	s.chronicle.fire("evidence_theft")
	check(s.arsenals.law.stock.rifle < law_r and s.arsenals.rival.stock.rifle > riv_r, "the evidence room's guns end up with Los Cuervos")
	var c = s.police.case("runner")
	c.suspicion = 50.0
	s.chronicle.fire("cop_payroll")
	check(c.suspicion < 50.0, "a cop on the payroll cools the case")
	var hot: Dictionary = Py.max_by(s.stash_net.live(), func(st): return StashNet.suspicion(st))
	var i0 := StashNet.suspicion(hot)
	s.chronicle.fire("snitch")
	check(StashNet.suspicion(hot) > i0, "a snitch in the crew: the police hear about a house")
	s.dispose()


func test_private_news_stays_on_its_side() -> void:
	var s := _sess()
	s.chronicle.fire("cop_payroll")  # the organisation's secret
	s.chronicle.fire("informant_turned")  # the task force's
	s.chronicle.fire("budget_cut")  # everyone reads the paper
	var runner: Array = Snapshot.build(s, Roles.COPILOT).chronicle.news.map(func(n): return n.text)
	var law: Array = Snapshot.build(s, Roles.CONTROLLER).chronicle.news.map(func(n): return n.text)
	check(runner.any(func(t): return "envelope" in t) and not law.any(func(t): return "envelope" in t), "the payroll cop is our secret")
	check(law.any(func(t): return "informant" in t) and not runner.any(func(t): return "informant" in t), "the informant is theirs")
	check(runner.any(func(t): return "budget" in t) and law.any(func(t): return "budget" in t), "the budget cut is in the papers")
	check(law.any(func(t): return t.contains(":")), "with an outlet's name")
	s.dispose()


func test_milestones_fire_once() -> void:
	var s := _sess()
	s.money = 60000
	var c = s.police.case("runner")
	var h0: float = c.suspicion
	s.update(1.1)
	check(s.chronicle.fired.has("rich_50k"), "flash money makes the papers")
	check(c.suspicion > h0, "and brings heat")
	var n := s.chronicle.entries.size()
	for i in 5:
		s.update(1.1)
	check_eq(s.chronicle.entries.filter(func(e): return "Testarossa" in e[4]).size(), 1, "once")
	# the first delivery, from the bus
	s.bus.emit("job_delivered", s.time, "", ["runner"], {"job_id": 1, "pay": 100, "dest": "FRM", "hot": false})
	s.update(1.1)
	check(s.chronicle.fired.has("first_delivery"), "a new name on the street")
	# a burned stash
	s.stash_net.stashes[0].burned = true
	s.update(1.1)
	check(s.chronicle.fired.has("stash_burned"), "a raid on the evening news")
	check(s.chronicle.entries.back()[4].contains(s.stash_net.stashes[0].name), "naming the house")
	check(n >= 1, "")
	s.dispose()


func test_the_random_clock() -> void:
	var s := _sess(5)
	var t := 0
	for i in 3 * 3600:  # three hours
		s.chronicle.update(1.0)
	t = s.chronicle.entries.size()
	check(t >= 10 and t <= 45, "about one story every eight minutes (%d in 3 h)" % t)
	var sides := {}
	for e in s.chronicle.entries:
		sides[e[1]] = true
	check(sides.size() == 3, "for all three outfits")
	s.dispose()


func test_the_same_seed_writes_the_same_news() -> void:
	var a := _sess(9)
	var b := _sess(9)
	for i in 3600:
		a.chronicle.update(1.0)
		b.chronicle.update(1.0)
	check_eq(a.chronicle.entries.map(func(e): return e[4]), b.chronicle.entries.map(func(e): return e[4]), "deterministic")
	a.dispose()
	b.dispose()


func test_without_a_ground_war_the_squad_events_are_skipped() -> void:
	var s := _sess(3, false)
	check(not s.chronicle._can("rival_recruits"), "no crews to hire without the ground war")
	for i in 40:
		s.chronicle.random_event()  # must not crash on missing squads
	check(true, "ok")
	s.dispose()


func test_off_means_silent() -> void:
	Chronicle.ENABLED = false
	var s := _sess()
	check(s.chronicle == null, "no chronicle")
	s.dispose()
	Chronicle.ENABLED = true
