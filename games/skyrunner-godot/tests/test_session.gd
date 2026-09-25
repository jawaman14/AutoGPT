extends TestCase
## Ported from tests/test_session.py


func test_starts_parked_with_jobs() -> void:
	var s := T.sess()
	T.idle(s, 1)
	check(s.parked and s.location == "HAR", "parked at HAR")
	check(not s.boards["HAR"].is_empty(), "board has work")


func test_accept_job_loads_items() -> void:
	var s := T.sess()
	T.idle(s, 0.5)
	var job: Jobs.Job = T.first(s.boards["HAR"], func(j): return j.weight_lb() < 250)
	var before := s.fm.state().weight_lb
	check(s.accept_job(job) == null, "accepted")
	check(not s.loadout.pending.is_empty(), "the crew has to carry it in")
	T.idle(s, 0.2)
	check_near(s.fm.state().weight_lb, before, 5, "not aboard yet")
	T.idle(s, 30)
	check(s.loadout.pending.is_empty(), "loading done")
	check_near(s.fm.state().weight_lb, before + job.weight_lb(), 5, "aboard now")


func test_cannot_depart_with_cargo_on_ramp() -> void:
	var s := T.sess()
	T.idle(s, 0.5)
	var job: Jobs.Job = T.first(s.boards["HAR"], func(j): return j.weight_lb() < 250)
	s.accept_job(job)
	T.idle(s, 3, ["throttle_up"])  # still loading
	check(s.state.gs_kts < 1, "held while loading")
	T.idle(s, 30)
	for it in s.loadout.items.values():
		s.loadout.assignment.erase(it.id)
	T.idle(s, 3, ["throttle_up"])  # left on the ramp
	check(s.state.gs_kts < 1, "held with cargo on the ramp")


func test_takeoff_with_keyboard() -> void:
	var s := T.sess()
	T.idle(s, 0.5)
	for i in 60 * 40:
		var held := ["throttle_up"] if s.mapper.controls.throttle < 1 else []
		var st := s.state
		if st.ias_kts > 58 and st.pitch < 8:
			held.append("pitch_up")
		var err := Py.wrap180(st.heading - World.airfield("HAR").heading)
		if err > 1:
			held.append("yaw_left")
		elif err < -1:
			held.append("yaw_right")
		s.update(1.0 / 60, T.inp(held))
		if not check(s.phase != "crashed", s.last_outcome):
			return
		if s.state.agl > 60:
			break
	check(s.phase == "flying" and s.location == null, "airborne")


func test_delivery_pays_on_arrival() -> void:
	var s := T.sess()
	T.idle(s, 0.5)
	var job: Jobs.Job = s.boards["HAR"][0]
	job.dest = "VAL"
	var cargo := job.items.filter(func(it): return it.kind == "cargo").slice(0, 1)
	job.items = cargo if not cargo.is_empty() else job.items.slice(0, 1)
	check(s.accept_job(job) == null, "accepted")
	T.idle(s, 20)
	var money := s.money
	# teleport: rolling slowly down Valley's runway as if just landed
	s.spawn_at("VAL")
	s.log.airborne = true
	s.phase = "flying"
	s.location = null
	T.idle(s, 6)
	check(s.location == "VAL" and s.parked, "parked at VAL")
	check(s.money > money, "paid")
	check(s.active_jobs.is_empty(), "job done")


func test_crash_into_ridge_then_respawn() -> void:
	var s := T.sess()
	T.idle(s, 0.3)
	s.fm.spawn(0, 2500, 0, 0, s.loadout, 450, 100)
	s.phase = "flying"
	s.location = null
	s.log.airborne = true
	s.log.departed_from = "VAL"
	s.mapper.controls.throttle = 0.8
	for i in 60 * 90:
		s.update(1.0 / 60, T.inp())
		if s.phase == "crashed":
			break
	check_eq(s.phase, "crashed")
	s.update(1.0 / 60, T.inp([], ["confirm"]))
	check(s.phase == "parked" and s.location == "VAL", "respawned at VAL")
