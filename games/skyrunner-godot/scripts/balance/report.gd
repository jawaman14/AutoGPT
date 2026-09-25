class_name BalanceReport
extends RefCounted
## Build docs/BALANCE.md from saved simulation results (sim-results/*.json).
## Port of skyrunner/sim/report.py; the changelog below is copied verbatim.

## What the simulations changed, oldest first. Numbers are from the runs that
## motivated each change; the tables below are regenerated from current code.
const CHANGELOG := [
	["Pine Ridge was a trap",
		"Feasibility sweep: a C172 could land at PNR but only take off again with <25% fuel. The 22 m tree lines 60 m past each runway end blocked any loaded climb-out.",
		"Tree lines moved to 110 m past the ends and cut to 16 m (the 50 ft obstacle a pilot's handbook plans for). A C172 now gets out at every load the sweep tries."],
	["Old Quarry was a trap",
		"No aircraft could take off from QRY in either direction: a 13 m rim just past the downhill end, and the pit wall (215 m in 240 m) past the other.",
		"Added a graded haul road out of the downhill end (`Airfield.haul_road`). QRY becomes a one-way strip: land uphill, take off downhill. It stays the hardest strip on the island."],
	["Narrow strips had no way to turn round",
		"A 180-degree pivot needs about 13 m, more than the width of QRY (12 m) or PNR (15 m). Backtracking for a downhill takeoff left you in the rough.",
		"New actions: differential toe-brakes for pivot turns (`Controls.diff_brake`), and 'push her round' (key I, 20 s solo or 10 s with crew), which is what bush pilots actually do."],
	["Flying under the radar never worked",
		"Tactical sweep: low-level runs with the transponder off were flagged 100% and busted 78-100%. Squawking like legitimate traffic delivered 89% against light police. That is the opposite of the history, and it made one tactic dominant.",
		"A primary-only radar track now builds suspicion slowly (1.2-4.2 %/s instead of 8-33 %/s), so it takes 30-60 s of sustained track. Behaviour multiplies it: low and fast inbound from the sea x2.5, orbiting low over water +3 %/s, a squawk that vanishes mid-track +50. The aerostat's 20 m floor is the counter to low flying."],
	["Then hiding in plain sight became dominant",
		"With the radar fix in, squawking like legitimate traffic delivered 73-100% of loads and was never flagged by light or standard police. Only an informant's tip stopped it. The quarry sits in radar shadow, so nothing saw where the 'legitimate' flight went.",
		"Two linked rules. (1) A squawking track that drops off the scope low and heading for a shady strip is flagged at once ('nobody legit lands at Old Quarry'); a bush strip only earns +30 suspicion, because honest jobs go there too. (2) A hot load at a bush or shady strip takes 60 s to unload, and a police aircraft within 2 km in that time means a raid. The tell now has consequences: the task force races you to the strip, and a patrol parked nearby wins the race."],
	["Coast Guard cutters never caught anything",
		"0% boat seizures across 189 flights: cutters sailed from Port Harbor, 20 km away at 32 kt, and the go-fast was gone in 5 minutes.",
		"A funded cutter starts the night on picket off the coast (`Maritime.new_cutter(at=...)`). Seizures appear (13-17% of sea runs in later sweeps) without making airdrops pointless."],
	["The law won 81% of seasons",
		"First strategic run: the runner equilibrium win rate was 0.18. Retiring rich happened in 2% of seasons, bribery cut win rate by 18 points, and wiretaps added 43 points.",
		"Retire target $90k -> $60k; run payout $11k -> $13k; contract crews cheaper ($4k -> $3k) and better paid (50% -> 60% share); bribes cheaper; wiretap 7 -> 4 evidence/night (warrant at 20 evidence, $7k); audits worth more (3.5 -> 6 per exposure point, $5k -> $4k); seizure share 50% -> 80% (the 1984 equitable-sharing rule); encryption $8k -> $5k; new runner order 'gear' (scanner/detector) so encryption has something to counter; comeback gap 30% -> 25%. Equilibrium: 0.18 -> 0.30 -> 0.49 -> 0.50."],
	["Calibrated to flown numbers, the law won 98%",
		"Once the season simulator used rates flown by the bot instead of hand estimates, the organisation's equilibrium win rate fell to 2% and 48% of seasons ended broke. Three causes: the aerostat's 40 km radius covered every route on the island; the abstract model treated five police units as five times one; and every bust fed the case against the boss, a snowball.",
		"Aerostat radius 40 -> 22 km (south coast and sea lanes; the northern mountains are the way round it). Interception now has diminishing returns (`k * ln(1 + units)`, with k fitted to flown flights). Units cost more (helicopter $3k -> $4k, interceptor $5k -> $7k, aerostat $4k -> $6k). A contract crew's bust gives 2 evidence and never flips, because they don't know who they fly for. Bust evidence 12 -> 6; wiretap 4 -> 3; bankruptcy at -$10k. A bribed dispatcher's warning now reroutes the run away from the patrol and the balloon. Economy: run value $15k, retire at $45k, start with $16k, police base budget $9k. A 16-point grid search picked the last four. The bot's low-level crash rate is capped at 6% in the calibration, because it overstates a competent human. A smarter organisation bot joined the pool so both sides have one strategy that uses all its information (principle P8: balance at equal skill). Equilibrium: 0.02 -> 0.09 -> 0.25 -> 0.37 -> 0.475."],
	["The test rig itself was wrong once",
		"'aerostat' and 'standard' postures gave identical numbers because the Session raises the aerostat automatically whenever the feature is on.",
		"Fixed in the rig (the aerostat is available but only raised by the posture). Lesson: check that configurations which should differ actually do, before believing the numbers."],
	["Recruiting an informant was the single best move in the game",
		"At 8000 seasons the equilibrium (organisation win 45.5%) looked fair, but the ablation table told a different story: removing 'recruit' alone swung it to 60% (+14.5, the biggest number on the board). Reading the code found why: an informant gave three stacked, always-on bonuses (a flat +45% detection chance on tip nights, a 1.2x intercept-hazard multiplier on top of that, and 2.5 evidence/night per head, up to 3 heads) for $3k plus $1k/night upkeep, and a whole computed 'informant_mult' field was dead code that never reached the resolver. Worse, 'cautious' - the equilibrium runner strategy - never called 'counterintel' at all, so the one built-in counter to informants was never used by the side that was actually winning.",
		"Informant cap 3 -> 2; recruiting cost $3k -> $5k; evidence/informant 2.5 -> 1.8; the tip's detection bonus +45% -> +30% and its intercept-match multiplier 1.2x -> 1.1x; counterintel cheaper ($5k -> $4k) and burns 75% of informants instead of 60%. Removed the dead 'informant_mult' field instead of wiring it in on top of the tip bonus, which would have doubled up the same effect. Gave 'runner_cautious' a counterintel response whenever it already reaches for opsec (serious evidence rumour or heat > 70), matching what 'adaptive' and 'smart' already did. Equilibrium: 0.455 -> 0.450 at 40000 seasons; the investigation trio (recruit/audit/wiretap) still swings the most on ablation (+15 to +20 points each), which tracks with evidence being the task force's only win condition, but it is now measured, not accidentally doubled by dead code."],
	["Recruiting a second informant was still nearly free",
		"Known limits flagged the fix above as partial: recruit's ablation stayed the single biggest number (+20.2) because the cost and odds only depended on the informant cap, not on how many were already in place. Stacking to the cap (2) cost the same $5k twice and succeeded at the same rate twice, so a chief who could afford it just always went to 2 early and never felt a choice.",
		"Recruiting cost now scales with the count already turned ($5k, then $10k for the second), and the success chance is multiplied by 0.6 per existing informant, so the second head is a real, worse bet rather than a free top-up. Equilibrium barely moved (0.450 -> 0.451 at 40000 seasons) because most of recruit's value is 'have one at all' versus 'have none', which this doesn't touch - that first informant is doing the work the task force's whole case-building game is built on. The remaining ablation size is now read as by-design (evidence is the task force's only win path) rather than a bug, per the note above."],
]


