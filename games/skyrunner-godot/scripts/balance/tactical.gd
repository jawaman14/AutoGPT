class_name Tactical
extends RefCounted
## Tactical balance: the pilot bot flies real runs against the AI task force
## (port of skyrunner/sim/tactical.py).
##
## Each trial is one night's main run in a full Session (JSBSim, radar, police
## units, boats, cutters) under one law configuration, flown with one runner
## tactic. The rates it measures are used two ways:
##
##   1. directly, to judge the cops-vs-smugglers game people play in 3D
##      (is low flying a free win? can the helicopter ever catch anything?)
##   2. to calibrate `HQ.resolve_abstract`, so thousands of simulated seasons
##      rest on flown numbers rather than guesses

## zone -> [origin, destination or "SEA"]
const MISSIONS := {"west": ["FRM", "QRY"], "north": ["FRM", "EGL"], "sea": ["COV", "SEA"]}

const BOT_CRASH_CAP := 0.06

## name: [heli, interceptor, cutter, aerostat, patrol_match, tip]
const LAW_CONFIGS := {
	"light": [1, 0, 0, false, false, false],
	"standard": [1, 1, 1, false, false, false],
	"heavy": [2, 2, 1, false, false, false],
	"aerostat": [1, 1, 1, true, false, false],
	"patrol": [1, 1, 1, false, true, false],
	"tipped": [1, 1, 1, false, false, true],
	"all_in": [2, 2, 1, true, true, true],
}
const TACTICS := {
	"low": {"agl_m": 50.0, "transponder_off": true, "lookahead_s": 35.0},
	"high": {"agl_m": 450.0, "transponder_off": false, "evade": false},
	"evasive": {"agl_m": 50.0, "evade_agl_m": 45.0, "transponder_off": true, "lookahead_s": 35.0},  # + scanner & detector
}


static func _trial(zone: String, law: String, tactic: String, aircraft: String, seed: int) -> Dictionary:
	return {"zone": zone, "law": law, "tactic": tactic, "aircraft": aircraft, "seed": seed, "detected": false,
		"flagged": false, "intercepted": false, "busted": false, "crashed": false, "delivered": false,
		"boat_seized": false, "outcome": "", "minutes": 0.0, "first_detect_s": null}


static func _contraband_job(origin: String, dest: String, rng: PyRandom) -> Jobs.Job:
	var jid := Jobs.new_id()
	var c: Array = Jobs.CONTRABAND[0]
	var items := []
	for i in 3:
		items.append(Jobs.item(c[0], "cargo", rng.uniform(c[1], c[2]), jid, {"hot": true}))
	return Jobs.Job.new(jid, "No questions asked -> " + dest, "contraband", origin, dest, items, 6000)


## `trace`, if given, collects one row per second (debugging parity with Python).
static func run_trial(zone: String, law: String, tactic: String, seed: int, aircraft := "c172p", trace = null) -> Dictionary:
	var st = setup_trial(zone, law, tactic, seed, aircraft)
	if st is String:
		var t := _trial(zone, law, tactic, aircraft, seed)
		t["outcome"] = "error: " + st
		return t
	var s: Session = st[0]
	var bot: PilotBot = st[1]
	var job: Jobs.Job = st[2]
	var tr := _trial(zone, law, tactic, aircraft, seed)
	var events := {}
	s.bus.subscribe("*", func(ev): events[ev.kind] = true)
	var frame := func(sess: Session):
		var c = sess.police.cases.get("runner")
		if c != null and (Py.truthy(c.detected_by) or c.wanted) and not tr["detected"]:
			tr["detected"] = true
			tr["first_detect_s"] = sess.time
		if c != null and c.wanted:
			tr["flagged"] = true
		if Py.any(sess.police.units, func(u): return u.sees_player and u.faction() == "police" and u.target_id == "runner"):
			tr["intercepted"] = true
		if trace != null and Py.round_int(sess.time * 30) % 30 == 0:
			var fs := sess.state
			trace.append([sess.time, bot.phase, fs.x, fs.y, fs.alt, sess.police.suspicion, sess.police.wanted,
				sess.police.units.map(func(u): return [u.id, u.x, u.y, u.z, u.state, u.target_id])])
	var out := PilotBot.fly(s, bot, 2400, 1.0 / 30, frame)
	# a hot load on a strip takes a minute to unload: the police may yet arrive
	var t_end := s.time + 120
	while not s.unloading.is_empty() and s.time < t_end and s.phase == "parked":
		s.update(1.0 / 10)
	# let the boat finish its trip to the cove (airdrops pay on arrival)
	if job.is_airdrop() and not (s.phase in ["crashed", "busted"]):
		t_end = s.time + 900
		while s.time < t_end and not job.resolved:
			s.update(1.0 / 10)
	tr["busted"] = s.phase == "busted" or events.has("busted")
	tr["crashed"] = s.phase == "crashed" or events.has("crashed")
	tr["boat_seized"] = events.has("boat_seized")
	tr["delivered"] = events.has("job_delivered") or (events.has("bales_delivered") and not tr["boat_seized"])
	tr["outcome"] = s.last_outcome if s.last_outcome != "" else out
	tr["minutes"] = s.time / 60
	s.dispose()
	return tr


