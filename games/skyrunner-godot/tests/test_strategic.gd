extends TestCase
## The ported season simulator against Python (tools/reference/gen_strategic.py
## -> tests/fixtures/strategic_ref.json), plus the sim-matrix checks from
## tests/test_hq.py.

var ref: Dictionary
const TOL := 1e-9


func before_each() -> void:
	if ref.is_empty():
		ref = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/strategic_ref.json"))


func _same(got, want, what: String) -> bool:
	if want is float or (want is int and got is float):
		if absf(float(got) - float(want)) > absf(float(want)) * TOL + TOL:
			check_near(float(got), float(want), absf(float(want)) * TOL + TOL, what)
			return false
	elif want is Array:
		if got.size() != want.size():
			check_eq(got.size(), want.size(), what + " length")
			return false
		for i in want.size():
			if not _same(got[i], want[i], "%s[%d]" % [what, i]):
				return false
	elif want is Dictionary:
		if not (got is Dictionary):
			check(false, "%s: %s is not a dict" % [what, got])
			return false
		for k in want:
			if not _same(got.get(k), want[k], "%s.%s" % [what, k]):
				return false
	elif got != want:
		check_eq(got, want, what)
		return false
	return true


func _cal() -> HQ.Calibration:
	return HQ.Calibration.from_dict(ref.cal)


func test_seasons_match_python() -> void:
	for s in ref.seasons:
		var a: Array = s.args
		var rules := HQ.PYTHON_RULES.duplicate()  # Python has no rival cartel
		if a[3] is Dictionary:
			rules.merge(a[3])
		var got := Strategic.play_season(a[0], a[1], int(a[2]), rules, _cal() if a[4] else null, a[5])
		_same(got, s.result, "%s vs %s seed %d %s" % [a[0], a[1], a[2], a[5]])


func test_matrix_equilibrium_and_summary_match_python() -> void:
	var res := Strategic.run_matrix(3, HQ.PYTHON_RULES, _cal())
	var want: Dictionary = ref.matrix
	for i in want.results.size():
		var w: Dictionary = want.results[i]
		if not _same({"runner": res[i].runner, "law": res[i].law, "seed": res[i].seed, "winner": res[i].winner,
				"reason": res[i].reason, "nights": res[i].nights, "halftime": res[i].halftime, "margin": res[i].margin},
				w, "season %d" % i):
			return
	var mx := Strategic.matrix(res)
	_same(mx[0], want.runners, "runners")
	_same(mx[1], want.laws, "laws")
	_same(mx[2], want.m, "win matrix")
	var eq := Strategic.equilibrium(mx[2])
	_same(eq, [want.p, want.q, want.v], "equilibrium")
	_same(Strategic.dominance(mx[2], mx[0], mx[1]), want.dominance, "dominance")
	var s := Strategic.summary(res)
	_same(s, want.summary, "summary")
	check_eq(s.reasons.keys(), want.summary.reasons.keys(), "reason order")
	for side in ["runner", "law"]:
		var av := Strategic.action_values(res, side)
		check_eq(av.keys(), want.action_values[side].keys(), side + " actions")
		_same(av, want.action_values[side], side + " action values")


func test_calibration_from_python_flights() -> void:
	var tac = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/tactical_sample.json"))
	_same(Tactical.calibrate(tac).to_dict(), ref.calibrate_tactical, "calibration")


# ---- ported from tests/test_hq.py (the sim-matrix half)
func test_equilibrium_of_matching_pennies() -> void:
	var eq := Strategic.equilibrium([[1.0, 0.0], [0.0, 1.0]])
	check_near(eq[2], 0.5, 0.01)
	check_near(eq[0][0], 0.5, 0.02)
	check_near(eq[1][0], 0.5, 0.02)


func test_dominance_detects_a_strictly_better_row() -> void:
	var notes := Strategic.dominance([[0.9, 0.8], [0.5, 0.4]], ["a", "b"], ["x", "y"])
	check("runner 'a' dominates 'b'" in notes, str(notes))


func test_ablation_disables_the_order() -> void:
	var r := PyRandom.new()
	r.seed(1)
	var ss := HQ.Season.new(r)
	Strategic._disable(ss, "bribe")
	check_eq(ss.runner_cmd("bribe", {"who": "tower"}), "disabled")
	Strategic._disable(ss, "comeback")
	check_eq(ss.rules["comeback_gap"], 99.0)


func test_worker_pool_matches_in_process() -> void:
	var js := Strategic.jobs(1, null, null, [], ["greedy", "smart"], ["balanced"])
	var local := js.map(func(j): return WorkerPool.run_one("strategic", j))
	var pooled := WorkerPool.map("strategic", js, 2)
	check_eq(pooled.size(), local.size())
	for i in local.size():
		_same(pooled[i], local[i], "job %d" % i)
