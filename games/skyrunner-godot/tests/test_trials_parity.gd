extends TestCase
## Seeded tactical and feasibility trials replayed against the Python sims
## (tools/reference/gen_trials.py -> tests/fixtures/trials_ref.json): JSBSim,
## the pilot bot, police, boats and both RNG streams together.
##
## JSBSim here is our CMake build, not the pip wheel; the two differ by a few
## ulp in position/long-gc-deg now and then (compiler/libm), and a trial that
## flies near a bot decision threshold amplifies that: north/tipped/low is
## identical to 1e-12 until t=88 s and still ends in the same bust, a minute
## later. So: outcome and every flag must match for all trials, the numbers
## only for the ones that stay off a knife-edge.
const CHAOTIC := ["north/tipped/low"]

var ref: Dictionary


func before_each() -> void:
	if ref.is_empty():
		ref = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/trials_ref.json"))


func _match(got: Dictionary, want: Dictionary, what: String) -> void:
	for k in want:
		if want[k] is float and what in CHAOTIC:
			continue
		if want[k] is float:
			# the fixture went through Godot's JSON parser, which is only good to ~1e-15
			check_near(float(got[k]), want[k], 1e-9 * maxf(1.0, absf(want[k])), "%s.%s" % [what, k])
		else:
			check_eq(got[k], want[k], "%s.%s" % [what, k])


func test_tactical_trials_replay_exactly() -> void:
	for w in ref.tactical:
		Jobs._next_id = 1
		_match(Tactical.run_trial(w.zone, w.law, w.tactic, int(w.seed)), w, "%s/%s/%s" % [w.zone, w.law, w.tactic])


func test_feasibility_trials_replay_exactly() -> void:
	for w in ref.feasibility:
		Jobs._next_id = 1
		var got := Feasibility.run_job([w.test, w.aircraft, w.field, w.load])
		_match(got, w, "%s %s %s %s" % [w.test, w.aircraft, w.field, w.load])
