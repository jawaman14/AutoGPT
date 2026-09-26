extends TestCase
## The Agency: arms flights south, protection from the task force (quashed
## busts, waved-through trucks), favours, the task force digging, the hearings,
## and the history the Chronicle runs through.


func after_each() -> void:
	World.use_map(0)


func _sess(opts := {}) -> Session:
	var o := {"seed": 6, "map_seed": MapCity.SEED, "location": "QRY", "features": Session.SANDBOX_FEATURES, "agency": true}
	o.merge(opts, true)
	var s := Session.new(o)
	s.police.frozen = true
	s.update(1.0 / 30)
	return s


func _agency_job(s: Session) -> Jobs.Job:
	for i in 30:
		var j = s.agency.job_from(World.airfield("QRY"), s.world.airfields)
		if j != null:
			return j
	return null


func test_southern_front_flights_on_the_board() -> void:
	var s := _sess()
	var found := false
	for i in 20:
		s.refresh_board("QRY")
		if s.boards["QRY"].any(func(j): return j.agency):
			found = true
			break
	check(found, "the Company's flights are offered at the shady strips")
	var j := _agency_job(s)
	check(j.hot() and j.agency and not j.weapons.is_empty(), "guns, hot, the Agency's")
	check_eq(Economy.good_of(j), "guns", "priced as guns")
	s.dispose()


func test_carrying_its_cargo_a_bust_is_quashed() -> void:
	var s := _sess()
	s.active_jobs.append(_agency_job(s))
	s.police.case("runner").suspicion = 90.0
	s._bust("forced down by police")
	check(s.phase != "busted", "a call from Washington")
	check_eq(s.police.case("runner").suspicion, 0.0, "the case is gone")
	check_eq(s.agency.quashed, 1, "one quash")
	check(s.agency.exposure >= Agency.QUASH_EXPOSURE, "and a trail left behind")
	check(s.law_log.any(func(m): return "Washington" in m[1]), "the desk knows who closed it")
	s.dispose()


func test_protection_after_a_run_then_it_runs_out() -> void:
	var s := _sess()
	var j := _agency_job(s)
	s.active_jobs.append(j)
	s._complete_delivery(j, World.airfield(j.dest))
	check(s.agency.flights == 1 and s.agency.trust > 20.0, "a run for the Company")
	check(s.agency.protecting(), "protected for a while")
	s._bust("test")
	check(s.phase != "busted", "quashed")
	s.time += Agency.PROTECT_S + 1.0
	check(not s.agency.protecting(), "the window closes")
	s._bust("test")
	check_eq(s.phase, "busted", "busted like anyone else")
	s.dispose()


func test_checkpoints_wave_protected_trucks_through() -> void:
	var s := _sess()
	s.agency.protected_until = s.time + 600.0
	var r := PyRandom.new()
	r.seed(3)
	var waved := 0
	for i in 400:
		if s.agency.waves_through(r):
			waved += 1
	check(waved > 240 and waved < 320, "mostly (%d of 400)" % waved)
	s.agency.protected_until = -1.0
	check(not s.agency.waves_through(r), "not when unprotected")
	s.dispose()


func test_the_task_force_digs_and_the_hearings_end_it() -> void:
	var s := _sess()
	s.law_funds = 100000.0
	check(s.command(Roles.CHIEF, "investigate_agency")[0], "the chief orders an investigation")
	check(s.agency.exposure > 0.0, "exposure grows")
	check(not s.command(Roles.PILOT, "investigate_agency")[0], "not the pilot's to order")
	var f0 := s.law_funds
	for i in 30:
		if s.agency.burned:
			break
		s.command(Roles.CONTROLLER, "investigate_agency")
	check(s.agency.burned, "exposed")
	check(s.law_funds > f0 - 30 * Agency.INVESTIGATE_COST + 14000.0, "the budget from Congress")
	check(s.messages.any(func(m): return "hearings" in m[1]), "the pilot reads it in the papers")
	s.active_jobs.append(_agency_job(s) if _agency_job(s) != null else Jobs.Job.new(1, "x", "cargo", "QRY", "FRM", [], 1))
	s._bust("after the hearings")
	check_eq(s.phase, "busted", "no more protection")
	check(s.agency.job_from(World.airfield("QRY"), s.world.airfields) == null, "no more flights")
	s.dispose()


func test_favours_for_a_trusted_outfit() -> void:
	var s := _sess()
	s.agency.trust = 90.0
	var r0: int = s.arsenals.org.stock.rifle
	for i in 40 * 90:
		s.agency.update(10.0)
		s.agency.trust = 90.0
		if s.arsenals.org.stock.rifle > r0:
			break
	check(s.arsenals.org.stock.rifle > r0, "rifles left at the strip")
	s.dispose()


func test_the_history_runs_in_order_and_hits_the_agency() -> void:
	var s := _sess({"chronicle": true})
	var e0 := s.agency.exposure
	var texts := []
	for i in Chronicle.HISTORY.size():
		texts.append(s.chronicle.history(i))
	check(texts[0].begins_with("1979") and texts.back().begins_with("1986"), "1979 to 1986")
	check(s.agency.exposure > e0 or s.agency.burned, "the shoot-down, the affair and the Senate move the exposure")
	check(s.agency.pay_mult > 1.0, "Boland: the money went private")
	check(s.messages.any(func(m): return "Boland" in m[1]), "in the papers")
	# and the clock fires them one at a time
	var t := _sess({"chronicle": true})
	for i in int(Chronicle.HISTORY_EVERY_S) + 5:
		t.chronicle.update(1.0)
	check_eq(t.chronicle.history_i, 1, "one headline per stretch of play")
	s.dispose()
	t.dispose()


func test_off_means_no_agency() -> void:
	Agency.ENABLED = false
	var s := _sess()
	check(s.agency == null, "no Agency")
	s.dispose()
	Agency.ENABLED = true
