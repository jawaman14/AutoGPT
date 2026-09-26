class_name NightDirector
extends RefCounted
## Nights: the bridge between the HQ season (HQ.Season) and the live Session.
##
##   planning   the runner crew is on the ground; both HQs give orders (humans
##              through the station, or HQ bots). The pilot loads up meanwhile.
##   operation  starts when the pilot takes off with something hot. The plan is
##              applied to the world: police aircraft and boats, aerostat,
##              patrol, informant tips, bribes, contract crews and decoys.
##   wrap-up    the pilot's flight has ended; once the crews and decoys are done
##              too, the night is scored and the next planning phase begins.

const WRAP_TIMEOUT_S := 600.0


static func zone_of(job: Jobs.Job) -> String:
	if job.is_airdrop():
		return "sea"
	for zone in HQ.ZONE_FIELDS:
		if HQ.ZONE_FIELDS[zone].has(job.dest):
			return zone
	return "west"


var sess  ## Session
var season: HQ.Season
var runner_ai  ## policy name, or null when a human boss is seated
var law_ai
var phase := "planning"
var main: HQ.RunResult
var crews: Array = []
var ended_at = null
var _ai_mem := [{}, {}]
var _bot_rng: PyRandom
var _ai_planned := false
var _paid_before := 0


func _init(sess_, runner_ai_ = "adaptive", law_ai_ = "adaptive", rules := {}) -> void:
	sess = sess_
	var r := PyRandom.new()
	r.seed(sess.seed + 404)
	season = HQ.Season.new(r, rules)
	runner_ai = runner_ai_
	law_ai = law_ai_
	_bot_rng = PyRandom.new()
	_bot_rng.seed(sess.seed + 505)
	sess.money = int(season.org.dirty)  # the organisation's war chest is the crew's cash
	_show_forecast()
	sess.bus.subscribe("hijacked", func(_ev):
		if phase == "operation" and main != null:
			main.hijacked = true)


# ------------------------------------------------------------ money sync
func _pull() -> void:
	var o := season.org
	o.dirty = int(sess.money)
	o.gear = sess.gear.duplicate()
	var keys := HQ.AIRCRAFT_TIERS.map(func(t): return t[0])
	var tier := 0
	for k in sess.owned:
		if keys.has(k):
			tier = maxi(tier, keys.find(k))
	o.tier = tier


func _push() -> void:
	sess.money = int(season.org.dirty)
	for g in ["scanner", "detector"]:
		if season.org.gear.has(g):
			sess.gear[g] = true


## An HQ order from a human (via Session.command) or a bot.
func order(side: String, name: String, args := {}):
	if season.phase == "over":
		return "The season is over: %s (%s)." % [season.winner, season.reason]
	if phase != "planning":
		return "HQ orders wait until the crew is back on the ground."
	_pull()
	var err = season.runner_cmd(name, args) if side == "runner" else season.law_cmd(name, args)
	_push()
	return err


func _run_ai() -> void:
	_pull()
	if runner_ai:
		HQBots.RUNNER_POLICIES[runner_ai].call(season, _bot_rng, _ai_mem[0])
	if law_ai:
		HQBots.LAW_POLICIES[law_ai].call(season, _bot_rng, _ai_mem[1])
	_push()
	_ai_planned = true


# ------------------------------------------------------------ tick
func tick(dt: float) -> void:
	if season.phase == "over":
		return
	if phase == "planning":
		if not _ai_planned:
			_run_ai()
		if sess.phase == "flying" and sess.carrying_hot():
			_begin()
	elif phase == "operation":
		_track()
		if (sess.phase in ["crashed", "busted"] or (sess.phase == "parked" and sess.unloading.is_empty())) \
				and ended_at == null:
			ended_at = sess.time
			_close_main()
		if ended_at != null:
			var busy := crews.filter(func(a): return a.active())
			if busy.is_empty() or sess.time - ended_at > WRAP_TIMEOUT_S:
				_finish()