## The trial's world, job, bot and police posture, ready to fly: [session, bot, job],
## or an error string. The demo recorder flies the same setup in real time.
static func setup_trial(zone: String, law: String, tactic: String, seed: int, aircraft := "c172p"):
	var rng := PyRandom.new()
	rng.seed(seed)
	var od: Array = MISSIONS[zone]
	var origin: String = od[0]
	var dest: String = od[1]
	var cfg: Array = LAW_CONFIGS[law]
	var s := Session.new({"seed": seed, "location": origin, "owned": [aircraft], "aircraft_key": aircraft,
		"features": ["contraband", "airdrop", "interceptors", "cutters", "df", "rivals"]})
	s.police.features.erase("rivals")  # measure the law, not the rival gangs
	s.police.features["aerostat"] = true  # available, but only raised when the posture says so
	s.police.stock = {"heli": cfg[0], "interceptor": cfg[1], "cutter": cfg[2]}
	if tactic == "evasive":
		for g in ["scanner", "detector"]:
			s.gear[g] = true
			s.features[g] = true
	s.set_copilot("ai")
	s.transponder = true
	s.update(1.0 / 30)  # settle on the ramp
	var job: Jobs.Job
	if dest == "SEA":
		job = Jobs.airdrop_job(World.airfield(origin), Maritime.random_drop_point(s.world, rng, s.maritime.cove), rng)
	else:
		job = _contraband_job(origin, dest, rng)
	s.boards[origin] = [job]
	var err = s.accept_job(job)
	if err != null:
		s.dispose()
		return str(err)
	s.loadout.auto_balance()
	s.loadout.pending.clear()
	s.fm.apply_loadout(s.loadout)
	var af := World.airfield(origin)
	var legs := []
	if job.is_airdrop():
		legs = [PilotBot.Leg.new("drop", job.drop_point[0], job.drop_point[1]), PilotBot.Leg.new("land", af.x, af.y, origin)]
	else:
		var d := World.airfield(dest)
		legs = [PilotBot.Leg.new("land", d.x, d.y, dest)]
	s.set_fuel(PilotBot.plan_fuel_lb(s, legs))
	var bot := PilotBot.new(s, legs, PilotBot.BotStyle.make(TACTICS[tactic]))
	# the night's law posture
	if cfg[3]:
		s.police.set_aerostat(true)
		s.police.aerostat_ready_t = s.time  # already up
	if cfg[4]:
		s.police.launch("heli", null, null, HQ.ZONE_CENTRE[zone])
	if cfg[2] and (cfg[4] or zone == "sea"):
		s.police.stock["cutter"] -= 1  # on picket offshore, not tied up in the harbour
		s.maritime.new_cutter(null, _picket_point("sea", rng))
	if cfg[5]:
		var txy: Array = s.job_xy(job)
		s.police.features["informants"] = true
		s.police.add_tip(txy[0] + rng.uniform(-1200, 1200), txy[1] + rng.uniform(-1200, 1200), 2500,
			"informant: a load moves tonight", s.squawk, "runner")
	return [s, bot, job]


static func _picket_point(zone: String, rng: PyRandom) -> Array:
	var c: Array = HQ.ZONE_CENTRE[zone]
	return [c[0] + rng.uniform(-3000, 3000), c[1] + rng.uniform(-3000, 3000)]


## One worker job: [zone, law, tactic, seed, aircraft].
static func run_job(j: Array) -> Dictionary:
	return run_trial(j[0], j[1], j[2], int(j[3]), j[4])


