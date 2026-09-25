class_name HQBots
extends RefCounted
## HQ bots: strategy archetypes for the Organisation and the Task Force.
##
## Each policy is `policy(season, rng, memory)`: it issues orders through the
## same runner_cmd / law_cmd gate a human uses, then says ready. They fill empty
## HQ seats and are pitted against each other thousands of times by the
## strategic simulator to find dominant strategies and dead mechanics.
## Archetypes are deliberately one-dimensional; 'adaptive' mixes them and
## 'random' explores everything (which tells us what each action is worth).

static var RUNNER_POLICIES := {
	"greedy": runner_greedy, "cautious": runner_cautious, "corrupt": runner_corrupt,
	"shadow": runner_shadow, "launderer": runner_launderer, "adaptive": runner_adaptive,
	"smart": runner_smart, "random": runner_random,
}
static var LAW_POLICIES := {
	"interdiction": law_interdiction, "investigator": law_investigator, "balanced": law_balanced,
	"adaptive": law_adaptive, "random": law_random,
}

const DANGER := {"thin": 0, "building": 1, "serious": 2, "closing in": 3}


# ------------------------------------------------------------------ helpers
static func _launder_all(ss: HQ.Season) -> void:
	ss.runner_cmd("launder")


static func _pick_route(ss: HQ.Season, rng: PyRandom, mem: Dictionary, avoid = null) -> void:
	var zones := HQ.ZONES.filter(func(z): return z != avoid)
	if zones.is_empty():
		zones = HQ.ZONES.duplicate()
	# don't be predictable: avoid last night's route half the time
	var last = mem.get("last_route")
	if zones.has(last) and zones.size() > 1 and rng.random() < 0.5:
		zones.erase(last)
	var z: String
	if ss.on("pattern"):
		# the analysts expect you where they've seen you: mix it up (the inspection game's answer)
		var ex := ss.pattern_exposure()
		var w := PackedFloat64Array()
		for zz in zones:
			w.append(maxf(0.1, 1.0 - 2.0 * ex[zz]))
		z = zones[rng.choices_index(w, 1)[0]]
	else:
		z = rng.choice(zones)
	ss.runner_cmd("route", {"zone": z})
	mem["last_route"] = z


## Spend spare dirty money on capacity: fronts first, then aircraft.
static func _grow(ss: HQ.Season, rng: PyRandom) -> void:
	var o := ss.org
	var reserve := 12000
	if o.dirty - reserve > HQ.FRONTS["car_lot"][0] and o.capacity() < 25000:
		ss.runner_cmd("buy_front", {"kind": "car_lot" if o.dirty < 60000 else "marina"})
	elif o.dirty - reserve > 25000 and o.tier == 0:
		ss.runner_cmd("upgrade")
	elif o.dirty - reserve > HQ.FRONTS["laundromat"][0] and o.capacity() < 10000:
		ss.runner_cmd("buy_front", {"kind": "laundromat"})


## The cartel war, for bots that read the room (only when rules.rivals is on;
## no random draws otherwise, so rival-free seasons are unchanged). Call after
## the route is set: a hit weakens them on tonight's route.
static func _cartel(ss: HQ.Season, rng: PyRandom, mem: Dictionary) -> void:
	var rv := ss.rival
	if rv == null:
		return
	var o := ss.org
	var danger: int = DANGER[ss.view("runner")["evidence_rumor"]]
	var contested: bool = rv.turf[o.route] > 0.4
	var strong: bool = rv.band() in ["strong", "dominant"]
	var last := _last(ss)
	var hijacked := last != null and Py.any(last.runs, func(r): return r.hijacked)
	if ss.on("rival_tempers"):
		var left := int(ss.rules["nights"]) - ss.night
		# backward induction: a known opportunist will sell you out at the end, so
		# don't pay for a truce then; and on the last night, defect first
		if rv.truce_nights > 0 and left <= 1 and danger >= 1:
			ss.runner_cmd("tip_off")
			return
		if rv.revealed and rv.temper == "opportunist" and left <= 2:
			hijacked = false
			strong = false
		if rv.revealed and rv.temper == "grudger" and rv.wronged > 0:
			strong = false  # no point asking
	if rv.truce_nights == 0 and rv.grudge == 0 and (strong or hijacked) and rng.random() < 0.6:
		ss.runner_cmd("truce")
	elif (strong or hijacked) and contested and o.dirty > 20000 and o.heat < 50 and rv.truce_nights == 0:
		ss.runner_cmd("hit_rival")
	if danger >= 2 and rv.truce_nights == 0 and rng.random() < 0.5:
		ss.runner_cmd("tip_off")  # hand the task force someone else to chase


