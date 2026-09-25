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
	["The balance rested on 9-flight calibration cells",
		"Porting to Godot, the season simulator reproduced Python's numbers exactly, yet the Godot build's own tactical sweep (same seeds) produced an equilibrium of 69% instead of 45%. 130 of 189 flights were identical; the rest diverged because the pip JSBSim and a source-built JSBSim differ by a few ulps in longitude, and a flight near a bot decision threshold amplifies that. Totals matched (109 vs 109 flagged), but the calibration fits each zone from 9 flights, so a handful of flipped outcomes moved intercept_k from 2.0 to 1.3 and the season result by 24 points.",
		"The tactical sweep now flies 10 seeds per cell (630 flights). intercept_k settles at 1.96, next to Python's 2.03; west-route detection is higher than the small sample said (0.47 vs 0.22). Lesson: a calibration built on a single-digit sample is a coin toss, however exact the simulator downstream."],
	["A second smuggling outfit: Los Cuervos",
		"Requested feature: competing smuggler groups. Added a rival cartel run by the AI on its own random stream. It flies loads every night, splits the police, undercuts payouts where it owns the market, and hijacks your load if you share a route without a truce. The boss can hit it, buy a truce or sell its route to the police; the chief can send a gang unit. With the new calibration and the cartel on, the organisation's equilibrium was 39% (44% with the cartel off).",
		"A 12-point grid over the cartel's market bite, its hijack chance and the retirement target. Retire at $38k (was $45k), market loss 30% at full rival control, hijack chance 20% + 30% x strength when you meet on the same route. Equilibrium 48.8% over 40,000 seasons, every ending between 13% and 27%, comebacks 21%. The cartel hijacks at least one load in a third of seasons, and recruit's ablation swing fell from +20 to +8 points: the cartel gives the task force a second target and the organisation a second enemy."],
	["Heavy police flew exactly like standard police",
		"Tactical sweep, 90 flights per posture: 'heavy' (2 helicopters, 2 interceptors) and 'standard' (1 + 1) gave identical rows, flight for flight. The AI sends a fixed response per wanted level (1 helicopter, then +1 interceptor, then +1 more), so a second helicopter never left the ground: the chief's extra money bought nothing.",
		"First try, a stake-out: a spare helicopter flew to the strip the track seemed to be making for. It guessed wrong against routes that dog-leg round radar cover, and changed no flight. Second, the surge (asked for: the spare joins the chase): every spare helicopter launches after a wanted track as a flanker, aiming up to 90 s ahead of the runner to cut it off, and two aircraft within bust range fill the bust meter 50% faster (boxed in). Re-flown, heavy still matches standard flight for flight, and the reason is now clear: of the 38 flights standard police flag, one helicopter busts 29, 6 end in the bot's own hard landing or ditching, and 3 get away over the sea. There is nothing left for a second chaser to win. Extra helicopters pay before the chase, not in it: the patrol posture (one helicopter already over the zone) busts 40 of 90 against 29. The season model credits extra units with ln(1 + units), 1.49x the hazard for heavy; flown, it's 1.00x (see section 2). Kept as is: human controllers do use spare aircraft, and the surge makes the AI's spares fly rather than sit in the hangar.""],
	["Weather and the moon",
		"Requested: realism. Each night now has a forecast both HQs see while planning (clear 55%, cloud 30%, storm 15%, right 75% of the time) and a moon on a 29.5-day cycle. Cloud, rain and a dark moon cut how far crews see; storms ground most helicopters and the aerostat (TARS balloons are winched down for lightning), make the sea too rough for cutters, and more than double crash risk. Live: JSBSim wind and Dryden turbulence, rain, lightning, a storm deck, the moon's phase. The first version handed the organisation 69% (weather was a flat -16% on detection). Centring the factors on 1.0 (clear x1.1, cloud x0.9, storm x0.7; moon x0.8-1.2; crashes x0.8/1.1/2.2) still left it at 62%: attribution runs (one storm effect off at a time) put ~5 points on visibility, 1 or less each on grounded helicopters, balloon and cutters, the rest on interactions (the law bots learn less from fewer sightings). That matches history: smugglers picked bad weather and dark nights.",
		"Kept the realism and moved the economy instead: retire target $38k -> $48k (with the pattern rule below at 0.45). Equilibrium 51.2% over 40,000 seasons, endings 14-28%, comebacks 22%. Weather is now worth about 13 points to the organisation on ablation - the biggest single lever in the game - so reading the forecast is part of playing well."],
	["Pattern of life: predictability is exploitable",
		"Game theory's inspection game (police vs smuggler) has no pure-strategy equilibrium: whoever is predictable loses. The old abstract model had no memory, so flying the same route every night cost nothing (the greedy bot flew the sea every night, 0 bits of route entropy). Real task forces keep sighting logs and patrol where the pattern points.",
		"The law's analysts now add up to +45% detection on a route, scaled by the share of the last four nights' sightings that fell there; both HQs see the numbers. The runner bots now weight their route choice away from that exposure. Ablation: switching it off hands the organisation ~5 points; route entropy runs from 0 (greedy) to 1.5 bits (cautious, shadow; 1.585 is uniform), and the most mixed strategies are detected least."],
	["The canary trap",
		"Real counter-intelligence tests a suspected leak by feeding a unique false detail down one channel and watching whether it comes back. Added as a chief order ($1.5k): the bribed dispatcher passes on a fake patrol; if the organisation's plan swerves around a patrol that never flew, the dispatcher is arrested (+12 evidence). The first version made the law worse off (-5 points): the adaptive chief sprang it after any single missed patrol, which is usually just luck, and it caught a leak in 3% of seasons.",
		"The chief bot now waits for two evaded patrols. The canary is neutral at equilibrium (+/-1 point) and catches a leak in ~2% of seasons: a niche counter that matters against dispatcher-reliant play. It also makes every leak an uncertain signal, which is the point: the organisation can no longer treat the dispatcher as ground truth."],
	["Truces unravel near the end",
		"A truce with Los Cuervos is an iterated prisoner's dilemma: cooperation holds while the future is worth more than one betrayal (the shadow of the future). Backward induction says it collapses as the season runs out. Each season Los Cuervos now get a hidden temper - tit-for-tat, grudge-holder or opportunist - that the organisation learns from how they behave. Opportunists sell your route to the task force, most often in the last two nights; grudge-holders never make peace after you hit or sold them; tit-for-tat answers your last move.",
		"Measured over 40,000 seasons: betrayals land at 157 each with 1 and 2 nights left, 142 on the last night, against 20-90 on any earlier night; opportunists betray 0.055 times per season, tit-for-tat 0.004, grudgers never. The runner bots now refuse to pay for a truce with a known opportunist near the end, and defect first on the last night. Ablation: ~1 point, because truces are rare in the bot meta - it matters to humans who read the reputation line."],
	["The pilot's nerves",
		"Requested: psychology. Stress now follows what real smuggling pilots feared (wanted level, a police aircraft in sight, low flying in the dark or a storm, fuel running out; a crew in the right seat takes 25% off), rising in seconds and settling over half a minute. Following the Yerkes-Dodson curve, moderate arousal costs nothing; above 0.6 the screen tunnels and drains of colour, the heartbeat becomes audible and an 8-12 Hz tremor (the band adrenaline amplifies) is added to the stick.",
		"Human hands only: the bot and the autopilot are immune, so none of the numbers in this report move. It is a skill tax that rewards staying calm - a co-pilot, altitude, fuel margin - rather than a dice roll."],
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
		var ur := Tactical.unit_returns(tac)
		if not ur.is_empty():
			lines += ["Returns on extra units: heavy (2 helicopters + 2 interceptors) vs standard (1 + 1) intercept hazard, flown "
				+ "%sx, season model %sx. Where they differ, the flown number says a second chaser adds nothing the first "
				% [Py.f(ur["flown"], 2), Py.f(ur["model"], 2)] + "doesn't already get (entry 14).", ""]

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
	if strat:
		var ends := Strategic.endings(strat)
		lines += ["Win conditions (target: each at least 8% of seasons):", "", "| ending | share |", "|---|---|"]
		for k in ends:
			lines.append("| %s | %s |" % [k, _pct(ends[k])])
		lines.append("")
	var rv = _load(results_dir, "rivals")
	if rv is Dictionary and not rv.is_empty():
		lines += ["## 4. The rival cartel (Los Cuervos)", "",
			"A third, AI-run outfit fights the organisation for the island's markets. Each night it flies its own "
			+ "loads in the zone it likes best (weighted by its turf and the pay, dodging a patrol it hears about). "
			+ "Its flights split the task force's attention; its busts are good press for the police. Where it owns "
			+ "the market the organisation's loads pay up to 40% less, and meeting it on the same route without a "
			+ "truce risks a hijack. The boss can hit it, buy a truce or sell its route to the police; the chief can "
			+ "send a gang unit after it.", "",
			"- Seasons with at least one hijack: %s; hijacks per season: %s" % [_pct(rv["hijack_seasons"]), Py.f(rv["hijacks_per_season"], 2)],
			"- Cartel planes busted per season: %s; cartel strength at the end: %s/100" % [Py.f(rv["rival_busts_per_season"], 2), Py.f(rv["end_strength"], 0)],
			""]
	var rz = _load(results_dir, "realism")
	if rz is Dictionary and not rz.is_empty():
		lines += ["## 5. The realism layer", "",
			"Weather and moon, pattern-of-life analysis, the canary trap and the rivals' tempers (entries 15-18 above), "
			+ "measured over the same seasons:", "",
			"- Storm nights per season: %s; seasons where a canary caught a leak: %s" % [Py.f(rz["storm_nights_per_season"], 2), _pct(rz["canary_catch_seasons"])],
			"- Truce betrayals per season, by temper: %s" % ", ".join((rz["betrayals_per_season_by_temper"] as Dictionary).keys().map(
				func(k): return "%s %s" % [k, Py.f(rz["betrayals_per_season_by_temper"][k], 3)])),
			"", "Betrayals by nights left in the season (backward induction: the end is when truces break):", "",
			"| nights left | " + " | ".join(range(10).map(func(i): return str(i))) + " |",
			"|---" + "|---".repeat(10) + "|",
			"| betrayals | " + " | ".join(range(10).map(func(i): return str(int(rz["betrayals_by_nights_left"].get(str(i), 0))))) + " |",
			"", "Route mixing against the analysts (entropy in bits; 1.585 = uniform over three routes):", "",
			"| organisation bot | route entropy | main run detected |", "|---|---|---|"]
		for pol in rz["route_entropy_by_runner"]:
			lines.append("| %s | %s | %s |" % [pol, Py.f(rz["route_entropy_by_runner"][pol], 2), _pct(rz["main_run_detected_by_runner"][pol])])
		lines.append("")
	var crew = _load(results_dir, "crew")
	if crew is Dictionary and not crew.is_empty():
		lines += ["## 6. What a co-pilot is worth", "",
			"The sea mission (airdrop to the go-fast, standard police) flown three ways: solo (autopilot on, the pilot "
			+ "goes aft and kicks, 4 s a bale), the AI co-pilot's habits (auto-kick over the mark, 2 s a bale) and a "
			+ "scripted human co-pilot through the command gate (calls the boat on the way in, kicks the load in one go). "
			+ "%d flights per crew." % int(crew["table"][0]["n"]), "",
			"| crew | bales kicked | bales delivered | s over the drop | flagged | busted | crashed | minutes |",
			"|---|---|---|---|---|---|---|---|"]
		for row in crew["table"]:
			lines.append("| %s | %s | %s | %s | %s | %s | %s | %s |" % [row["crew"], _pct(row["kicked"]), _pct(row["delivered"]),
				Py.f(row["over_drop_s"], 0), _pct(row["flagged"]), _pct(row["busted"]), _pct(row["crashed"]), Py.f(row["minutes"], 1)])
		var ld: Dictionary = crew["loading_s"]
		lines += ["", "Ramp loading at a bush strip (no ground crew): %s s solo, %s s with a co-pilot." % [Py.f(ld["solo"], 1), Py.f(ld["copilot"], 1)], ""]
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
		"- Sample sizes: tactical cells have 10-30 flights each. Anything under about 10 points of "
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
