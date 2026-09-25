extends TestCase
## The ported route/approach/departure planners and one seeded bot flight
## against the Python bots (tools/reference/gen_bots.py -> tests/fixtures/bots_ref.json).

var ref: Dictionary
var w: World
const TOL := 1e-9


func before_each() -> void:
	if ref.is_empty():
		ref = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/bots_ref.json"))
		w = World.new()


func _near_all(got: Array, want: Array, tol: float, what: String) -> bool:
	if got.size() != want.size():
		check_eq(got.size(), want.size(), what + " length")
		return false
	for i in want.size():
		if want[i] is Array:
			if not _near_all(got[i], want[i], tol, "%s[%d]" % [what, i]):
				return false
		elif want[i] is String:
			if got[i] != want[i]:
				check_eq(got[i], want[i], "%s[%d]" % [what, i])
				return false
		elif absf(float(got[i]) - float(want[i])) > tol * maxf(1.0, absf(float(want[i]))):
			check_near(float(got[i]), float(want[i]), tol * maxf(1.0, absf(float(want[i]))), "%s[%d]" % [what, i])
			return false
	return true


func test_routes_match_python() -> void:
	for r in ref.routes:
		var a := World.airfield(r.from)
		var b := World.airfield(r.to)
		_near_all(RoutePlanner.plan_route(w, [a.x, a.y], [b.x, b.y]), r.pts, TOL, "%s->%s" % [r.from, r.to])


func test_approaches_and_departures_match_python() -> void:
	for code in ref.approaches:
		var ap := PilotBot.plan_approach(w, World.airfield(code), 1.2, 120.0)
		_near_all([ap.hdg, ap.aim, ap.elev, ap.gamma, ap.clear_m], ref.approaches[code], TOL, "approach " + code)
		_near_all(PilotBot.plan_departure(w, World.airfield(code), 160), ref.departures[code], TOL, "departure " + code)


## The whole HAR -> VAL flight, JSBSim and bot logic together, every 10 s.
func test_seeded_bot_flight_matches_python() -> void:
	Jobs._next_id = 1
	var s := Session.new({"seed": 5, "location": "HAR", "features": []})
	s.police.frozen = true
	var val := World.airfield("VAL")
	var bot := PilotBot.new(s, [PilotBot.Leg.new("land", val.x, val.y, "VAL")])
	var trace := []
	var frame := func(sess: Session):
		if Py.imod(Py.round_int(sess.time * 30), 300) == 0:
			var st := sess.state
			trace.append([Py.round_n(sess.time, 6), bot.phase, st.x, st.y, st.alt, st.heading, st.ias_kts])
	var want: Dictionary = ref.flight
	check_eq(PilotBot.fly(s, bot, 900, 1.0 / 30, frame), want.outcome, "outcome")
	check_near(s.time, want.time, 1e-9, "landing time")
	check_near(s.log.max_touchdown_fpm, want.touchdown_fpm, 1e-6, "touchdown sink")
	_near_all(trace, want.trace, 1e-7, "trace")
	s.dispose()
