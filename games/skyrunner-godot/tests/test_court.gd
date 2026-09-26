extends TestCase
## The court: an arrest opens a case with charges; the bail hearing; lawyers
## and motions; the Family's help and its risks; pleas and cooperation; the
## trial's odds; the sentence, time inside and the appeal; fugitives; the
## prosecutor's tools; the lawyer's conversation.


func after_each() -> void:
	World.use_map(0)


func _sess(opts := {}) -> Session:
	var o := {"seed": 8, "map_seed": MapCity.SEED, "location": "HAR", "features": Session.SANDBOX_FEATURES, "court": true}
	o.merge(opts, true)
	var s := Session.new(o)
	s.police.frozen = true
	s.court.prosecutor_ai = false
	if s.family != null:
		s.family.ai = false
	s.update(1.0 / 30)
	return s


func _load(s: Session, lb: float) -> void:
	var jid := Jobs.new_id()
	s.active_jobs.append(Jobs.Job.new(jid, "a load", "contraband", "HAR", "FRM", [Jobs.item("Unmarked crate", "cargo", lb, jid, {"hot": true})], 5000))


func _arrest(s: Session, lb := 200.0, how := "forced down by police") -> Dictionary:
	_load(s, lb)
	s._bust(how)
	return s.court.case_


func test_an_arrest_opens_a_case() -> void:
	var s := _sess()
	s.money = 30000
	var c := _arrest(s)
	check(c != null and c.stage == "bail", "the bail hearing")
	check(c.charges.has("possession") and c.charges.has("trafficking"), "possession and trafficking for 200 lb: %s" % [c.charges])
	check_eq(s.phase, "busted", "")
	check(not s.command(Roles.PILOT, "confirm")[0], "no walking out before bail")
	check(c.bail >= 20000, "bail set ($%d)" % c.bail)
	check(s.messages.any(func(m): return "COURT" in m[1]), "the pilot hears it")
	s.dispose()


func test_cash_bail_comes_back_at_trial() -> void:
	var s := _sess()
	s.money = 200000
	var c := _arrest(s)
	var m0 := s.money
	check(s.command(Roles.PILOT, "court_bail", {"how": "cash"})[0], "posted")
	check_eq(s.money, m0 - int(c.bail), "all of it")
	check_eq(c.stage, "pretrial", "out")
	check(s.command(Roles.PILOT, "confirm")[0] and s.phase != "busted", "walk out and fly")
	c.evidence = 0.0  # an easy acquittal
	c.lawyer = "miami"
	c.trial_at = s.time
	var m1 := s.money
	s.court.update(0.1)
	check(s.court.case_ == null or s.court.case_.stage != "pretrial", "tried")
	check(s.money >= m1 + int(c.bail), "the bail came back")
	s.dispose()


func test_a_bond_costs_ten_percent_and_no_money_means_custody() -> void:
	var s := _sess()
	s.money = 50000
	var c := _arrest(s)
	check(s.command(Roles.PILOT, "court_bail", {"how": "bond"})[0], "a bondsman")
	check_eq(s.money, 50000 - int(c.bail * 0.1), "ten percent")
	var t := _sess()
	t.money = 0
	var d := _arrest(t)
	t.time += Court.BAIL_DECIDE_S + 1.0
	t.court.update(0.1)
	check_eq(d.stage, "custody", "nobody posted: custody")
	check_eq(t.phase, "custody", "and the aircraft sits")
	s.dispose()
	t.dispose()


func test_the_prosecutor_calls_the_rich_a_flight_risk() -> void:
	var denied := 0
	for i in 20:
		var s := _sess({"seed": 100 + i})
		s.money = 200000
		_arrest(s)
		check(s.court.flight_risk(), "rich: a flight risk")
		s.court.no_bail()
		if s.court.case_.no_bail:
			denied += 1
			check(s.court.post_bail("cash") != "", "no bail means no bail")
		s.dispose()
	check(denied >= 8, "usually denied (%d of 20)" % denied)


