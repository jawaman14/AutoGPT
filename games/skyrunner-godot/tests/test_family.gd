extends TestCase
## The Family (La Cosa Nostra): offers that help or rob, reads that hint which,
## the street tax, the RICO case, the rat and the trial; and the Company's
## double game (the hangout, the stung flight, the pay in the mail).


func after_each() -> void:
	World.use_map(0)


func _sess(opts := {}) -> Session:
	var o := {"seed": 6, "map_seed": MapCity.SEED, "location": "QRY", "features": Session.SANDBOX_FEATURES, "family": true}
	o.merge(opts, true)
	var s := Session.new(o)
	s.police.frozen = true
	s.family.ai = false
	s.update(1.0 / 30)
	return s


## An offer of `kind`, honest or not (re-rolled until it comes out that way).
func _offer(s: Session, kind: String, honest: bool) -> Dictionary:
	for i in 200:
		var o = s.family.offer(kind)
		if o != null and o.honest == honest:
			return o
		if o != null:
			s.family.offers.erase(o)
	return {}


func test_an_honest_loan_is_repaid() -> void:
	var s := _sess()
	s.money = 1000
	var o := _offer(s, "loan", true)
	check_eq(s.family.accept(o.id), "", "taken")
	check_eq(s.money, 1000 + int(o.amount), "cash now")
	s.money += int(o.amount)  # a good run meanwhile
	var m0 := s.money
	s.time += Family.LOAN_DUE_S + 1.0
	s.family.update(10.0)
	check_eq(s.money, m0 - int(o.amount * 1.2), "the vig: 20%")
	check(s.family.loan.is_empty() and s.family.cons == 0, "square")
	s.dispose()


func test_a_con_loan_brings_the_enforcers() -> void:
	var s := _sess()
	s.money = 0
	var o := _offer(s, "loan", false)
	s.family.accept(o.id)
	var trucks0: int = s.stash_net.trucks.size()
	var heat0: float = Py.sum_by(s.stash_net.stashes, func(st): return st.heat)
	s.time += Family.LOAN_DUE_S + 1.0
	s.family.update(10.0)
	check_eq(s.money, 0, "they take everything")
	check_eq(s.family.cons, 1, "a con")
	check(s.stash_net.trucks.size() < trucks0 or Py.sum_by(s.stash_net.stashes, func(st): return st.heat) > heat0,
		"and break something of ours")
	s.dispose()


func test_the_docks_deal_slows_the_boardings_or_betrays_them() -> void:
	var s := _sess()
	s.money = 10000
	var base: float = s.maritime.seize_mult
	s.family.accept(_offer(s, "docks", true).id)
	check_near(s.maritime.seize_mult, base * 2.0, 0.001, "the union: boardings take twice as long")
	s.time += Family.DOCKS_S + 1.0
	s.family.update(10.0)
	check_near(s.maritime.seize_mult, base, 0.001, "and back to normal")
	s.family.accept(_offer(s, "docks", false).id)
	check_near(s.maritime.seize_mult, base * 0.5, 0.001, "a rat: the Coast Guard knows")
	s.dispose()


func test_a_guns_buy_bust_feeds_the_law() -> void:
	var s := _sess()
	s.money = 50000
	var r0: int = s.arsenals.org.stock.rifle
	var o := _offer(s, "guns", true)
	s.family.accept(o.id)
	check_eq(s.arsenals.org.stock.rifle, r0 + int(o.amount), "rifles")
	var l0: int = s.arsenals.law.stock.rifle
	var f0 := s.law_funds
	var c := _offer(s, "guns", false)
	s.family.accept(c.id)
	check_eq(s.arsenals.org.stock.rifle, r0 + int(o.amount), "no more rifles")
	check_eq(s.arsenals.law.stock.rifle, l0 + int(c.amount), "they're evidence now")
	check(s.law_funds > f0 and s.police.case("runner").suspicion >= 20.0, "forfeit, and the case grows")
	s.dispose()


