extends SceneTree
## The live-play systems' balance: the Family, Isla Soberana's trade and the
## Company's double game, which the season simulator (scripts/balance/) doesn't
## model. Many seeds of a few simulated hours each, stepping those systems
## directly (fast: no flight model), under stated stand-ins:
##
##   - flown runs are an income of RUN_PAY every RUN_EVERY_S (what the bot's
##     calibrated runs earn, roughly); the task force's budget grows likewise
##   - the organisation's AI takes the Family's offers by their read
##     (Family.ai_wants), pays tribute when it can, and trades with the island:
##     mules when their odds are under MULE_MAX, a container when under SHIP_MAX
##   - the task force's AI buys the customs tree as the money comes, orders a
##     crackdown or inspections after a catch, and files RICO when it can
##
##   godot --headless --script res://tools/live_balance.gd -- [seeds] [hours]
##
## Writes sim-results/live.json; `cli.gd -- report` puts it in docs/BALANCE.md.

const RUN_PAY := 1500
const RUN_EVERY_S := 300.0
const LAW_PAY := 900.0
const LAW_EVERY_S := 600.0
const MULE_MAX := 0.3
const SHIP_MAX := 0.25
const STEP := 10.0

var seeds := 60
var hours := 3.0


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0:
		seeds = int(a[0])
	if a.size() > 1:
		hours = float(a[1])
	var t0 := Time.get_ticks_msec()
	var configs := {
		"control": {},
		"family": {"family": true},
		"island": {"island": true},
		"agency": {"agency": true},
		"payroll": {"payroll": true},
		"all": {"family": true, "island": true, "agency": true, "chronicle": true, "payroll": true},
	}
	var out := {"seeds": seeds, "hours": hours, "stand_ins": {"run_pay": RUN_PAY, "run_every_s": RUN_EVERY_S,
		"law_pay": LAW_PAY, "law_every_s": LAW_EVERY_S, "mule_max": MULE_MAX, "ship_max": SHIP_MAX}, "configs": {}}
	for name in configs:
		var rows := []
		for sd in seeds:
			rows.append(_run(sd + 1, configs[name]))
		out.configs[name] = _summary(rows)
		print("%-8s money p50 $%s  law p50 $%s" % [name, Py.money(int(out.configs[name].money.p50)), Py.money(int(out.configs[name].law_funds.p50))])
	out["odds"] = _odds_table()
	out["seconds"] = (Time.get_ticks_msec() - t0) / 1000.0
	DirAccess.make_dir_recursive_absolute("res://sim-results")
	var f := FileAccess.open("res://sim-results/live.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "  "))
	f.close()
	print("live.json written (%.0f s)" % out.seconds)
	quit()


func _run(sd: int, extra: Dictionary) -> Dictionary:
	var o := {"seed": sd, "map_seed": MapCity.SEED, "location": "HAR", "features": Session.SANDBOX_FEATURES}
	o.merge(extra)
	var s := Session.new(o)
	s.police.frozen = true
	s.money = 16000
	s.law_funds = 9000.0
	var r := {"money_min": s.money, "tribute_paid": 0, "shipped": 0, "caught_units": 0, "sent_units": 0,
		"spent_island": 0, "earned_island": 0}
	var t := 0.0
	var next_run := RUN_EVERY_S
	var next_law := LAW_EVERY_S
	var next_trade := 600.0
	var last_caught := 0
	var closed_s := 0.0
	var tribute0 := 0
	var coke := [INF, -INF]
	var guns_sum := 0.0
	var dis_max := 0.0
	var ticks := 0
	while t < hours * 3600.0:
		t += STEP
		s.time = t
		if t >= next_run:
			next_run += RUN_EVERY_S
			s.money += RUN_PAY
		if t >= next_law:
			next_law += LAW_EVERY_S
			s.law_funds += LAW_PAY
		if s.family != null:
			s.family.update(STEP)
			# the law files RICO when it can spare the money
			if s.law_funds > 12000.0 and not s.family.gone and int(t) % 600 == 0:
				s.family.rico_case()
		if s.agency != null:
			s.agency.update(STEP)
			if int(t) % 1800 == 0 and s.agency.active():
				_agency_flight(s)
		if s.chronicle != null:
			s.chronicle.update(STEP)
		if s.payroll != null:
			s.payroll.update(STEP)
		if s.island != null:
			var isl := s.island
			isl.update(STEP)
			if not isl.open():
				closed_s += STEP
			if t >= next_trade:
				next_trade += 600.0
				var m0 := s.money
				if isl.mule_odds()[0] < MULE_MAX and s.money > 20000 and isl.ship("mules", 4) == "":
					r.shipped += 1
					r.sent_units += 4
					r.spent_island += m0 - s.money
				m0 = s.money
				if isl.ship_odds()[0] < SHIP_MAX and s.money > 40000 and isl.ship("ship", 500) == "":
					r.shipped += 1
					r.sent_units += 1
					r.spent_island += m0 - s.money
			# the task force: the customs tree, then a crackdown after a catch
			for id in Island.LAW_NODES:
				var n := Upgrades.node("law", id)
				if not s.upgrades.law.has(id) and s.law_funds > float(n.cost) + 6000.0 and Upgrades.blocker("law", id, s.upgrades.law, int(s.law_funds)) == "":
					s.law_funds -= float(n.cost)
					s.upgrades.law[id] = true
			if isl.caught > last_caught:
				last_caught = isl.caught
				if s.law_funds > 5000.0:
					s.command(Roles.CONTROLLER, "airport_crackdown")
			# and the organisation buys its perks when rich
			for id in Island.RUNNER_NODES:
				var n := Upgrades.node("runner", id)
				if not s.upgrades.runner.has(id) and s.money > int(n.cost) * 4 and Upgrades.blocker("runner", id, s.upgrades.runner, s.money) == "":
					s.money -= int(n.cost)
					s.upgrades.runner[id] = true
		# the markets: supply and demand move with everything above
		s.econ.update(STEP, t, [], [], {}, s.ground)
		if int(t) % 60 == 0:
			var c := s.econ.mult("cocaine", "town")
			coke = [minf(coke[0], c), maxf(coke[1], c)]
			guns_sum += s.econ.mult("guns", "town")
			ticks += 1
			for m in Economy.MARKETS:
				dis_max = maxf(dis_max, s.econ.market.disruption[m])
		r.money_min = mini(r.money_min, s.money)
	r["market"] = {"coke_lo": coke[0], "coke_hi": coke[1], "guns": guns_sum / maxf(1.0, ticks), "disruption": dis_max,
		"coke_lots": s.agency.coke_lots if s.agency != null else 0, "gun_lots": s.agency.gun_lots if s.agency != null else 0}
	r["money"] = s.money
	r["law_funds"] = s.law_funds
	r["suspicion"] = s.police.case("runner").suspicion
	if s.family != null:
		r.tribute_paid = s.family.tribute_total
		r["family"] = {"cons": s.family.cons, "loans": s.family.loans_taken, "rat": s.family.rat, "gone": s.family.gone,
			"respect": s.family.respect, "taxed": s.family.taxed}
	if s.island != null:
		r["island"] = {"caught": s.island.caught, "delivered": s.island.delivered, "intercepts": s.island.intercepts,
			"closed_frac": closed_s / (hours * 3600.0), "relations": s.island.relations}
	if s.payroll != null:
		var pr := s.payroll
		r["payroll"] = {"crew": pr.of("org").filter(func(w): return w.status in ["free", "assigned"]).size(), "paid": pr.paid_total.org,
			"lost": pr.lost.org, "flips": pr.flips.org, "loyalty": pr.loyalty("org"), "short": pr.unpaid.org > 0}
	if s.agency != null:
		r["agency"] = {"flights": s.agency.flights, "hung_out": s.agency.hung_out, "burned": s.agency.burned,
			"stings": r.get("stings", 0), "withheld": s.agency.withheld, "exposure": s.agency.exposure}
	s.dispose()
	return r


## An Agency flight, flown and delivered (the air risk isn't modelled here).
func _agency_flight(s: Session) -> void:
	var j = s.agency.job_from(World.airfield("QRY"), s.world.airfields)
	if j == null:
		return
	if s.agency.flight_done(j):
		s.money -= mini(maxi(0, s.money), 1500 + int(maxi(0, s.money) * 0.25))  # the sting: a bust's fine
		return
	s.money += j.payout


func _pct(xs: Array, q: float) -> float:
	if xs.is_empty():
		return 0.0
	var v := xs.duplicate()
	v.sort()
	return float(v[clampi(int(q * (v.size() - 1)), 0, v.size() - 1)])


func _stats(xs: Array) -> Dictionary:
	var m := 0.0
	for x in xs:
		m += float(x)
	return {"mean": m / maxf(1.0, xs.size()), "p10": _pct(xs, 0.1), "p50": _pct(xs, 0.5), "p90": _pct(xs, 0.9)}


func _rate(rows: Array, sect: String, key: String) -> float:
	var have := rows.filter(func(r): return r.has(sect))
	if have.is_empty():
		return 0.0
	return float(have.filter(func(r): return bool(r[sect][key])).size()) / have.size()


func _mean(rows: Array, sect: String, key: String) -> float:
	var have := rows.filter(func(r): return r.has(sect))
	if have.is_empty():
		return 0.0
	var m := 0.0
	for r in have:
		m += float(r[sect][key])
	return m / have.size()


func _summary(rows: Array) -> Dictionary:
	var sm := {"money": _stats(rows.map(func(r): return r.money)), "money_min": _stats(rows.map(func(r): return r.money_min)),
		"law_funds": _stats(rows.map(func(r): return r.law_funds)), "suspicion": _stats(rows.map(func(r): return r.suspicion))}
	if rows[0].has("family"):
		sm["family"] = {"cons": _mean(rows, "family", "cons"), "loans": _mean(rows, "family", "loans"),
			"rat_rate": _rate(rows, "family", "rat"), "trial_rate": _rate(rows, "family", "gone"),
			"taxed_rate": _rate(rows, "family", "taxed"), "respect": _mean(rows, "family", "respect"),
			"tribute_paid": _stats(rows.map(func(r): return r.tribute_paid))}
	if rows[0].has("island"):
		var sent := 0
		var caught := 0
		var spent := 0
		for r in rows:
			sent += int(r.sent_units)
			caught += int(r.island.caught)
			spent += int(r.spent_island)
		sm["island"] = {"shipments": _stats(rows.map(func(r): return r.shipped)), "units_sent": sent, "units_caught": caught,
			"catch_rate": float(caught) / maxf(1.0, sent), "closed_frac": _mean(rows, "island", "closed_frac"),
			"intercepts": _mean(rows, "island", "intercepts"), "relations": _mean(rows, "island", "relations"), "spent": spent}
	if rows[0].has("payroll"):
		sm["payroll"] = {"crew": _mean(rows, "payroll", "crew"), "paid": _mean(rows, "payroll", "paid"), "lost": _mean(rows, "payroll", "lost"),
			"flips": _mean(rows, "payroll", "flips"), "loyalty": _mean(rows, "payroll", "loyalty"), "short_rate": _rate(rows, "payroll", "short")}
	sm["market"] = {"coke_lo": _mean(rows, "market", "coke_lo"), "coke_hi": _mean(rows, "market", "coke_hi"),
		"guns": _mean(rows, "market", "guns"), "disruption": _mean(rows, "market", "disruption"),
		"coke_lots": _mean(rows, "market", "coke_lots"), "gun_lots": _mean(rows, "market", "gun_lots")}
	if rows[0].has("agency"):
		sm["agency"] = {"flights": _mean(rows, "agency", "flights"), "hangout_rate": _rate(rows, "agency", "hung_out"),
			"burned_rate": _rate(rows, "agency", "burned"), "withheld": _mean(rows, "agency", "withheld"),
			"exposure": _mean(rows, "agency", "exposure")}
	return sm


## The island's odds and expected return per dollar, cold and under each side's kit.
func _odds_table() -> Array:
	var s := Session.new({"seed": 1, "map_seed": MapCity.SEED, "location": "HAR", "features": Session.SANDBOX_FEATURES, "island": true})
	var isl := s.island
	var rows := []
	var cases := [
		["cold", [], []],
		["law: dogs + profiling", [], ["sniffer_dogs", "passenger_profiling"]],
		["law: everything + crackdown", [], ["sniffer_dogs", "passenger_profiling", "container_xray", "crackdown"]],
		["ours: all perks", ["mule_school", "forged_papers", "baggage_handlers", "false_bottoms"], []],
		["both: everything", ["mule_school", "forged_papers", "baggage_handlers", "false_bottoms"],
			["sniffer_dogs", "passenger_profiling", "container_xray", "crackdown"]],
	]
	var mule_cost := float(Island.MULE_COST)
	# loads are sold at today's street price: take the usual one (three quiet hours of the market)
	var street := {"town": 0.0, "sea": 0.0}
	var n := 0
	for i in 1080:
		s.econ.update(10.0, i * 10.0, [], [], {}, null)
		if i % 6 == 0:
			street.town += s.econ.mult("cocaine", "town")
			street.sea += s.econ.mult("cocaine", "sea")
			n += 1
	var mule_value: float = Island.MULE_VALUE * street.town / n
	var ship_cost := 500 * Island.PRICE_PER_LB + Island.SHIP_FREIGHT
	var ship_value: float = 500 * Island.STREET_PER_LB * street.town / n
	for c in cases:
		s.upgrades.runner.clear()
		s.upgrades.law.clear()
		isl.crackdown_until = -1.0
		isl.inspections_until = -1.0
		for id in c[1]:
			s.upgrades.runner[id] = true
		for id in c[2]:
			if id == "crackdown":
				isl.crackdown_until = s.time + 999.0
				isl.inspections_until = s.time + 999.0
			else:
				s.upgrades.law[id] = true
		var pm: float = isl.mule_odds()[0]
		var ps: float = isl.ship_odds()[0]
		rows.append({"case": c[0], "mule_p": snappedf(pm, 0.001), "ship_p": snappedf(ps, 0.001),
			"mule_roi": snappedf(((1.0 - pm) * mule_value - mule_cost) / mule_cost, 0.01),
			"ship_roi": snappedf(((1.0 - ps) * ship_value - ship_cost) / ship_cost, 0.01)})
	s.dispose()
	return rows