func test_a_better_lawyer_changes_the_odds() -> void:
	var s := _sess()
	s.money = 100000
	var c := _arrest(s)
	c.judge = Court.JUDGES[1].duplicate()
	var p0 := s.court.conviction_odds()
	check(s.command(Roles.PILOT, "court_hire", {"tier": "local"})[0], "Arturo Vega")
	var p1 := s.court.conviction_odds()
	check(s.command(Roles.PILOT, "court_hire", {"tier": "miami"})[0], "Roy Kessler")
	var p2 := s.court.conviction_odds()
	check(p0 > p1 and p1 > p2, "each better lawyer lowers the odds (%.2f %.2f %.2f)" % [p0, p1, p2])
	check(not s.command(Roles.PILOT, "court_hire", {"tier": "local"})[0], "no downgrades")
	s.dispose()


func test_suppression_works_more_for_a_good_lawyer_and_an_illegal_stop() -> void:
	var rate := func(tier: String, no_warrant: bool) -> float:
		var s := _sess()
		s.money = 10000000
		var c := _arrest(s)
		s.court.post_bail("custody")
		c.lawyer = tier
		c.no_warrant = no_warrant
		var ok := 0
		for i in 200:
			c.motions.clear()
			c.evidence = 80.0
			s.court.motion("suppress")
			if c.evidence < 80.0:
				ok += 1
		s.dispose()
		return ok / 200.0
	var pub: float = rate.call("public", false)
	var kes: float = rate.call("miami", false)
	var kes_nw: float = rate.call("miami", true)
	check(pub < kes and kes < kes_nw, "public %.2f < Kessler %.2f < Kessler on an illegal stop %.2f" % [pub, kes, kes_nw])


func test_the_jury_follows_the_evidence() -> void:
	var convict := func(ev: float, tier: String) -> float:
		var s := _sess()
		s.money = 0
		var n := 0
		var guilty := 0
		for i in 120:
			_arrest(s)
			var c: Dictionary = s.court.case_
			c.judge = Court.JUDGES[1].duplicate()
			c.evidence = ev
			c.witnesses = 1
			c.lawyer = tier
			c.stage = "custody"
			c.trial_at = s.time
			s.court.update(0.1)
			var c2 = s.court.case_
			if c2 == null or c2.stage == "prison":
				n += 1
				guilty += int(c2 != null)
			s.court.case_ = null
			s.phase = "parked"
			s.active_jobs.clear()
		s.dispose()
		return float(guilty) / maxf(1.0, n)
	var strong: float = convict.call(85.0, "public")
	var weak: float = convict.call(25.0, "miami")
	check(strong > 0.75, "a strong case with the public defender: convicted (%.2f)" % strong)
	check(weak < 0.25, "a weak case with Kessler: acquitted (%.2f)" % weak)


func test_conviction_prison_and_release() -> void:
	var s := _sess()
	s.money = 50000
	s._switch_aircraft("c182", 0.5)
	var c := _arrest(s)
	c.stage = "custody"
	c.evidence = 100.0
	c.trial_at = s.time
	for i in 10:
		if s.court.stage() == "prison":
			break
		c.trial_at = s.time
		s.court.update(0.1)
	check_eq(s.court.stage(), "prison", "convicted")
	check_eq(s.phase, "custody", "inside")
	check_eq(s.aircraft_key, "c172p", "the Skylane forfeited")
	check(s.money < 50000, "fines and forfeiture")
	check(s.command(Roles.PILOT, "court_wait")[0], "do the time")
	check(s.court.case_ == null, "released")
	check(s.phase != "custody", "and flying again")
	check_eq(s.court.history.size(), 1, "on the record")
	s.dispose()