static func jobs(seeds := 4, zones = null, laws = null, tactics = null, aircraft := "c172p") -> Array:
	var out := []
	for z in (zones if zones != null else MISSIONS.keys()):
		for l in (laws if laws != null else LAW_CONFIGS.keys()):
			for t in (tactics if tactics != null else TACTICS.keys()):
				for i in seeds:
					out.append([z, l, t, 100 + i, aircraft])
	return out


static func sweep(seeds := 4, workers := 4, zones = null, laws = null, tactics = null, aircraft := "c172p") -> Array:
	var js := jobs(seeds, zones, laws, tactics, aircraft)
	if workers <= 1:
		return js.map(run_job)
	return WorkerPool.map("tactical", js, workers)


static func _b(v) -> float:
	return 1.0 if Py.truthy(v) else 0.0


static func rates(results: Array, where := {}) -> Dictionary:
	var rs := results.filter(func(r):
		for k in where:
			if r[k] != where[k]:
				return false
		return not str(r["outcome"]).begins_with("error"))
	var n := rs.size()
	if n == 0:
		return {"n": 0}
	var f := func(k: String) -> float:
		return Py.sum_by(rs, func(r): return _b(r[k])) / n
	var det := rs.filter(func(r): return Py.truthy(r["flagged"]))
	var inter := rs.filter(func(r): return Py.truthy(r["intercepted"]))
	return {
		"n": n, "detected": f.call("detected"), "flagged": f.call("flagged"), "intercepted": f.call("intercepted"),
		"busted": f.call("busted"), "crashed": f.call("crashed"), "delivered": f.call("delivered"),
		"boat_seized": f.call("boat_seized"),
		"intercept_if_flagged": Py.sum_by(det, func(r): return _b(r["intercepted"])) / det.size() if det else null,
		"bust_if_intercepted": Py.sum_by(inter, func(r): return _b(r["busted"])) / inter.size() if inter else null,
	}


## Fit HQ.Calibration to flown results. The abstract resolver's 'detected'
## means the task force has decided it's a smuggler, i.e. our 'flagged'.
## Intercept hazard of one posture's flagged flights (null with fewer than six).
static func posture_hazard(results: Array, law: String):
	var flagged := results.filter(func(r): return r["law"] == law and Py.truthy(r["flagged"]))
	if flagged.size() < 6:
		return null
	var p := Py.sum_by(flagged, func(r): return _b(r["intercepted"])) / flagged.size()
	return minf(3.0, -log(maxf(0.05, 1 - p)) / 0.8)


## `postures` ["standard"] reproduces Python's fit exactly.
static func calibrate(results: Array, postures := ["standard", "heavy"]) -> HQ.Calibration:
	var cal := HQ.Calibration.new()
	for z in MISSIONS:
		var base := rates(results, {"zone": z, "law": "standard"})
		var aer := rates(results, {"zone": z, "law": "aerostat"})
		if base.get("n", 0) >= 4:
			cal.detect[z] = Py.round_n(minf(0.9, base["flagged"]), 3)
			# the bot crashes more than a competent human on low-level legs: cap it
			cal.crash[z] = Py.round_n(minf(BOT_CRASH_CAP, maxf(0.01, base["crashed"])), 3)
		if aer.get("n", 0) >= 4 and base.get("n", 0) >= 4:
			cal.aerostat_detect[z] = Py.round_n(maxf(0.0, aer["flagged"] - base["flagged"]), 3)
	# intercept hazard per posture: k * ln(1 + weighted units) * patrol match (0.8 elsewhere).
	# Standard and heavy fly the same routes with 1+1 and 2+2 units, so a least-squares
	# fit through both tests the diminishing-returns curve instead of assuming it.
	var num := 0.0
	var den := 0.0
	for law in postures:
		var h = posture_hazard(results, law)
		if h == null:
			continue
		var cfg: Array = LAW_CONFIGS[law]
		var l := PyMath.log1p(cfg[0] * cal.intercept_per_unit["heli"] + cfg[1] * cal.intercept_per_unit["interceptor"])
		num += h * l
		den += l * l
	if den > 0:
		cal.intercept_k = Py.round_n(num / den, 3)
	var inter := results.filter(func(r): return Py.truthy(r["intercepted"]))
	if inter.size() >= 6:
		cal.bust_given_intercept = Py.round_n(minf(0.9, Py.sum_by(inter, func(r): return _b(r["busted"])) / inter.size()), 3)
	return cal
