class_name Feasibility
extends RefCounted
## Airfield x aircraft x load feasibility, flown by the pilot bot (port of
## skyrunner/sim/feasibility.py).
##
## A strip that a loaded aircraft can land on but can't leave is a trap, and a
## job generator that sends you there is unfair. This sweep finds both.

## [fuel frac, payload frac]
const LOADS := {"light": [0.3, 0.0], "half": [0.6, 0.5], "max": [1.0, 1.0]}


static func _trial(aircraft: String, field: String, load: String, test: String, ok: bool, outcome: String,
		weight_lb: float, seconds: float) -> Dictionary:
	return {"aircraft": aircraft, "field": field, "load": load, "test": test, "ok": ok, "outcome": outcome,
		"weight_lb": weight_lb, "seconds": seconds}


static func _session(key: String, code: String, seed := 11) -> Session:
	var s := Session.new({"seed": seed, "location": code, "owned": [key], "aircraft_key": key, "features": []})
	s.police.features.clear()
	s.police.frozen = true  # no law in the test rig (tick and landing checks)
	return s


## Fill fuel, then crates up to payload_frac of what MTOW/stations allow,
## placed by the loadmaster, loaded instantly (this is a test rig).
static func load_aircraft(sess: Session, fuel_frac: float, payload_frac: float) -> void:
	var lo: Loadout = sess.loadout
	lo.fuel_lb = lo.mass.fuel_capacity_lb() * fuel_frac
	var base: float = lo.compute(null, true).weight_lb
	var room := maxf(0.0, sess.spec.mtow_lb - base) * payload_frac
	while room > 20:
		var w := minf(60.0, room)
		lo.add(Loadout.Item.new(Jobs.new_id(), "Crate", "cargo", w, 0))
		room -= w
		if not lo.auto_balance():
			lo.remove_item(lo.items.keys().max())
			lo.auto_balance()
			break
	lo.pending.clear()
	sess.fm.apply_loadout(lo)
	sess.fm.step(0.2, sess.world.ground)
	sess.state = sess.fm.state()


static func takeoff_trial(key: String, code: String, load: String) -> Dictionary:
	var s := _session(key, code)
	load_aircraft(s, LOADS[load][0], LOADS[load][1])
	var w := s.state.weight_lb
	var af := World.airfield(code)
	# a point 3 km toward the nearest other field: the bot picks its own takeoff
	# direction and has to get round any high ground on the way
	var far: Airfield = Py.min_by(World.AIRFIELDS.filter(func(a): return a.code != code),
		func(a): return PyMath.hypot(a.x - af.x, a.y - af.y))
	var d := PyMath.hypot(far.x - af.x, far.y - af.y)
	var tx := af.x + (far.x - af.x) / d * 3000
	var ty := af.y + (far.y - af.y) / d * 3000
	var bot := PilotBot.new(s, [PilotBot.Leg.new("goto", tx, ty)])
	var t0 := s.time
	PilotBot.fly(s, bot, 400)
	var ok: bool = s.phase == "flying" and bot.phase in ["enroute", "done"] and not Py.truthy(s.fm.crash_reason)
	if bot.leg_i >= 1:
		ok = true
	var outcome: String = s.last_outcome if s.last_outcome != "" else (bot.outcome if bot.outcome != null else "")
	var r := _trial(key, code, load, "takeoff", ok, outcome, w, s.time - t0)
	s.dispose()
	return r


static func landing_trial(key: String, code: String, load: String) -> Dictionary:
	var af := World.airfield(code)
	var start := "HAR" if code != "HAR" else "VAL"
	var s := _session(key, start)
	load_aircraft(s, LOADS[load][0], LOADS[load][1])
	var w := s.state.weight_lb
	var roll := s.spec.est_landing_roll(w, s.world.airfield_elev(af))
	var ap := PilotBot.plan_approach(s.world, af, s.fm.mass.gear_height_ft * 0.3048, roll)
	var dist := minf(5000.0, 320.0 / tan(Py.radians(ap.gamma))) + 2500
	var xy := ap.point(dist)
	var agl := maxf(ap.path_alt(dist) - s.world.ground(xy[0], xy[1]), 250.0)
	s.spawn_airborne(xy[0], xy[1], ap.hdg, agl, s.spec.approach_kts * 1.3)
	var bot := PilotBot.new(s, [PilotBot.Leg.new("land", af.x, af.y, code)])
	bot.phase = "enroute"
	var t0 := s.time
	PilotBot.fly(s, bot, 600)
	var ok: bool = s.phase == "parked" and s.location == code
	var r := _trial(key, code, load, "landing", ok, s.last_outcome if not ok else "landed", w, s.time - t0)
	s.dispose()
	return r


## One worker job: [test, aircraft, field, load].
static func run_job(j: Array) -> Dictionary:
	if j[0] == "takeoff":
		return takeoff_trial(j[1], j[2], j[3])
	return landing_trial(j[1], j[2], j[3])


static func jobs(aircraft = null, fields = null, loads = null) -> Array:
	var out := []
	for k in (aircraft if aircraft != null else Aircraft.ROSTER.keys()):
		for c in (fields if fields != null else World.AIRFIELDS.map(func(a): return a.code)):
			for ld in (loads if loads != null else LOADS.keys()):
				for t in ["takeoff", "landing"]:
					out.append([t, k, c, ld])
	return out


static func sweep(workers := 4, aircraft = null, fields = null, loads = null) -> Array:
	var js := jobs(aircraft, fields, loads)
	if workers <= 1:
		return js.map(run_job)
	return WorkerPool.map("feasibility", js, workers)


static func _mark(r) -> String:
	if r == null:
		return "·"
	return "✓" if Py.truthy(r["ok"]) else "✗"


## Markdown: rows = aircraft/load, cols = fields, cell = T/L pass marks.
static func table(results: Array) -> String:
	var fields := World.AIRFIELDS.map(func(a): return a.code)
	var by := {}
	var keys := {}
	for r in results:
		by["%s|%s|%s|%s" % [r["aircraft"], r["load"], r["field"], r["test"]]] = r
		keys["%s|%s" % [r["aircraft"], r["load"]]] = [r["aircraft"], r["load"]]
	var rorder: Array = Aircraft.ROSTER.keys()
	var lorder: Array = LOADS.keys()
	var ordered := Py.sorted_by(keys.values(), func(k): return rorder.find(k[0]) * 100 + lorder.find(k[1]))
	var lines := ["| aircraft | load | " + " | ".join(fields) + " |", "|---|---|" + "---|".repeat(fields.size())]
	for k in ordered:
		var cells := []
		for f in fields:
			var t = by.get("%s|%s|%s|takeoff" % [k[0], k[1], f])
			var la = by.get("%s|%s|%s|landing" % [k[0], k[1], f])
			cells.append("L%s T%s" % [_mark(la), _mark(t)])
		lines.append("| %s | %s | " % [Aircraft.ROSTER[k[0]].name, k[1]] + " | ".join(cells) + " |")
	return "\n".join(lines)