# ------------------------------------------------------------ operation
func _begin() -> void:
	var ss := season
	var hot: Array = sess.active_jobs.filter(func(j): return j.hot())
	var zone := zone_of(hot[0]) if not hot.is_empty() else "west"
	_pull()
	var planned := ss.org.route
	ss.org.route = zone
	var plan := ss.start_operation()
	plan["planned_route"] = planned  # the canary trap compares what HQ planned with what was flown
	if plan.has("weather"):
		sess.set_weather(plan["weather"])
		if plan["weather"] != ss.forecast:
			sess.say("The forecast was wrong: %s, %d kt." % [plan["weather"]["sky"], int(plan["weather"]["wind_kt"])])
	phase = "operation"
	ended_at = null
	main = HQ.RunResult.new("main", zone)
	_paid_before = sess.money
	var ps: PoliceSystem = sess.police
	ps.stock = {"heli": plan["funded"]["heli"], "interceptor": plan["funded"]["interceptor"], "cutter": plan["cutters"]}
	for f in ["interceptors", "cutters", "aerostat", "informants"]:
		ps.features[f] = true
	if plan["aerostat"]:
		ps.set_aerostat(true)
	sess.radio.encrypted = plan["encryption"]
	ps.no_customs = plan["no_customs"]
	if plan["patrol"] and ps.stock.get("heli", 0) > 0:
		ps.launch("heli", null, null, HQ.ZONE_CENTRE[plan["patrol"]])
	# spares patrol where the analysts expect the organisation, the ordered patrol zone aside
	var expect: Dictionary = ss.pattern_exposure()
	var zones: Array = Py.sorted_by(HQ.ZONES.filter(func(z): return z != plan["patrol"]), func(z): return -float(expect[z]))
	ps.patrol_spares(zones)
	# funded cutters start the night on picket off the coast, not in the harbour
	var rng := _bot_rng
	for i in plan["cutters"]:
		var c: Array = HQ.ZONE_CENTRE["sea"]
		ps.stock["cutter"] -= 1
		var px: float = c[0] + rng.uniform(-3000, 3000)
		var py: float = c[1] + rng.uniform(-3000, 3000)
		sess.maritime.new_cutter(null, [px, py])
	if plan["tip"] and not hot.is_empty():
		var p: Array = sess.job_xy(hot[0])
		var tx: float = p[0] + rng.uniform(-1500, 1500)
		var ty: float = p[1] + rng.uniform(-1500, 1500)
		ps.add_tip(tx, ty, 3000, "informant: the organisation moves a load tonight", sess.squawk, "runner")
	if plan["leak_patrol"] or plan.get("leak_aerostat"):
		sess.say("Your man in dispatch: patrol over the %s tonight" % [plan["leak_patrol"] if plan["leak_patrol"] else "nowhere"]
			+ (", and the balloon is up." if plan.get("leak_aerostat") else "."))
	# contract crews and decoys
	crews = []
	for k in plan["crews"] + plan["decoys"]:
		crews.append(_spawn_run(k >= plan["crews"]))
	# the rival cartel flies tonight too; meet them on your route and they come for your load
	if plan.has("rival_zone"):
		for k in plan["rival_runs"]:
			var a := _spawn_run(false)
			a.kind = "rival"
			a.id = "Cuervo-%d" % sess.director.serial
		ps.features.erase("rivals")
		if season.rrng.random() < plan["hijack_p"] and not hot.is_empty():
			var p: Array = sess.job_xy(hot[0])
			ps.features["rivals"] = true
			ps._rival_spawned["runner"] = true
			ps.spawn_rival(p, "runner")
			sess.say("Radio chatter in Spanish on the company frequency. Company tonight.")
		if plan.get("rival_tipped"):
			ps.add_tip(HQ.ZONE_CENTRE[plan["rival_zone"]][0], HQ.ZONE_CENTRE[plan["rival_zone"]][1], 4000,
				"anonymous caller: a Cuervos plane moves tonight", "", null)
	sess.say("Night %d: operation under way (%d crews, %d decoys)." % [plan["night"], plan["crews"], plan["decoys"]])
	sess.law_say("Night %d: operations begin." % plan["night"])