## Route choice that also weighs the rivals' grip on each market.
static func _rival_route_weights(ss: HQ.Season, base: Array) -> PackedFloat64Array:
	var w := PackedFloat64Array(base)
	if ss.rival != null:
		for i in HQ.ZONES.size():
			w[i] *= 1.0 - ss.rules["rival_market"] * ss.rival.turf[HQ.ZONES[i]]
	return w


static func _last(ss: HQ.Season) -> HQ.NightReport:
	return ss.reports.back() if not ss.reports.is_empty() else null


# ------------------------------------------------------------------ organisation
## Fly everything, every night, over the richest route. Spend on growth.
static func runner_greedy(ss: HQ.Season, rng: PyRandom, mem: Dictionary) -> void:
	ss.runner_cmd("route", {"zone": "sea"})
	ss.runner_cmd("crews", {"n": 2})
	_grow(ss, rng)
	_launder_all(ss)
	ss.runner_cmd("ready")


## Lawyer on retainer, loyal crews, burner phones, lie low when hot.
static func runner_cautious(ss: HQ.Season, rng: PyRandom, mem: Dictionary) -> void:
	var o := ss.org
	if not o.lawyer:
		ss.runner_cmd("lawyer", {"on": true})
	if o.loyalty < 0.6:
		ss.runner_cmd("loyalty")
	var view := ss.view("runner")
	if view["evidence_rumor"] in ["serious", "closing in"] or o.heat > 70:
		ss.runner_cmd("opsec")
		if not o.counterintel:
			ss.runner_cmd("counterintel")
		if o.heat > 70:
			ss.runner_cmd("lie_low")
	else:
		ss.runner_cmd("crews", {"n": 1})
	_pick_route(ss, rng, mem)
	_launder_all(ss)
	ss.runner_cmd("ready")


## Buy the dispatcher and the harbour; fly around the patrol you know about.
static func runner_corrupt(ss: HQ.Season, rng: PyRandom, mem: Dictionary) -> void:
	var o := ss.org
	for b in ["dispatcher", "harbor"]:
		if not o.bribes.has(b) and o.dirty > HQ.BRIBES[b][0] + 6000:
			ss.runner_cmd("bribe", {"who": b})
	var leak = ss.leak_zone() if o.bribes.has("dispatcher") else null
	ss.runner_cmd("crews", {"n": 1})
	_grow(ss, rng)
	_pick_route(ss, rng, mem, leak)
	_launder_all(ss)
	ss.runner_cmd("ready")


## Decoys and misdirection; counter-intel sweeps; never the same route.
static func runner_shadow(ss: HQ.Season, rng: PyRandom, mem: Dictionary) -> void:
	var o := ss.org
	if not o.gear.has("detector") and o.dirty > 8000:
		ss.runner_cmd("gear", {"name": "detector"})
	ss.runner_cmd("decoys", {"n": 2})
	if ss.night % 3 == 0:
		ss.runner_cmd("counterintel")
	else:
		ss.runner_cmd("crews", {"n": 1})
	if o.loyalty < 0.5:
		ss.runner_cmd("loyalty")
	_pick_route(ss, rng, mem)
	_launder_all(ss)
	ss.runner_cmd("ready")