func test_the_plea_and_the_deal() -> void:
	var s := _sess({"family": true, "ground_war": true})
	s.money = 10000
	var c := _arrest(s)
	s.court.post_bail("custody")
	var full := s.court._expected_years()
	s.court.offer_plea()
	check(not c.plea.is_empty() and float(c.plea.years) < full, "fewer years than trial (%.1f < %.1f)" % [c.plea.years, full])
	check(s.command(Roles.PILOT, "court_plea")[0], "pleaded")
	check_eq(s.court.stage(), "prison", "")
	check(s.court.case_.years < full, "")
	# a deal: name names
	var t := _sess({"family": true, "ground_war": true})
	_arrest(t)
	var st: Dictionary = t.stash_net.live()[0]
	var i0: float = st.intel
	t.family.respect = 60.0
	check(t.command(Roles.PILOT, "court_cooperate")[0], "cooperating")
	check(st.intel >= i0 + 35.0, "the stash houses")
	check_eq(t.family.respect, 0.0, "the Family knows")
	check(t.court.case_ == null or t.court.case_.years < 2.0, "almost no time")
	s.dispose()
	t.dispose()


func test_the_witness_and_the_judge() -> void:
	var s := _sess({"family": true})
	s.money = 1000000
	var outcomes := {}
	for i in 40:
		var c := _arrest(s)
		s.court.post_bail("custody")
		c.witnesses = 2
		c.tampered = false
		var ev: float = c.evidence
		s.court.tamper()
		outcomes["obstruction" if c.charges.has("obstruction") else "quiet"] = true
		check(c.evidence != ev, "something happened")
		s.court.case_ = null
		s.phase = "parked"
		s.active_jobs.clear()
	check(outcomes.size() == 2, "sometimes it works, sometimes it's obstruction: %s" % [outcomes.keys()])
	var c := _arrest(s)
	s.court.post_bail("custody")
	c.judge = Court.JUDGES[1].duplicate()
	check(s.court.bribe_judge() != "", "Judge Ruiz isn't that kind")
	c.judge = Court.JUDGES[2].duplicate()
	var p0 := s.court.conviction_odds()
	s.court.bribe_judge()
	check(c.bought or c.charges.has("obstruction"), "bought, or a sting")
	if c.bought:
		check(s.court.conviction_odds() < p0, "a bought judge helps")
	else:
		check_eq(c.judge.id, "pike", "the sting: Judge Pike takes the case")
	s.dispose()


func test_skip_bail_to_the_island() -> void:
	var s := _sess({"island": true})
	s.money = 100000
	var c := _arrest(s)
	s.court.post_bail("bond")
	s.command(Roles.PILOT, "confirm")
	s.location = Island.CODE
	c.trial_at = s.time
	s.court.update(0.1)
	check_eq(c.stage, "fugitive", "a no-show")
	check(c.charges.has("bail_jumping"), "failure to appear")
	check(s.police.case("runner").wanted, "a warrant")
	# caught again, later
	s.location = "HAR"
	_arrest(s)
	check_eq(c.stage, "custody", "back in custody, straight to trial")
	s.dispose()


func test_arrested_again_on_bail() -> void:
	var s := _sess()
	s.money = 100000
	var c := _arrest(s)
	s.court.post_bail("bond")
	s.command(Roles.PILOT, "confirm")
	var ev: float = c.evidence
	_arrest(s, 50.0)
	check_eq(c.stage, "custody", "bail revoked")
	check(c.evidence > ev, "a stronger case")
	s.dispose()