func test_muscle_fights_for_us_or_sells_a_stash() -> void:
	var s := _sess({"ground_war": true})
	s.money = 50000
	var n0: int = s.ground.of("org").size()
	s.family.accept(_offer(s, "muscle", true).id)
	var lent: Array = s.ground.of("org").filter(func(q): return q.tag == "family")
	check_eq(lent.size(), 1, "a Moretti crew")
	check(not GroundWar.HOSTILE["org"].has(lent[0].faction), "on our side")
	check_eq(lent[0].dict().tag, "family", "drawn in their suits")
	var r0: int = s.arsenals.org.stock.rifle
	s.time += Family.MUSCLE_S + 1.0
	s.family.update(10.0)
	check_eq(s.ground.of("org").size(), n0, "gone home")
	check_eq(s.arsenals.org.stock.rifle, r0, "with their own guns")
	var hot = Py.max_by(s.stash_net.live(), func(st): return StashNet.suspicion(st))
	var h0: float = hot.heat
	s.family.accept(_offer(s, "muscle", false).id)
	check(hot.heat >= h0 + 25.0, "sold to Los Cuervos")
	s.dispose()


func test_the_lawyer_makes_a_bust_a_fine_or_worse() -> void:
	var s := _sess()
	s.money = 50000
	s.family.accept(_offer(s, "lawyer", true).id)
	s._bust("test")
	check(s.phase != "busted", "a fine, not the aircraft")
	check(s.money < 46000, "and a big one")
	s.family.accept(_offer(s, "lawyer", false).id)
	s._bust("test")
	check_eq(s.phase, "busted", "the lawyer worked for the prosecutor")
	s.dispose()


func test_the_read_is_a_clue_not_a_certainty() -> void:
	var s := _sess()
	var right := 0
	var n := 600
	for i in n:
		var o = s.family.offer("laundry" if s.money >= 8000 else "docks")
		if o == null:
			s.money = 20000
			o = s.family.offer("laundry")
		s.family.offers.erase(o)
		var looks_good: bool = Family.GOOD_READS[o.kind].has(o.read)
		if looks_good == o.honest:
			right += 1
	var acc := float(right) / n
	check(acc > 0.7 and acc < 0.9, "the read is right ~80%% of the time (%.2f)" % acc)
	s.dispose()


func test_pressure_makes_them_liars() -> void:
	var s := _sess()
	var calm := s.family.honesty()
	s.family.rico = 80.0
	s.family.rat = true
	check(s.family.honesty() < calm - 0.3, "a family with a rat in it sells everyone out")


func test_the_street_tax() -> void:
	var s := _sess()
	s.money = 100000
	s.family.update(10.0)
	check_eq(s.family.tribute_due, 10000, "10% of the cash on hand")
	check(s.command(Roles.BOSS, "pay_tribute")[0], "the boss pays")
	check_eq(s.money, 90000, "")
	check(s.family.respect > 55.0, "respect")
	# refuse, and something burns
	var t := _sess()
	t.money = 100000
	t.family.update(10.0)
	t.money = 5000  # spent it
	var r0 := t.family.respect
	t.time += Family.TAX_DUE_S + 1.0
	t.family.update(10.0)
	check(t.family.respect <= r0 - 25.0, "an insult")
	check(t.messages.any(func(m): return "tribute wasn't paid" in m[1]), "and a torching")
	s.dispose()
	t.dispose()


func test_rico_the_rat_and_the_trial() -> void:
	var s := _sess({"ground_war": true})
	s.law_funds = 100000.0
	var st: Dictionary = s.stash_net.live()[0]
	s.family.knows[st.id] = true
	var i0: float = st.intel
	check(s.command(Roles.CHIEF, "rico_case")[0], "the chief files")
	check(not s.command(Roles.PILOT, "rico_case")[0], "not the pilot's to file")
	s.family.rico = Family.RAT_AT
	for i in 400:
		s.family.update(10.0)
		if s.family.rat:
			break
	check(s.family.rat, "past 60 somebody flips")
	for i in 60:
		s.family.update(10.0)
	check(st.intel > i0, "the rat's tips")
	for i in 30:
		if s.family.gone:
			break
		s.command(Roles.PATROL, "rico_case")
	check(s.family.gone, "the Commission trial")
	check(st.intel >= i0 + 30.0, "what they knew is evidence")
	check(s.family.offer("docks") == null, "no more offers")
	check(not s.command(Roles.BOSS, "pay_tribute")[0], "nobody left to pay")
	s.dispose()


