extends TestCase
## The ported Session, police/maritime/AI-runner world and HQ season against
## the Python game (tools/reference/gen_session.py -> tests/fixtures/session_ref.json).
## Everything here is kinematics + seeded RNG, so it should match to the bit;
## the tolerance only exists to print a readable diff if it ever drifts.

var ref: Dictionary
const TOL := 1e-9


func before_each() -> void:
	if ref.is_empty():
		ref = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/session_ref.json"))


func _same(got, want, what: String) -> void:
	if want is float or (want is int and got is float):
		check_near(float(got), float(want), absf(float(want)) * TOL + TOL, what)
	elif want is Array:
		check_eq(got.size(), want.size(), what + " length")
		for i in mini(got.size(), want.size()):
			_same(got[i], want[i], "%s[%d]" % [what, i])
	elif want is Dictionary:
		check_eq(got.keys().map(func(k): return str(k)), want.keys(), what + " keys")
		for k in want:
			_same(got.get(k), want[k], "%s.%s" % [what, k])
	else:
		check_eq(got, want, what)


func test_seeded_session_matches() -> void:
	Jobs._next_id = 1
	var s := Session.new({"seed": 3})
	var want: Dictionary = ref.solo
	check_eq(s.squawk, want.squawk, "squawk")
	_same(s.maritime.cove, want.cove, "cove point")
	_same(s.maritime.cg_station, want.cg, "coast guard station")
	var got := []
	for j in s.boards["HAR"]:
		got.append([j.id, j.title, j.payout, Py.round_n(j.weight_lb(), 6)])
	_same(got, want.board, "HAR board")


func _police_snap(p: Session) -> Dictionary:
	var cases := {}
	for k in p.police.cases:
		var c: PoliceSystem.Case = p.police.cases[k]
		cases[k] = [c.suspicion, c.wanted, c.bust_meter]
	var tracks := {}
	for k in p.police.sensors.tracks:
		tracks[k] = [p.police.sensors.tracks[k].x, p.police.sensors.tracks[k].y]
	return {
		"t": Py.round_n(p.time, 6),
		"smugglers": p.smugglers.map(func(a): return [a.id, a.x, a.y, a.z, a.heading, a.state, a.bales_left]),
		"units": p.police.units.map(func(u): return [u.id, u.kind, u.x, u.y, u.z, u.heading, u.state, u.target_id]),
		"cases": cases,
		"score": p.police.score,
		"boats": p.maritime.boats.map(func(b): return [b.id, b.kind, b.x, b.y, b.state]),
		"tracks": tracks,
		"stock": p.police.stock,
		"law_log": p.law_log.slice(-6).map(func(m): return m[1]),
	}


func test_police_mode_run_matches_python() -> void:
	Jobs._next_id = 1
	var p := Session.new({"seed": 3, "mode": Roles.POLICE})
	var k := 0
	for i in range(1, 30 * 300 + 1):
		p.update(1.0 / 30)
		if i % (30 * 60) == 0:
			var before := failures.size()
			_same(_police_snap(p), ref.police[k], "police t=%ds" % ((k + 1) * 60))
			if failures.size() > before:
				return  # first divergence is the interesting one
			k += 1


func test_hq_seasons_match_for_every_bot_pairing() -> void:
	var ri := 0
	for rname in HQBots.RUNNER_POLICIES:
		var li := 0
		for lname in HQBots.LAW_POLICIES:
			var want: Dictionary = ref.seasons[ri * HQBots.LAW_POLICIES.size() + li]
			check_eq([rname, lname], [want.runner, want.law], "pairing order")
			var r := PyRandom.new()
			r.seed(1000 + 10 * ri + li)
			var ss := HQ.Season.new(r, {"rivals": false})  # Python has no rival cartel
			var bot := PyRandom.new()
			bot.seed(7 + ri * 31 + li)
			var mem := [{}, {}]
			while true:
				HQBots.RUNNER_POLICIES[rname].call(ss, bot, mem[0])
				HQBots.LAW_POLICIES[lname].call(ss, bot, mem[1])
				var plan := ss.start_operation()
				ss.finish_night(HQ.resolve_abstract(ss, plan, bot))
				if ss.phase == "over":
					break
				ss.next_night()
			var news := []
			for rep in ss.reports:
				news.append_array(rep.lines)
			var before := failures.size()
			_same({"winner": ss.winner, "reason": ss.reason, "history": ss.history, "news": news, "dirty": ss.org.dirty,
				"clean": ss.org.clean, "evidence": ss.law.evidence},
				{"winner": want.winner, "reason": want.reason, "history": want.history, "news": want.news,
				"dirty": want.dirty, "clean": want.clean, "evidence": want.evidence}, "%s vs %s" % [rname, lname])
			if failures.size() > before:
				return
			li += 1
		ri += 1
