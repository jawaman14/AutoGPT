extends TestCase
## HQ season rules and seat plans. Ported from tests/test_hq.py (the strategic
## simulator's checks live with the balance tooling).


static func _season(rules := {}) -> HQ.Season:
	var r := PyRandom.new()
	r.seed(1)
	return HQ.Season.new(r, rules)


func test_laundering_is_capped_by_fronts_and_costs_a_fee() -> void:
	var ss := _season({"start_dirty": 50000})
	var cap := ss.org.capacity()
	check(ss.runner_cmd("launder") == null)
	check_eq(ss.org.laundered_tonight, cap)
	check(0.85 * cap <= ss.org.clean and ss.org.clean < cap, "10% fee on a laundromat")
	check(ss.runner_cmd("launder") != null, "fronts are full tonight")
	check(ss.runner_cmd("buy_front", {"kind": "car_lot"}) == null)
	check_eq(ss.org.capacity(), cap + HQ.FRONTS["car_lot"][1])


func test_action_points_limit_a_night() -> void:
	var ss := _season({"start_dirty": 100000})
	for i in 3:
		check(ss.runner_cmd("loyalty") == null)
	check_eq(ss.runner_cmd("loyalty"), "No more moves tonight.")
	check(ss.runner_cmd("launder") == null, "free actions still work")


func test_burner_phones_blank_the_wiretap() -> void:
	var ss := _season()
	ss.law.evidence = 30
	ss._begin_planning()
	check(ss.law_cmd("wiretap") == null)
	check(ss.runner_cmd("opsec") == null)
	ss.start_operation()
	var before := ss.law.evidence
	ss.finish_night([])
	check(ss.law.evidence <= before, "decay only, no wiretap gain")


func test_wiretap_needs_a_warrant() -> void:
	check("warrant" in _season().law_cmd("wiretap"))


func test_internal_affairs_finds_bribes_and_turns_them_into_evidence() -> void:
	var found := 0
	for seed in 40:
		var r := PyRandom.new()
		r.seed(seed)
		var ss := HQ.Season.new(r, {"start_dirty": 50000})
		ss.runner_cmd("bribe", {"who": "dispatcher"})
		ss.law_cmd("ia_sweep")
		ss.start_operation()
		ss.finish_night([])
		if not ss.org.bribes.has("dispatcher"):
			found += 1
			check(ss.law.evidence > 5)
	check_between(found, 10, 30, "about half")


func test_bust_builds_evidence_less_with_a_lawyer() -> void:
	var a := _season({"evidence_decay": 0})
	var b := _season({"evidence_decay": 0})
	b.org.lawyer = true
	for ss in [a, b]:
		ss.start_operation()
		ss.finish_night([HQ.RunResult.new("main", "west", {"detected": true, "intercepted": true, "busted": true, "seized_value": 30000})])
	check(a.law.evidence > b.law.evidence and b.law.evidence > 0, "lawyer halves it")
	check(a.law.bank_k > 0, "seizures fund the task force")


func test_win_conditions() -> void:
	var ss := _season({"retire_target": 1000, "start_dirty": 5000})
	ss.runner_cmd("launder")
	ss.start_operation()
	ss.finish_night([])
	check(ss.phase == "over" and ss.winner == "runner" and ss.reason == "retired rich", "retired")
	ss = _season()
	ss.law.evidence = 120
	ss.start_operation()
	ss.finish_night([])
	check(ss.winner == "law" and ss.reason == "boss indicted", "indicted")


func test_comeback_event_fires_once_for_the_trailing_law() -> void:
	var ss := _season({"retire_target": 30000, "start_dirty": 100000, "nights": 20})
	for night in 4:
		ss.runner_cmd("launder")
		ss.start_operation()
		ss.finish_night([])
		if ss.phase == "over":
			break
		ss.next_night()
	check(ss.law.fed_arrived)


func test_views_hide_the_other_sides_books() -> void:
	var ss := _season()
	var runner := ss.view("runner")
	var law := ss.view("law")
	check(runner.has("org") and not runner.has("law"))
	check(runner["evidence"] == null and runner["evidence_rumor"] == "thin")
	check(law.has("law") and not law.has("org") and law["clean_estimate"] == null)


func test_abstract_resolver_respects_counters() -> void:
	var rng := PyRandom.new()
	rng.seed(3)
	var ss := _season()
	var plan := {"runs": 1, "crews": 0, "decoys": 0, "route": "west", "funded": {"heli": 2, "interceptor": 2},
		"cutters": 0, "aerostat": true, "patrol": "west", "tip": true, "leak_patrol": null, "encryption": false}
	var busts := 0
	for i in 300:
		for r in HQ.resolve_abstract(ss, plan, rng):
			busts += int(r.busted)
	plan.merge({"patrol": "sea", "tip": false, "aerostat": false, "funded": {"heli": 0, "interceptor": 0}}, true)
	var busts2 := 0
	for i in 300:
		for r in HQ.resolve_abstract(ss, plan, rng):
			busts2 += int(r.busted)
	check(busts > 3 * busts2, "%d vs %d" % [busts, busts2])


func test_layers_and_seat_plans() -> void:
	check(Layers.features_for(1).is_empty())
	check(Layers.features_for(2).has("contraband") and Layers.features_for(2).has("interceptors"))
	check(Layers.features_for(5).has("hq") and Layers.features_for(5).has("copilot"))
	var p := Layers.plan_match(2)
	check(p.humans("runner") == [Roles.PILOT] and p.humans("law") == [Roles.CONTROLLER] and p.layer == 4, "2 players")
	p = Layers.plan_match(6)
	check(p.layer == 5 and p.humans("runner").has(Roles.BOSS) and p.humans("law").has(Roles.CHIEF), "6 players")
	check(p.humans("runner").size() == 3 and p.humans("law").size() == 3, "3 a side")
	p = Layers.plan_match(5)
	check(Py.any(p.notes, func(n): return "full strength" in n), "odd count note")
	var solo := Layers.plan_match(1)
	check(solo.humans("runner") == [Roles.PILOT] and solo.humans("law").is_empty(), "solo")
