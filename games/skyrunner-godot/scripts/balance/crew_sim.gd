class_name CrewSim
extends RefCounted
## What a second pair of hands is worth. The pilot bot flies the tactical sweep's
## sea mission (airdrop to a go-fast boat, standard police) three ways:
##   solo   no co-pilot: autopilot on, the pilot goes aft and kicks (4 s a bale)
##   ai     the AI co-pilot's habits (auto-kick over the rendezvous, 2 s a bale)
##   human  a scripted human co-pilot through the command gate: calls the boat on
##          the way in, kicks the load in one go over the drop
## and measures time over the drop, bales delivered, detection, busts and crashes.
## `loading_times` measures ramp loading with and without the co-pilot.

const CREWS := ["solo", "ai", "human"]
const CALL_BOAT_M := 3000.0
const KICK_M := 450.0


static func jobs(seeds := 10, tactics := ["low", "high"]) -> Array:
	var out := []
	for c in CREWS:
		for t in tactics:
			for i in seeds:
				out.append([c, t, 100 + i])
	return out


static func run_job(j: Array) -> Dictionary:
	return run_trial(j[0], j[1], int(j[2]))


static func run_trial(crew: String, tactic: String, seed: int) -> Dictionary:
	var tr := {"crew": crew, "tactic": tactic, "seed": seed, "kicked": 0, "bales": 0, "delivered_bales": 0,
		"over_drop_s": 0.0, "flagged": false, "busted": false, "crashed": false, "boat_called": false,
		"outcome": "", "minutes": 0.0}
	var st = Tactical.setup_trial("sea", "standard", tactic, seed)
	if st is String:
		tr["outcome"] = "error: " + st
		return tr
	var s: Session = st[0]
	var bot: PilotBot = st[1]
	var job: Jobs.Job = st[2]
	s.set_copilot({"solo": null, "ai": "ai", "human": "human"}[crew])
	s.auto_kick = crew == "ai"
	tr["bales"] = s._droppables().size()
	var events := {}
	s.bus.subscribe("*", func(ev):
		events[ev.kind] = true
		if ev.kind == "bale_kicked":
			tr["kicked"] += 1
		elif ev.kind == "bales_delivered":
			tr["delivered_bales"] += int(ev.data.get("count", 0)))
	var drop: Array = job.drop_point
	var frame := func(sess: Session):
		var fs := sess.state
		var d := PyMath.hypot(fs.x - drop[0], fs.y - drop[1])
		if d < 1500.0 and not sess._droppables().is_empty():
			tr["over_drop_s"] += 1.0 / 30
		var c = sess.police.cases.get("runner")
		if c != null and c.wanted:
			tr["flagged"] = true
		if crew != "human" or fs.on_ground:
			return
		# the human co-pilot: boat on the way in, the whole load out over the mark
		if d < CALL_BOAT_M and not tr["boat_called"]:
			tr["boat_called"] = sess.command(Roles.COPILOT, "call_boat")[0]
		if d < KICK_M and sess.kick_queue == 0 and not sess._droppables().is_empty() \
				and fs.ias_kts <= Session.KICK_MAX_KTS:
			sess.command(Roles.COPILOT, "kick", {"count": sess._droppables().size()})
	var out := PilotBot.fly(s, bot, 2400, 1.0 / 30, frame)
	# the boat's run to the cove pays per bale
	var t_end := s.time + 900
	while s.time < t_end and not job.resolved and not (s.phase in ["crashed", "busted"]):
		s.update(1.0 / 10)
	tr["busted"] = s.phase == "busted" or events.has("busted")
	tr["crashed"] = s.phase == "crashed" or events.has("crashed")
	tr["outcome"] = s.last_outcome if s.last_outcome != "" else out
	tr["minutes"] = s.time / 60
	s.dispose()
	return tr


static func sweep(seeds := 10, workers := 4) -> Array:
	var js := jobs(seeds)
	if workers <= 1:
		return js.map(run_job)
	return WorkerPool.map("crew", js, workers)


## Ramp loading time (s) for a four-item job at a bush strip, with and without a co-pilot.
static func loading_times(seed := 5) -> Dictionary:
	var out := {}
	for crew in [null, "human"]:
		var s := Session.new({"seed": seed, "location": "FRM"})
		s.set_copilot(crew)
		for i in 18:
			s.update(1.0 / 60)
		var job: Jobs.Job = Py.first(s.boards["FRM"], func(j): return j.items.size() >= 2 \
			and not Py.any(j.items, func(i): return i.kind == "passenger"))
		s.accept_job(job)
		var t := 0.0
		while not s.loadout.pending.is_empty() and t < 300:
			for i in 30:
				s.update(1.0 / 60)
			t += 0.5
		out["copilot" if crew else "solo"] = t
		s.dispose()
	return out


static func table(results: Array) -> Array:
	var rows := []
	for c in CREWS:
		var rs := results.filter(func(r): return r["crew"] == c and not str(r["outcome"]).begins_with("error"))
		var n := rs.size()
		if n == 0:
			continue
		var bales := Py.sum_by(rs, func(r): return float(r["bales"]))
		rows.append({"crew": c, "n": n,
			"kicked": Py.sum_by(rs, func(r): return float(r["kicked"])) / maxf(1.0, bales),
			"delivered": Py.sum_by(rs, func(r): return float(r["delivered_bales"])) / maxf(1.0, bales),
			"over_drop_s": Py.sum_by(rs, func(r): return float(r["over_drop_s"])) / n,
			"flagged": Py.sum_by(rs, func(r): return 1.0 if r["flagged"] else 0.0) / n,
			"busted": Py.sum_by(rs, func(r): return 1.0 if r["busted"] else 0.0) / n,
			"crashed": Py.sum_by(rs, func(r): return 1.0 if r["crashed"] else 0.0) / n,
			"minutes": Py.sum_by(rs, func(r): return float(r["minutes"])) / n})
	return rows
