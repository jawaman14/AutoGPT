class_name Strategic
extends RefCounted
## Season-level balance simulation (port of skyrunner/sim/strategic.py).
##
## Plays whole seasons of the HQ game between bot policies, thousands of times,
## with night outcomes rolled by `HQ.resolve_abstract` (rates calibrated from
## real bot flights by `Tactical`). Measures:
##
##   * win-rate matrix, runner policy x law policy
##   * the equilibrium mix (fictitious play on the zero-sum matrix): which
##     strategies a smart player would actually use, and the fair win rate
##   * dominance: a strategy that beats or ties everything is a design bug
##   * how games end (reasons), how long they last, how often the side leading
##     at half-time loses (comebacks), and how often it's decided early
##   * what each action is worth (win rate when a random bot used it vs not)
##   * ablations: switch a mechanic off and see whether anyone notices
##
## Same seeds, same numbers as the Python simulator: the season rules, the bot
## policies and both random streams are bit-exact ports.

const ABLATIONS := ["bribe", "wiretap", "decoys", "crews", "audit", "recruit", "lawyer", "opsec", "comeback",
	"hit_rival", "truce", "tip_off", "gang_unit"]


static func play_season(runner: String, law: String, seed: int, rules = null, cal: HQ.Calibration = null,
		disable: Array = []) -> Dictionary:
	var rng := PyRandom.new()
	rng.seed(seed)
	var srng := PyRandom.new()
	srng.seed(seed * 7 + 1)
	var ss := HQ.Season.new(srng, rules if rules is Dictionary else {})
	for name in disable:  # ablation: that order is simply unavailable
		_disable(ss, name)
	var rmem := {}
	var lmem := {}
	var halftime = null
	while ss.phase != "over":
		HQBots.RUNNER_POLICIES[runner].call(ss, rng, rmem)
		HQBots.LAW_POLICIES[law].call(ss, rng, lmem)
		var plan := ss.start_operation()
		ss.finish_night(HQ.resolve_abstract(ss, plan, rng, cal))
		if ss.night == Py.idiv(int(ss.rules["nights"]), 2):
			halftime = ss.runner_progress() - ss.law_progress()
		ss.next_night()
	var out := {
		"runner": runner, "law": law, "seed": seed, "winner": ss.winner, "reason": ss.reason,
		"nights": ss.night, "halftime": halftime,
		"margin": ss.runner_progress() - ss.law_progress(),
		"runner_used": rmem.get("used", []), "law_used": lmem.get("used", []),
		"history": ss.history,
	}
	if ss.rival != null:
		var hij := 0
		for rep in ss.reports:
			hij += Py.count(rep.runs, func(r): return r.hijacked)
		out["rival"] = {"strength": Py.round_n(ss.rival.strength, 1), "busts": ss.rival.busts, "hijacks": hij}
	return out


static func _disable(ss: HQ.Season, name: String) -> void:
	for side in ["_r_", "_l_"]:
		if ss.has_method(side + name):
			ss.disabled[side + name] = true
	if name == "comeback":
		ss.rules["comeback_gap"] = 99.0


## One job tuple as sent to a worker: [runner, law, seed, rules, cal dict, disable].
static func run_job(j: Array) -> Dictionary:
	var cal: HQ.Calibration = HQ.Calibration.from_dict(j[4]) if j[4] is Dictionary else null
	return play_season(j[0], j[1], int(j[2]), j[3], cal, j[5])


static func jobs(n := 200, rules = null, cal: HQ.Calibration = null, disable: Array = [], runners = null,
		laws = null) -> Array:
	var rs: Array = runners if runners != null else HQBots.RUNNER_POLICIES.keys()
	var ls: Array = laws if laws != null else HQBots.LAW_POLICIES.keys()
	var cd = cal.to_dict() if cal != null else null
	var out := []
	for r in rs:
		for l in ls:
			for i in n:
				out.append([r, l, 1000 * i + 17, rules, cd, disable])
	return out


static func run_matrix(n := 200, rules = null, cal: HQ.Calibration = null, disable: Array = [], runners = null,
		laws = null, workers := 1) -> Array:
	var js := jobs(n, rules, cal, disable, runners, laws)
	if workers <= 1:
		return js.map(run_job)
	return WorkerPool.map("strategic", js, workers)


## [runner names, law names, win-rate matrix as rows]
static func matrix(results: Array) -> Array:
	var rorder: Array = HQBots.RUNNER_POLICIES.keys()
	var lorder: Array = HQBots.LAW_POLICIES.keys()
	var runners := rorder.filter(func(k): return Py.any(results, func(r): return r["runner"] == k))
	var laws := lorder.filter(func(k): return Py.any(results, func(r): return r["law"] == k))
	var m := []
	var cnt := []
	for i in runners.size():
		var row := []
		row.resize(laws.size())
		row.fill(0.0)
		m.append(row)
		cnt.append(row.duplicate())
	for r in results:
		var i := runners.find(r["runner"])
		var j := laws.find(r["law"])
		m[i][j] += 1.0 if r["winner"] == "runner" else 0.0
		cnt[i][j] += 1.0
	for i in runners.size():
		for j in laws.size():
			m[i][j] /= maxf(cnt[i][j], 1.0)
	return [runners, laws, m]


static func _dot(a: Array, b: Array) -> float:
	var s := 0.0
	for k in a.size():
		s += a[k] * b[k]
	return s


static func _scaled(v: Array) -> Array:
	var t := 0.0
	for x in v:
		t += x
	return v.map(func(x): return x / t)


