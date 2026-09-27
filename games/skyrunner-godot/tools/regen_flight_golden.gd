extends SceneTree
## Regenerate tests/fixtures/flight_golden.json: the flight-dependent values of
## the parity suites (the take-off roll, the seeded bot flight, the tactical and
## feasibility trials), flown by the game's own flight model. The Python
## fixtures stay frozen for everything that doesn't fly (RNG, maps, jobs, mass,
## seasons); these are Godot golden values, a determinism check. Regenerate
## only when you deliberately change the flight model or the bot, and say so
## in the commit.
##
##   godot --headless --script tools/regen_flight_golden.gd

const OUT := "res://tests/fixtures/flight_golden.json"


func _init() -> void:
	var trials_ref: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/trials_ref.json"))
	var out := {"core_fm": _core_fm(), "bots_flight": _bot_flight(), "trials": _trials(trials_ref)}
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	f.store_string(JSON.stringify(out, " ", true, true) + "\n")
	f.close()
	print("wrote ", OUT)
	quit()


## tests/test_core_parity.gd: 10 s of full-throttle take-off roll at HAR.
static func _core_fm() -> Array:
	var spec := Aircraft.spec("c172p")
	var md := MassData.read("c172p")
	var w := World.new()
	var lo := Loadout.new(spec, md, md.fuel_capacity_lb() * 0.6)
	var fm := FlightModel.new(spec, MassData.patched_root(), md)
	var af := World.airfield("HAR")
	var back := af.length / 2 - 25
	fm.spawn(af.x - af.ux * back, af.y - af.uy * back, af.heading, w.airfield_elev(af), lo)
	fm.controls.brake = 1.0
	fm.step(0.5, w.ground)
	fm.controls.brake = 0.0
	fm.controls.throttle = 1.0
	var st: FlightModel.FlightState
	for i in 300:
		st = fm.step(1.0 / 30, w.ground)
	return [st.x, st.y, st.alt, st.gs_kts, st.heading, st.fuel_lb, st.weight_lb, st.cg_in, fm.n_gear, fm.n_engines]


## tests/test_bots_parity.gd: the seeded HAR -> VAL bot flight, every 10 s.
static func _bot_flight() -> Dictionary:
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
	var outcome = PilotBot.fly(s, bot, 900, 1.0 / 30, frame)
	var r := {"outcome": outcome, "time": s.time, "touchdown_fpm": s.log.max_touchdown_fpm, "trace": trace}
	s.dispose()
	return r


## tests/test_trials_parity.gd: the same trials (inputs from trials_ref.json).
static func _trials(ref: Dictionary) -> Dictionary:
	SensorNet.REALISM = false
	Economy.REALISM = false
	Arsenal.REALISM = false
	GroundWar.ENABLED = false
	Chronicle.ENABLED = false
	Agency.ENABLED = false
	var tac := []
	Tactical.PYTHON = true
	for w in ref.tactical:
		Jobs._next_id = 1
		tac.append(Tactical.run_trial(w.zone, w.law, w.tactic, int(w.seed)))
	Tactical.PYTHON = false
	var feas := []
	for w in ref.feasibility:
		Jobs._next_id = 1
		var got := Feasibility.run_job([w.test, w.aircraft, w.field, w.load])
		for k in ["test", "aircraft", "field", "load"]:
			got[k] = w[k]
		feas.append(got)
	return {"tactical": tac, "feasibility": feas}