## Build the laundering pipeline early, keep the operation small and steady.
static func runner_launderer(ss: HQ.Season, rng: PyRandom, mem: Dictionary) -> void:
	var o := ss.org
	if o.dirty > HQ.FRONTS["car_lot"][0] + 4000:
		ss.runner_cmd("buy_front", {"kind": "car_lot" if o.capacity() < 20000 else "marina"})
	if ss.law.evidence > 45 and not o.lawyer:
		ss.runner_cmd("lawyer", {"on": true})
	ss.runner_cmd("crews", {"n": 1})
	_pick_route(ss, rng, mem)
	_launder_all(ss)
	ss.runner_cmd("ready")


## A reasonable human: grow while it's quiet, defend when the case builds.
static func runner_adaptive(ss: HQ.Season, rng: PyRandom, mem: Dictionary) -> void:
	var o := ss.org
	if not o.gear.has("scanner") and o.dirty > 8000:
		ss.runner_cmd("gear", {"name": "scanner"})
	var view := ss.view("runner")
	var danger: int = DANGER[view["evidence_rumor"]]
	if danger >= 2:
		if not o.lawyer:
			ss.runner_cmd("lawyer", {"on": true})
		ss.runner_cmd("opsec")
		if mem.get("informant_suspected") or danger == 3:
			ss.runner_cmd("counterintel")
		elif o.loyalty < 0.6:
			ss.runner_cmd("loyalty")
	else:
		if o.lawyer and danger == 0:
			ss.runner_cmd("lawyer", {"on": false})
		_grow(ss, rng)
		if o.dirty > 10000:
			ss.runner_cmd("crews", {"n": 1 if o.heat > 50 else 2})
	if o.heat > 55 and danger < 2 and rng.random() < 0.5:
		ss.runner_cmd("decoys", {"n": 1})
	# a bust last night smells like a rat
	var last := _last(ss)
	mem["informant_suspected"] = last != null and Py.any(last.runs, func(r): return r.busted and r.kind == "main")
	var leak = ss.leak_zone() if o.bribes.has("dispatcher") else null
	if not o.bribes.has("dispatcher") and ss.night >= 3 and o.dirty > 20000 and danger < 2:
		ss.runner_cmd("bribe", {"who": "dispatcher"})
	_pick_route(ss, rng, mem, leak)
	_cartel(ss, rng, mem)
	_launder_all(ss)
	ss.runner_cmd("ready")


## Uses every source it has: scanner, then the dispatcher, routes weighted by
## radar exposure, decoys when the heat draws attention, defence when the case
## builds, growth while it's quiet.
static func runner_smart(ss: HQ.Season, rng: PyRandom, mem: Dictionary) -> void:
	var o := ss.org
	var view := ss.view("runner")
	var danger: int = DANGER[view["evidence_rumor"]]
	if not o.gear.has("scanner") and o.dirty > 6000:
		ss.runner_cmd("gear", {"name": "scanner"})
	elif not o.bribes.has("dispatcher") and o.dirty > 12000:
		ss.runner_cmd("bribe", {"who": "dispatcher"})
	if danger >= 2:
		if not o.lawyer:
			ss.runner_cmd("lawyer", {"on": true})
		ss.runner_cmd("opsec")
		if danger == 3 or mem.get("rat"):
			ss.runner_cmd("counterintel")
	else:
		if o.lawyer and danger == 0:
			ss.runner_cmd("lawyer", {"on": false})
		if o.loyalty < 0.45:
			ss.runner_cmd("loyalty")
		_grow(ss, rng)
		var storm: bool = ss.on("weather") and ss.forecast.get("sky") == "storm"
		ss.runner_cmd("crews", {"n": 0 if storm else (1 if o.heat > 45 or o.dirty < 15000 else 2)})
	if o.heat > 40:
		ss.runner_cmd("decoys", {"n": 1})
	var last := _last(ss)
	mem["rat"] = last != null and Py.any(last.runs, func(r): return r.busted and r.kind == "main" and not r.intercepted)
	var z: String = HQ.ZONES[rng.choices_index(_rival_route_weights(ss, [0.45, 0.25, 0.30]), 1)[0]]  # west is the least watched
	if z == mem.get("last_route") and rng.random() < 0.5:
		z = rng.choice(HQ.ZONES.filter(func(x): return x != z))
	mem["last_route"] = z
	ss.runner_cmd("route", {"zone": z})
	_cartel(ss, rng, mem)
	_launder_all(ss)
	ss.runner_cmd("ready")