func test_the_ai_boss_trusts_good_reads_only() -> void:
	var s := _sess()
	s.money = 1000
	var o = _offer(s, "loan", true)
	o.read = Family.BAD_READS.loan[0]
	check(not s.family.ai_wants(o), "a bad read: no")
	o.read = Family.GOOD_READS.loan[0]
	check(s.family.ai_wants(o), "short of cash and a good read: yes")
	s.money = 90000
	check(not s.family.ai_wants(o), "rich: no need")
	s.dispose()


func test_off_means_no_family() -> void:
	Family.ENABLED = false
	var t := Session.new({"seed": 6, "map_seed": MapCity.SEED, "location": "QRY", "family": true})
	check(t.family == null, "no Family")
	t.dispose()
	Family.ENABLED = true


func test_the_milestones_and_history() -> void:
	var s := _sess({"chronicle": true})
	s.money = 1000
	s.family.accept(_offer(s, "loan", true).id)
	s.chronicle.update(1.0)
	check(s.chronicle.fired.has("first_loan"), "first loan")
	s.family.rat = true
	s.chronicle.update(1.0)
	check(s.chronicle.fired.has("rat_flipped") and not s.messages.any(func(m): return "rat" in m[1]), "a secret the runner never hears")
	var r0 := s.family.rico
	var ids := Chronicle.HISTORY.map(func(h): return h[0])
	s.chronicle.history(ids.find("pizza"))
	check(s.family.rico >= r0 + 10.0, "the Pizza Connection trial")
	s.dispose()


# ------------------------------------------------------------------ the Company's double game
func _asess() -> Session:
	return _sess({"agency": true})


func test_the_hangout() -> void:
	var s := _asess()
	s.agency.exposure = 90.0
	s.agency.protected_until = s.time + 9999.0
	for i in 2000:
		s.agency.update(10.0)
		if s.agency.hung_out:
			break
	check(s.agency.hung_out, "the Company cut its losses")
	check(not s.agency.protecting(), "no protection")
	check(s.police.case("runner").suspicion >= 30.0, "and gave them our name")
	s.dispose()


func test_a_stung_flight_is_a_bust() -> void:
	var s := _asess()
	var j = null
	for i in 400:
		var k = s.agency.job_from(World.airfield("QRY"), s.world.airfields)
		if k != null and s.agency.stings.has(k.id):
			j = k
			break
	check(j != null, "the Company sometimes gives a flight away")
	s.active_jobs.append(j)
	check(not s.agency.protecting(), "no call from Washington for that one")
	s._complete_delivery(j, World.airfield(j.dest))
	check_eq(s.phase, "busted", "a DEA sting at the strip")
	s.dispose()


func test_sting_notes_are_a_clue() -> void:
	var s := _asess()
	var hinted_sting := 0
	var stings := 0
	var hinted_clean := 0
	var clean := 0
	s.agency.exposure = 60.0
	for i in 800:
		var j = s.agency.job_from(World.airfield("QRY"), s.world.airfields)
		if j == null:
			continue
		var hint: bool = Agency.STING_HINT in j.notes
		if s.agency.stings.has(j.id):
			stings += 1
			hinted_sting += int(hint)
		else:
			clean += 1
			hinted_clean += int(hint)
	check(stings > 20, "stings happen (%d)" % stings)
	check(float(hinted_sting) / stings > 0.6 and float(hinted_clean) / clean < 0.2, "the hint mostly means it")
	s.dispose()
