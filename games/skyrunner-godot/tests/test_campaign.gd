extends TestCase
## Ported from tests/test_campaign.py


func _sess() -> Session:
	return T.sess(11, {"mode": Roles.CAMPAIGN})


func _emit(s: Session, kind: String, data: Dictionary) -> void:
	s.bus.emit(kind, s.time, "", ["runner", "law"], data)


func test_chapter_one_is_legal_only() -> void:
	var s := _sess()
	Campaign.new().attach(s)
	check(not s.features.has("contraband") and s.police.features.is_empty(), "no hot systems")
	for board in s.boards.values():
		check(not Py.any(board, func(j): return j.hot()), "no hot jobs on the board")


func test_objectives_advance_chapters() -> void:
	var s := _sess()
	var camp := Campaign.new()
	camp.attach(s)
	_emit(s, "job_delivered", {"pay": 5200, "hot": false})
	_emit(s, "landed", {"code": "EGL"})
	s.update(1.0 / 60, T.inp())
	check(camp.index == 1 and camp.chapter.title == "A Favor for Manny", "chapter 2")
	check(Py.any(s.boards[s.location], func(j): return j.hot() and "Manny" in j.title), "Manny's job posted")
	check(s.features.has("contraband"))


func test_wanted_spoils_the_clean_run() -> void:
	var s := _sess()
	var camp := Campaign.new(1)
	camp.attach(s)
	var job = T.first(s.boards[s.location], func(j): return j.hot())
	s.accept_job(job)
	s.police.wanted = 1
	s.update(1.0 / 60, T.inp())
	_emit(s, "job_delivered", {"pay": 4500, "hot": true})
	check_eq(camp.progress.get("hot_clean", 0), 0)


func test_kickers_puts_rosa_aboard() -> void:
	var s := _sess()
	Campaign.new(2).attach(s)
	check(s.copilot == "ai" and s.loadout.copilot_aboard, "Rosa aboard")
	check(Py.any(s.boards[s.location], func(j): return j.is_airdrop()), "airdrop on the board")


func test_long_legs_starts_offshore_with_ferry_fuel() -> void:
	var s := _sess()
	Campaign.new(3).attach(s)
	check_eq(s.phase, "flying")
	check(s.loadout.ferry_fuel_lb() > 100, "bladder full")
	check(not s.active_jobs.is_empty() and s.active_jobs[0].is_airdrop(), "airdrop aboard")
	for i in 60 * 3:
		s.update(1.0 / 60, T.inp())
	check_eq(s.phase, "flying")
	# the AI co-pilot starts pumping once the wings have room
	s.fm.fdm.set_property("propulsion/tank[0]/contents-lbs", 20)
	s.fm.fdm.set_property("propulsion/tank[1]/contents-lbs", 20)
	for i in 60 * 5:
		s.update(1.0 / 60, T.inp())
	check(s.pumping, "pumping")


func test_save_roundtrip() -> void:
	var c := Campaign.new(2, {"kicked": 3})
	var d := Campaign.from_dict(c.to_dict())
	check(d.index == 2 and d.progress == {"kicked": 3}, "roundtrip")
	check(Campaign.CHAPTERS[3].playable and not Campaign.CHAPTERS[4].playable)