## Fictitious play on the zero-sum game (runner maximises win rate). Returns [p, q, value].
static func equilibrium(m: Array, iters := 20000) -> Array:
	var nr := m.size()
	var nl: int = m[0].size()
	var rc := []
	rc.resize(nr)
	rc.fill(0.0)
	var lc := []
	lc.resize(nl)
	lc.fill(0.0)
	rc[0] = 1.0
	lc[0] = 1.0
	var col := []
	col.resize(nl)
	for _it in iters:
		var q := _scaled(lc)
		var best := 0
		var bv := -INF
		for i in nr:
			var v := _dot(m[i], q)
			if v > bv:
				bv = v
				best = i
		rc[best] += 1.0
		var p := _scaled(rc)
		var worst := 0
		var wv := INF
		for j in nl:
			var v := 0.0
			for i in nr:
				v += p[i] * m[i][j]
			if v < wv:
				wv = v
				worst = j
		lc[worst] += 1.0
	var p := _scaled(rc)
	var q := _scaled(lc)
	var pm := []
	for j in nl:
		var v := 0.0
		for i in nr:
			v += p[i] * m[i][j]
		pm.append(v)
	return [p, q, _dot(pm, q)]


static func dominance(m: Array, names_r: Array, names_l: Array) -> Array:
	var notes := []
	var nl := names_l.size()
	for i in names_r.size():
		for k in names_r.size():
			if i == k:
				continue
			var all_ge := true
			var any_gt := false
			for j in nl:
				all_ge = all_ge and m[i][j] >= m[k][j] - 0.02
				any_gt = any_gt or m[i][j] > m[k][j] + 0.05
			if all_ge and any_gt:
				notes.append("runner '%s' dominates '%s'" % [names_r[i], names_r[k]])
	for j in nl:
		for k in nl:
			if j == k:
				continue
			var all_le := true
			var any_lt := false
			for i in names_r.size():
				all_le = all_le and m[i][j] <= m[i][k] + 0.02
				any_lt = any_lt or m[i][j] < m[i][k] - 0.05
			if all_le and any_lt:
				notes.append("law '%s' dominates '%s'" % [names_l[j], names_l[k]])
	return notes


static func summary(results: Array) -> Dictionary:
	var n := results.size()
	var reasons := {}
	var max_nights := 0
	var nights_sum := 0
	var wins := 0
	for r in results:
		var key: String = r["reason"].split(":")[0] if r["reason"].begins_with("season over") else r["reason"]
		key = r["reason"] if key == "season over" else key
		var k := "%s: %s" % [r["winner"], key]
		reasons[k] = reasons.get(k, 0) + 1
		max_nights = maxi(max_nights, int(r["nights"]))
		nights_sum += int(r["nights"])
		wins += 1 if r["winner"] == "runner" else 0
	var with_half := results.filter(func(r): return r["halftime"] != null)
	var comebacks := with_half.filter(func(r): return (r["halftime"] > 0) != (r["winner"] == "runner") and absf(r["halftime"]) > 0.02)
	var close := Py.count(results, func(r): return absf(r["margin"]) < 0.25)
	var rs := {}
	for k in Py.sorted_by(reasons.keys(), func(k): return -reasons[k]):
		rs[k] = float(reasons[k]) / n
	return {
		"seasons": n,
		"runner_win": float(wins) / maxi(1, n),
		"reasons": rs,
		"nights_mean": float(nights_sum) / n,
		"ended_early": float(Py.count(results, func(r): return int(r["nights"]) < max_nights)) / maxi(1, n),
		"comeback_rate": float(comebacks.size()) / maxi(1, with_half.size()),
		"close_finish": float(close) / maxi(1, n),
	}


## Cartel numbers over many seasons: how often it matters.
static func rival_summary(results: Array) -> Dictionary:
	var rs := results.filter(func(r): return r.has("rival"))
	if rs.is_empty():
		return {}
	var n := float(rs.size())
	return {
		"seasons": rs.size(),
		"hijack_seasons": Py.count(rs, func(r): return r.rival.hijacks > 0) / n,
		"hijacks_per_season": Py.sum_by(rs, func(r): return r.rival.hijacks) / n,
		"rival_busts_per_season": Py.sum_by(rs, func(r): return r.rival.busts) / n,
		"end_strength": Py.sum_by(rs, func(r): return r.rival.strength) / n,
	}


## The five ways a season ends, as shares (the target is >= 8% each).
static func endings(results: Array) -> Dictionary:
	var keys := ["retired rich", "walked free", "convicted at trial", "boss indicted", "organisation broke"]
	var out := {}
	for k in keys:
		out[k] = Py.count(results, func(r): return str(r.reason).ends_with(k)) / float(maxi(1, results.size()))
	return out


## Win rate of the random bot's side when it used an action at least once vs never:
## {action: [delta, uses]}, keys sorted.
static func action_values(results: Array, side: String) -> Dictionary:
	var key := "runner_used" if side == "runner" else "law_used"
	var pool := results.filter(func(r): return r[side] == "random")
	var acts := {}
	for r in pool:
		for a in r[key]:
			acts[a] = true
	var names := acts.keys()
	names.sort()
	var win := func(rs: Array) -> float:
		return float(Py.count(rs, func(r): return r["winner"] == side)) / rs.size()
	var out := {}
	for a in names:
		var used := pool.filter(func(r): return a in r[key])
		var not_used := pool.filter(func(r): return not (a in r[key]))
		if used.size() < 10 or not_used.size() < 10:
			continue
		out[a] = [win.call(used) - win.call(not_used), used.size()]
	return out