## Uniformly random legal orders: explores the action space for the sim.
static func runner_random(ss: HQ.Season, rng: PyRandom, mem: Dictionary) -> void:
	# argument draws happen in the same order as the Python list literal
	var a_crews := rng.randint(0, 2)
	var a_decoys := rng.randint(1, 2)
	var a_bribe = rng.choice(HQ.BRIBES.keys())
	var a_lawyer := rng.random() < 0.5
	var a_front = rng.choice(HQ.FRONTS.keys())
	var a_gear = rng.choice(["scanner", "detector"])
	var options := [
		["crews", {"n": a_crews}], ["decoys", {"n": a_decoys}], ["bribe", {"who": a_bribe}], ["loyalty", {}],
		["lawyer", {"on": a_lawyer}], ["opsec", {}], ["counterintel", {}], ["lie_low", {}], ["upgrade", {}],
		["buy_front", {"kind": a_front}], ["gear", {"name": a_gear}],
	]
	if ss.rival != null:
		options += [["hit_rival", {}], ["truce", {}], ["tip_off", {}]]
	options = rng.shuffle(options)
	if not mem.has("used"):
		mem["used"] = []
	for o in options.slice(0, 4):
		if ss.runner_cmd(o[0], o[1]) == null:
			mem["used"].append(o[0])
	_pick_route(ss, rng, mem)
	_launder_all(ss)
	ss.runner_cmd("ready")


# ------------------------------------------------------------------ task force
## Where did we see them last? Tips win; else frequency of detections, noisily.
static func _predict_zone(ss: HQ.Season, rng: PyRandom, mem: Dictionary) -> String:
	if not mem.has("seen"):
		mem["seen"] = {"west": 1.0, "north": 1.0, "sea": 1.0}
	var seen: Dictionary = mem["seen"]
	var last := _last(ss)
	if last != null:
		for r in last.runs:
			if r.detected and r.kind == "main":
				seen[r.zone] += 1.0
	var w := PackedFloat64Array()
	for z in HQ.ZONES:
		w.append(seen[z])
	return HQ.ZONES[rng.choices_index(w, 1)[0]]


## The balloon comes down in a storm or a gale: don't pay for it on that forecast.
static func _balloon_weather(ss: HQ.Season) -> bool:
	return not ss.on("weather") or (ss.forecast.get("sky") != "storm" and int(ss.forecast.get("wind_kt", 0)) <= HQ.AEROSTAT_MAX_WIND)


static func _fund_units(ss: HQ.Season, heli: int, interceptor: int, cutter: int) -> void:
	for pair in [["interceptor", interceptor], ["heli", heli], ["cutter", cutter]]:
		var n: int = pair[1]
		while n > 0 and ss.law_cmd("fund", {"unit": pair[0], "n": n}) != null:
			n -= 1


## All money into aircraft, boats and radar.
static func law_interdiction(ss: HQ.Season, rng: PyRandom, mem: Dictionary) -> void:
	ss.law_cmd("patrol", {"zone": _predict_zone(ss, rng, mem)})
	if _balloon_weather(ss):
		ss.law_cmd("aerostat")
	_fund_units(ss, 1, 2, 1)
	_fund_units(ss, 2, 2, 1)
	ss.law_cmd("ready")