static func _load(dir: String, name: String):
	var p := dir.path_join(name + ".json")
	return JSON.parse_string(FileAccess.get_file_as_string(p)) if FileAccess.file_exists(p) else null


static func _pct(v) -> String:
	return "-" if v == null else Py.f(100 * float(v), 0) + "%"


static func _signed(x: float, n: int) -> String:
	var s := Py.f(x, n)
	return s if s.begins_with("-") else "+" + s


## Python repr of a float (shortest round-trip form, "1.0" for integers).
static func _repr(v) -> String:
	if v is float:
		return Py.float_repr(v)
	if v is Dictionary:
		var parts := []
		for k in v:
			parts.append("'%s': %s" % [k, _repr(v[k])])
		return "{" + ", ".join(parts) + "}"
	return str(v)


static func cal_repr(cal: HQ.Calibration) -> String:
	var d := cal.to_dict()
	var parts := []
	for k in d:
		parts.append("%s=%s" % [k, _repr(d[k])])
	return "Calibration(" + ", ".join(parts) + ")"


static func write_report(results_dir: String, out_path: String) -> String:
	var lines := ["# Skyrunner balance report", "",
		"Generated by `godot --headless --script res://scripts/balance/cli.gd -- report` from the raw runs in "
		+ "`sim-results/`. The method and the reasoning behind the targets are in "
		+ "[MULTIPLAYER.md](../../skyrunner/docs/MULTIPLAYER.md).", "",
		"**Targets.** Equilibrium win rate 50% ± 5 for same-skill play. No dominant strategy. At least two "
		+ "strategies per side in the equilibrium mix. Every win condition happens in at least 8% of seasons. "
		+ "Comebacks (the side leading at half-time loses) in 15-35% of seasons. No airfield you can land at "
		+ "but can't leave with the aircraft that got you there.", ""]

	lines += ["## What the simulations changed", ""]
	for i in CHANGELOG.size():
		var c: Array = CHANGELOG[i]
		lines += ["%d. **%s.** *Found:* %s *Changed:* %s" % [i + 1, c[0], c[1], c[2]], ""]

	var feas = _load(results_dir, "feasibility")
	if feas:
		var ok := Py.count(feas, func(r): return Py.truthy(r["ok"]))
		lines += ["## 1. Can you get in and out? (feasibility)", "",
			("The pilot bot flew %d takeoffs and landings: every aircraft × airfield × load " % feas.size())
			+ "(light = 30% fuel; half = 60% fuel + half payload; max = full fuel + payload to MTOW). "
			+ ("%d succeeded. L = landing, T = takeoff." % ok), "", Feasibility.table(feas), "",
			"How to read it: the C172 row is the one that matters for fairness, because every career "
			+ "starts in one. It lands everywhere at light and half loads and takes off from everywhere "
			+ "except the quarry at half load. At max weight it can't leave the plateau (EGL) or the "
			+ "quarry. That is the trade-off the game is built on: tight strips mean light loads. The PA28, C182 and Twin Otter "
			+ "rows mostly measure the bot rather than the aircraft. It was tuned on the C172 and C310, and "
			+ "the PA28's JSBSim model needs about -0.6 elevator of trim at approach speed. Treat red cells "
			+ "there as 'the bot can't', not 'a human can't'.", ""]

	var tac = _load(results_dir, "tactical")
	if tac:
		var missions := []
		for k in Tactical.MISSIONS:
			missions.append("%s: %s->%s" % [k, Tactical.MISSIONS[k][0], Tactical.MISSIONS[k][1]])
		var laws_seen := {}
		for r in tac:
			laws_seen[r["law"]] = true
		lines += ["## 2. Cops vs smugglers, flown (tactical)", "",
			("%d real flights: the pilot bot (C172) against the AI task force. Three missions " % tac.size())
			+ "(" + ", ".join(missions) + "), "
			+ ("%d police postures, three runner tactics: *low* (50 m, " % laws_seen.size())
			+ "transponder off, valley routing), *high* (450 m, squawking like legitimate traffic) and "
			+ "*evasive* (low plus scanner, detector and evasion).", "",
			"| | n | flagged | intercepted | busted | crashed | delivered | boat seized |",
			"|---|---|---|---|---|---|---|---|"]
		var row := func(label: String, w: Dictionary) -> void:
			var q := Tactical.rates(tac, w)
			if q.get("n"):
				lines.append("| %s | %d | %s | %s | %s | %s | %s | %s |" % [label, q["n"], _pct(q["flagged"]),
					_pct(q["intercepted"]), _pct(q["busted"]), _pct(q["crashed"]), _pct(q["delivered"]),
					_pct(q["boat_seized"])])
		row.call("**all**", {})
		for t in Tactical.TACTICS:
			row.call("tactic: " + t, {"tactic": t})
		for law in Tactical.LAW_CONFIGS:
			row.call("police: " + law, {"law": law})
		for z in Tactical.MISSIONS:
			row.call("zone: " + z, {"zone": z})
		var laws := Tactical.LAW_CONFIGS.keys().filter(func(law): return Tactical.rates(tac, {"law": law}).get("n"))
		lines += ["", "Tactic × posture (delivered):", "", "| tactic | " + " | ".join(laws) + " |",
			"|---|" + "---|".repeat(laws.size())]
		for t in Tactical.TACTICS:
			var cells := laws.map(func(law): return _pct(Tactical.rates(tac, {"tactic": t, "law": law}).get("delivered")))
			lines.append("| %s | " % t + " | ".join(cells) + " |")
		lines += ["", "Calibration fed to the season simulator: `%s`" % cal_repr(Tactical.calibrate(tac)), ""]

	var strat = _load(results_dir, "strategic")
	if strat:
		var mx := Strategic.matrix(strat)
		var R: Array = mx[0]
		var L: Array = mx[1]
		var m: Array = mx[2]
		var eq := Strategic.equilibrium(m)
		var p: Array = eq[0]
		var q: Array = eq[1]
		var v: float = eq[2]
		var s := Strategic.summary(strat)
		lines += ["## 3. Whole seasons, HQ vs HQ (strategic)", "",
			"%d simulated seasons, %d organisation strategies × %d task-force " % [s["seasons"], R.size(), L.size()]
			+ "strategies. Cells are the organisation's win rate.", "",
			"| boss \\ chief | " + " | ".join(L) + " |", "|---|" + "---|".repeat(L.size())]
		for i in R.size():
			lines.append("| %s | " % R[i] + " | ".join(m[i].map(func(x): return Py.f(100 * x, 0) + "%")) + " |")
		var mix := func(names: Array, w: Array) -> String:
			var parts := []
			for i in names.size():
				if w[i] > 0.01:
					parts.append("%s %s%%" % [names[i], Py.f(100 * w[i], 0)])
			return ", ".join(parts)
		lines += ["", "- **Equilibrium win rate (organisation): %s%%** (target 50 ± 5)" % Py.f(100 * v, 1),
			"- Equilibrium mix, organisation: " + mix.call(R, p),
			"- Equilibrium mix, task force: " + mix.call(L, q),
			"- Raw win rate over all pairings: %s for the organisation" % _pct(s["runner_win"]),
			"- Average season length: %s nights; decided before the last night: %s" % [Py.f(s["nights_mean"], 1), _pct(s["ended_early"])],
			"- Comebacks (half-time leader loses): %s; close finishes: %s" % [_pct(s["comeback_rate"]), _pct(s["close_finish"])],
			"", "How seasons end:", ""]
		for k in s["reasons"]:
			lines.append("- %s: %s" % [k, _pct(s["reasons"][k])])
		var dom := Strategic.dominance(m, R, L)
		lines += ["", "Dominance between archetypes (a bot archetype being beaten everywhere is fine; a *mechanic* "
			+ "nobody should use is not, see the next table): " + ("; ".join(dom) if dom else "none"), ""]
		for side in ["runner", "law"]:
			var av := Strategic.action_values(strat, side)
			if av:
				lines += ["What each %s order is worth " % ("organisation" if side == "runner" else "task-force")
					+ "(win rate when the random bot used it vs didn't):", "", "| order | effect | uses |", "|---|---|---|"]
				for a in Py.sorted_by(av.keys(), func(k): return -av[k][0]):
					lines.append("| %s | %s pts | %d |" % [a, _signed(av[a][0] * 100, 0), av[a][1]])
				lines.append("")
	var abl = _load(results_dir, "ablation")
	if abl:
		var base: float = abl["base"]
		lines += ["Ablations: equilibrium win rate with one mechanic switched off (baseline "
			+ "%s%%). Big swings mean the mechanic matters. Near zero means it's " % Py.f(100 * base, 1)
			+ "optional flavour.", "", "| without | organisation win | change |", "|---|---|---|"]
		var wo: Dictionary = abl["without"]
		for k in Py.sorted_by(wo.keys(), func(k): return -absf(wo[k] - base)):
			lines.append("| %s | %s%% | %s |" % [k, Py.f(100 * wo[k], 1), _signed(100 * (wo[k] - base), 1)])
		lines.append("")
	lines += ["## Known limits", "",
		"- The tactical numbers come from one bot that flies well but plays simply: it follows valleys "
		+ "and ducks when it sees police, but it doesn't read the police radio or bluff. Humans will do "
		+ "better on the runner side, so the real task force should be a little stronger than these "
		+ "numbers suggest.",
		"- The season simulator rolls nights from calibrated probabilities. It captures the economy and "
		+ "the information war, not flying skill.",
		"- Sample sizes: tactical cells have 3-9 flights each. Anything under about 15 points of "
		+ "difference is noise.",
		"- Recruit is nearly worthless to a random bot (+2 pts) but the single biggest ablation at "
		+ "equilibrium (about +20 pts even after the cost/odds were scaled per informant): most of its "
		+ "value is 'have one informant at all' versus 'have none', which no per-informant tuning "
		+ "touches. If this reads as too strong in playtests, the next lever is the tip mechanic the "
		+ "first informant grants, not the recruiting cost."]
	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	f.store_string("\n".join(lines) + "\n")
	f.close()
	return out_path