func test_mandatory_minimums_and_the_prosecutors_tools() -> void:
	var s := _sess({"chronicle": true})
	s.money = 100000
	s.law_funds = 50000.0
	var c := _arrest(s, 400.0)
	s.court.post_bail("custody")
	var y0 := s.court._expected_years()
	var ids := Chronicle.HISTORY.map(func(h): return h[0])
	s.chronicle.history(ids.find("drug_abuse_act"))
	check(s.court.mandatory, "the 1986 act")
	check(s.court._expected_years() > y0, "mandatory minimums (%.1f > %.1f)" % [s.court._expected_years(), y0])
	var w0: int = c.witnesses
	check(s.command(Roles.CONTROLLER, "court_immunity")[0] and c.witnesses == w0 + 1, "immunity for a crewman")
	var m0 := s.money
	check(s.command(Roles.CONTROLLER, "court_forfeiture")[0] and s.money < m0, "the bank records")
	c.evidence = 60.0
	c.charges.erase("conspiracy")
	check(s.command(Roles.CHIEF, "court_charge")[0] and c.charges.has("conspiracy"), "a conspiracy count")
	check(s.command(Roles.CONTROLLER, "court_offer_plea")[0] and not c.plea.is_empty(), "a plea offer")
	check(not s.command(Roles.PILOT, "court_immunity")[0], "not the pilot's to grant")
	s.dispose()


func test_the_familys_lawyer_can_be_the_prosecutors_man() -> void:
	var s := _sess({"family": true})
	s.money = 100000
	s.family.lawyer = "con"
	var c := _arrest(s)
	check_eq(c.lawyer, "family", "the Family's lawyer takes the case")
	check(not c.lawyer_honest, "")
	var bad := s.court.conviction_odds()
	c.lawyer_honest = true
	check(s.court.conviction_odds() < bad, "an honest one is far better")
	s.dispose()


func test_the_ai_prosecutor_works_the_case() -> void:
	var s := _sess()
	s.court.prosecutor_ai = true
	s.money = 20000
	var c := _arrest(s)
	s.court.post_bail("custody")
	s.time += Court.PLEA_AT[0] + 1.0
	s.court.update(0.1)
	check(not c.plea.is_empty(), "a plea offer arrives")
	s.dispose()


func test_the_lawyers_conversation() -> void:
	var s := _sess()
	s.money = 60000
	var c := _arrest(s)
	check(Talk.resource("lawyer") != null, "compiles")
	var b := TalkBalloon.new()
	Engine.get_main_loop().root.add_child(b)
	await b.start(Talk.resource("lawyer"), "start", Talk.State.new(func(): return LocalLink.new(s, Roles.PILOT, false).snapshot(),
		func(n: String, a: Dictionary) -> Array: return s.command(Roles.PILOT, n, a)))
	for i in 6:
		if not b._answers.is_empty():
			break
		await b.advance()
	var answers: Array = b._answers.map(func(r): return str(r.text))
	check(answers.any(func(a): return a.begins_with("Get a bondsman")), "the bail options: %s" % [answers])
	for i in answers.size():
		if answers[i].begins_with("Get a bondsman"):
			await b.choose(i)
			break
	check_eq(c.stage, "pretrial", "out on a bond")
	b.queue_free()
	# and in pretrial: the consultation offers the motions and a deal
	var d := TalkBalloon.new()
	Engine.get_main_loop().root.add_child(d)
	await d.start(Talk.resource("lawyer"), "start", Talk.State.new(func(): return LocalLink.new(s, Roles.PILOT, false).snapshot(),
		func(n: String, a: Dictionary) -> Array: return s.command(Roles.PILOT, n, a)))
	for i in 8:
		if not d._answers.is_empty():
			break
		await d.advance()
	var more: Array = d._answers.map(func(r): return str(r.text))
	check(more.any(func(a): return a.begins_with("File a motion to suppress")), "motions: %s" % [more])
	check(more.any(func(a): return "Named names" in a), "and the question nobody wants to ask")
	for i in more.size():
		if more[i].begins_with("Ask for discovery"):
			await d.choose(i)
			break
	check(c.discovered, "discovery filed through the talk")
	d.queue_free()
	s.dispose()


func test_off_means_the_old_bust() -> void:
	Court.ENABLED = false
	var s := Session.new({"seed": 8, "location": "HAR", "court": true})
	s.police.frozen = true
	check(s.court == null, "no court")
	s.money = 10000
	s._bust("test")
	check(s.money < 10000 and s.phase == "busted", "a fine and the impound, as before")
	s.dispose()
	Court.ENABLED = true