## Follow the money and the people: informants, wiretaps, audits.
static func law_investigator(ss: HQ.Season, rng: PyRandom, mem: Dictionary) -> void:
	var L := ss.law
	ss.law_cmd("patrol", {"zone": _predict_zone(ss, rng, mem)})
	if L.informants < 2:
		ss.law_cmd("recruit")
	ss.law_cmd("wiretap")
	if ss.night % 2 == 0 or ss.org.heat > 40:
		ss.law_cmd("audit")
	if ss.night % 3 == 0:
		ss.law_cmd("ia_sweep")
	_fund_units(ss, 1, 0, 0)
	ss.law_cmd("ready")


static func law_balanced(ss: HQ.Season, rng: PyRandom, mem: Dictionary) -> void:
	var L := ss.law
	ss.law_cmd("patrol", {"zone": _predict_zone(ss, rng, mem)})
	if L.informants < 1:
		ss.law_cmd("recruit")
	elif L.evidence >= 20:
		ss.law_cmd("wiretap")
	else:
		ss.law_cmd("audit")
	_fund_units(ss, 1, 1, 1)
	if L.budget_k > HQ.LAW_COSTS_K["aerostat"] + 4 and _balloon_weather(ss):
		ss.law_cmd("aerostat")
	ss.law_cmd("ready")


## React to the news: evaded patrols mean a leak; spending means laundering.
static func law_adaptive(ss: HQ.Season, rng: PyRandom, mem: Dictionary) -> void:
	var L := ss.law
	var o := ss.org
	var last := _last(ss)
	if last != null and Py.any(last.runs, func(r): return r.busted or r.boat_seized):
		ss.law_cmd("press")
	var evaded: int = mem.get("evaded", 0)
	if last != null and not ss.plan_hist.is_empty() and ss.plan_hist.back().get("patrol") \
			and not Py.any(last.runs, func(r): return r.intercepted):
		evaded += 1
	mem["evaded"] = evaded
	if evaded >= 2 and ss.night % 2 == 0:
		ss.law_cmd("ia_sweep")
		mem["evaded"] = 0
	elif evaded >= 1 and not L.encryption and L.budget_k > 14:
		ss.law_cmd("encryption")
	if L.informants < 2 and o.heat > 25:
		ss.law_cmd("recruit")
	if L.evidence >= 20:
		ss.law_cmd("wiretap")
	if o.fronts.size() > 1 and ss.night % 2 == 1:
		ss.law_cmd("audit")
	ss.law_cmd("patrol", {"zone": _predict_zone(ss, rng, mem)})
	# patrols keep missing: test the dispatch line with a canary before paying for a sweep
	if ss.on("canary") and evaded >= 1 and o.heat > 20:
		ss.law_cmd("canary")
	var heavy := o.heat > 40
	_fund_units(ss, 1, 2 if heavy else 1, 1)
	if L.budget_k >= HQ.LAW_COSTS_K["aerostat"] and _balloon_weather(ss):
		ss.law_cmd("aerostat")
	# the cartel war: busting Cuervos is good press and splits the organisation's cover
	if ss.rival != null and ss.rival.band() in ["strong", "dominant"] and L.budget_k >= ss.rules["gang_unit_k"]:
		ss.law_cmd("gang_unit")
	ss.law_cmd("ready")


static func law_random(ss: HQ.Season, rng: PyRandom, mem: Dictionary) -> void:
	var names := ["aerostat", "recruit", "wiretap", "audit", "ia_sweep", "encryption", "press"]
	if ss.rival != null:
		names.append("gang_unit")
	var options := rng.shuffle(names)
	if not mem.has("used"):
		mem["used"] = []
	for name in options.slice(0, 3):
		if ss.law_cmd(name) == null:
			mem["used"].append(name)
	ss.law_cmd("patrol", {"zone": rng.choice(HQ.ZONES)})
	if ss.on("canary") and rng.random() < 0.3:
		if ss.law_cmd("canary") == null:
			mem["used"].append("canary")
	var h := rng.randint(0, 2)
	var i := rng.randint(0, 2)
	var c := rng.randint(0, 1)
	_fund_units(ss, h, i, c)
	ss.law_cmd("ready")