func _spawn_run(decoy: bool) -> AISmuggler:
	var rng: PyRandom = sess.director.rng
	sess.director.serial += 1
	var ee := AISmuggler.entry_and_exit(rng)
	var drop := Maritime.random_drop_point(sess.world, rng, sess.maritime.cove)
	var jid := Jobs.new_id()
	var a := AISmuggler.new("Runner-%d" % sess.director.serial, ee[0][0], ee[0][1], 150.0, ee[2], drop, ee[1], jid,
		{"bales_left": 0 if decoy else rng.randint(4, 6), "hot": not decoy, "kind": "decoy" if decoy else "crew"})
	sess.smugglers.append(a)
	if not decoy:
		sess.maritime.new_gofast(drop, jid)
	return a


func _track() -> void:
	var c: PoliceSystem.Case = sess.police.cases.get("runner")
	if c and (c.detected_by or c.wanted):
		main.detected = true
	if Py.any(sess.police.units, func(u): return u.sees_player and u.target_id == "runner" and u.faction() == "police"):
		main.intercepted = true


func _close_main() -> void:
	var m := main
	m.busted = sess.phase == "busted"
	m.crashed = sess.phase == "crashed"
	m.delivered_value = maxi(0, sess.money - _paid_before)
	if m.busted:
		var hot_pay := 0
		for j in sess.active_jobs:
			if j.hot():
				hot_pay += j.payout
		m.seized_value = maxi(6000, hot_pay * 3)


func _finish() -> void:
	var ss := season
	var runs := [main]
	for a in crews:
		var kind := "rival" if a.kind == "rival" else ("decoy" if not a.hot else "crew")
		var r := HQ.RunResult.new(kind, ss.plan.get("rival_zone", "sea") if kind == "rival" else "sea")
		r.busted = a.state == "busted" and a.hot
		r.clean_stop = a.state == "busted" and not a.hot
		r.crashed = a.state == "crashed"
		var boat: Maritime.Boat = sess.maritime.gofast_for(a.job_id)
		r.boat_seized = boat != null and boat.state == "seized"
		if a.hot and not (r.busted or r.crashed or r.boat_seized):
			r.delivered_value = int(ss.rules["run_payout"])
		if r.busted or r.boat_seized:
			r.seized_value = int(ss.rules["run_payout"]) * 3
		runs.append(r)
		if a.active():
			a.state = "escaped"
	_pull()
	var rep := ss.finish_night(runs, true)
	# ground_turf (live play only; the season sims never have a ground war): who
	# held the streets tonight nudges the rivals' turf, at most 0.06 a zone
	if sess.ground != null and ss.rival != null:
		for z in HQ.ZONES:
			var d: float = sess.ground.turf_delta(z)
			if absf(d) >= 0.005:
				ss.rival.turf[z] = clampf(ss.rival.turf[z] + d, 0.05, 0.9)
				sess.say("NEWS: %s %s ground in the %s" % [ss.rival.name, "gained" if d > 0 else "lost", z])
	_push()
	for line in rep.lines:
		sess.say("NEWS: " + line)
		sess.law_say("NEWS: " + line)
	for line in rep.runner_lines:
		sess.say(line)
	for line in rep.law_lines:
		sess.law_say(line)
	sess.police.no_customs = false
	phase = "planning"
	crews = []
	if ss.phase == "over":
		var text := "SEASON OVER - %s wins: %s" % ["the Organisation" if ss.winner == "runner" else "the Task Force", ss.reason]
		sess.say(text)
		sess.law_say(text)
		return
	ss.next_night()
	_show_forecast()
	_push()  # tonight's overheads and standing bribes came off the books
	_ai_planned = false
	sess.say("Night %d of %d: HQ is planning." % [ss.night, int(ss.rules["nights"])])


## While HQ plans, the sky outside is the forecast.
func _show_forecast() -> void:
	if season.forecast.is_empty():
		return
	sess.set_weather(season.forecast)
	var f := season.forecast
	sess.say("Forecast: %s, wind %03d at %d kt, moon %d%%." % [f["sky"], int(f["wind_dir"]), int(f["wind_kt"]), int(float(f["moon"]) * 100)])


# ------------------------------------------------------------ views
func view(side: String) -> Dictionary:
	var v := season.view(side)
	v["director_phase"] = phase
	return v
