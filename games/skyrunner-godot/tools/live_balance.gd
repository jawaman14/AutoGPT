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
##   - the story config plays the chapters (Story): systems open as it goes (the
##     flown runs count as its deliveries, every other one hot); the
##     AI buys rifles once guns open and sells the Company four at a time
##
##   godot --headless --script res://tools/live_balance.gd -- [seeds] [hours] [config [first seed]]
##   (one config writes sim-results/live-<config>.json; the story's is run -- 40 12 story)
##
## Writes sim-results/live.json; `cli.gd -- report` puts it in docs/BALANCE.md.

const RUN_PAY := 1500
const RUN_EVERY_S := 300.0
const LAW_PAY := 900.0
const LAW_EVERY_S := 600.0
const MULE_MAX := 0.3
const SHIP_MAX := 0.25
const STEP := 10.0
const DECAY_SHARE := 0.1  ## of PoliceSystem's decay: its full rate assumes nobody's watching; the war keeps them looking

var seeds := 60
var hours := 3.0


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0:
		seeds = int(a[0])
	if a.size() > 1:
		hours = float(a[1])
	var t0 := Time.get_ticks_msec()
	# (a script error below would leave the tree running: the caller's timeout is the backstop)
	var configs := {
		"control": {},
		"family": {"family": true},
		"island": {"island": true},
		"agency": {"agency": true},
		"payroll": {"payroll": true},
		"trade": {"trade": true, "career": true, "payroll": true, "family": true, "agency": true},
		"all": {"family": true, "island": true, "agency": true, "chronicle": true, "payroll": true, "trade": true, "career": true},
		"logistics": {"trade": true, "career": true, "payroll": true, "family": true, "agency": true, "logistics": true},
		"war": {"family": true, "island": true, "agency": true, "chronicle": true, "payroll": true, "trade": true, "career": true, "ground_war": true},
		"story": {"story": true, "career": true},
	}
	if a.size() > 2:  # one config only
		configs = {a[2]: configs[a[2]]}
	else:
		configs.erase("story")  # a campaign, not three hours: its own run (-- 40 12 story)
	var first := int(a[3]) if a.size() > 3 else 1  # the first seed (to rerun one)
	var out := {"seeds": seeds, "hours": hours, "stand_ins": {"run_pay": RUN_PAY, "run_every_s": RUN_EVERY_S,
		"law_pay": LAW_PAY, "law_every_s": LAW_EVERY_S, "mule_max": MULE_MAX, "ship_max": SHIP_MAX}, "configs": {}}
	for name in configs:
		var rows := []
		for sd in seeds:
			var w0 := Time.get_ticks_msec()
			rows.append(_run(sd + first, configs[name]))
			printerr("  seed %d: %.1f s" % [sd + first, (Time.get_ticks_msec() - w0) / 1000.0])
		out.configs[name] = _summary(rows)
		print("%-8s money p50 $%s  law p50 $%s" % [name, Py.money(int(out.configs[name].money.p50)), Py.money(int(out.configs[name].law_funds.p50))])
	out["odds"] = _odds_table()
	out["seconds"] = (Time.get_ticks_msec() - t0) / 1000.0
	DirAccess.make_dir_recursive_absolute("res://sim-results")
	var fname := "live.json" if a.size() <= 2 else "live-%s.json" % a[2]  # one config: a file of its own
	var f := FileAccess.open("res://sim-results/" + fname, FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "  "))
	f.close()
	print("%s written (%.0f s)" % [fname, out.seconds])
	quit()


func _run(sd: int, extra: Dictionary) -> Dictionary:
	var o := {"seed": sd, "map_seed": MapCity.SEED, "location": "HAR", "features": Session.SANDBOX_FEATURES}
	o.merge(extra)
	var s := Session.new(o)
	if extra.get("story", false):
		Story.new().attach(s)
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
	var next_own := 900.0
	var connected_at := -1.0
	var chapter_min := [0.0]
	var nw_max := 0.0  # the best net worth in the last chapter (what its goal measures)
	while t < hours * 3600.0:
		t += STEP
		s.time = t
		if s.story != null:
			s.story.tick(s)
			nw_max = maxf(nw_max, float(s.story.progress.get("net_worth", 0.0)))
			while chapter_min.size() < s.story.index + 1 + (1 if s.story.completed_all else 0):
				chapter_min.append(t / 60.0)
			if s.unlocked("guns") and s.arsenals.org.count() < 10 and s.money > 12000 and int(t) % 300 == 0:
				s.command(Roles.BOSS, "buy_weapons", {"tier": "rifle", "n": 2})
			if s.agency != null and s.agency.active() and int(s.arsenals.org.stock.get("rifle", 0)) >= 4 and int(t) % 600 == 0:
				s.trade.sell("agency", "guns", 4, "rifle", "", true)  # careful: not into a checkpoint
		if t >= next_run:
			next_run += RUN_EVERY_S
			s.money += RUN_PAY
			if s.story != null:  # the story counts the pilot's flown jobs; every other one hot
				s.bus.emit("job_delivered", t, "", ["runner"], {"job_id": -1, "pay": RUN_PAY, "dest": "", "hot": int(t / RUN_EVERY_S) % 2 == 0,
					"good": "", "lb": 0.0, "agency": false, "origin": ""})
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
				# with logistics the island's product lands in a stash and has to be sold:
				# the AI buys only when the stash runs low, as it does its own loads (and in
				# the island chapter, whose goal is a load from the island, it buys anyway)
				var room: bool = s.logistics == null or s.trade.stock.cocaine < 150.0 \
					or (s.story != null and s.story.progress.get("island_runs", 0.0) < 1.0 and s.story.chapter.year == 1984)
				if room and isl.mule_odds()[0] < MULE_MAX and s.money > 20000 and isl.ship("mules", 4) == "":
					r.shipped += 1
					r.sent_units += 4
					r.spent_island += m0 - s.money
				m0 = s.money
				if room and isl.ship_odds()[0] < SHIP_MAX and s.money > 40000 and isl.ship("ship", 500) == "":
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
		# the trade: an own load every 15 minutes (grass until the Colombians call, then cocaine)
		if s.trade != null:
			s.trade.update(STEP)
			if t >= next_own:
				next_own += 900.0
				var af := World.airfield("QRY" if s.trade.connected else "FRM")
				var g := "cocaine" if s.trade.connected else "marijuana"
				var low: bool = s.trade.stock[g] < (150.0 if g == "cocaine" else 800.0)  # buy when the stash runs low
				var j = s.trade.board_offer(af, s.rng) if low else null
				if j != null and s.money > j.cost + 5000:
					s.money -= j.cost
					s.trade.delivered(j)
					if s.story != null:  # the story counts loads (the other configs as before)
						s.bus.emit("job_delivered", t, "", ["runner"], s._delivered(j, 0, World.airfield(j.dest), true))
			if s.trade.connected and connected_at < 0.0:
				connected_at = t
		# the trucks: product to the corners, cash home, lots to the buyers (the AI's orders)
		if s.logistics != null:
			s.logistics.update(STEP)
		if s.logistics != null or s.ground != null:
			s._update_stashes(STEP)  # trucks, and the street war (GroundWar.update)
		if s.ground != null:
			# the police's own decay (PoliceSystem.update, SUSPICION_DECAY a second
			# while the runner isn't seen): the flown runs are the stand-in, so the
			# case cools between them as in live play
			for c in s.police.cases.values():
				c.suspicion = maxf(0.0, c.suspicion - PoliceSystem.SUSPICION_DECAY * STEP * DECAY_SHARE)
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
	if s.ground != null:
		var g: GroundWar = s.ground
		r["war"] = {"recruit": g.spent.recruit, "upkeep": g.spent.upkeep, "arms": g.spent.arms,
			"fights": g.fights_total, "org_lost": g.lost_men.org, "rival_lost": g.lost_men.rival, "police_lost": g.lost_men.police,
			"org_arrested": g.arrests_total,
			"squads": g.of("org").size(), "rival_squads": g.of("rival").size(), "police_squads": g.of("police").size(),
			"burned": s.stash_net.stashes.filter(func(st): return st.burned).size() if s.stash_net != null else 0}
	if s.logistics != null:
		r["logistics"] = {"cash_out": s.logistics.cash_out(), "lost_cash": s.logistics.lost.cash, "lost_lb": s.logistics.lost.product,
			"lost_seized": s.logistics.lost_by.seized, "lost_hijacked": s.logistics.lost_by.hijacked, "lost_raided": s.logistics.lost_by.raided}
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
	if s.trade != null:
		r["trade"] = {"earned": s.trade.earned, "sold_coke": s.trade.sold.cocaine, "sold_weed": s.trade.sold.marijuana,
			"stock_coke": s.trade.stock.cocaine, "stock_weed": s.trade.stock.marijuana, "connected_min": (connected_at / 60.0) if connected_at >= 0.0 else hours * 60.0,
			"dealers": s.payroll.of("org", "dealer").filter(func(w): return w.status in ["free", "assigned"]).size() if s.payroll != null else 0,
			"bulk": s.trade.bulk_log.size(),
			"stock_value": s.trade.stock.cocaine * s.trade.street_price("cocaine", "town") + s.trade.stock.marijuana * s.trade.street_price("marijuana", "town")}
	if s.story != null:
		r["story"] = {"chapter": s.story.index + 1 + (1 if s.story.completed_all else 0), "minutes": chapter_min,
			"net_worth": float(s.money) + (s.trade.stock_value() if s.trade != null else 0.0) + (s.logistics.cash_out() if s.logistics != null else 0.0), "nw_max": nw_max}
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
	if s.story != null:
		s.bus.emit("job_delivered", s.time, "", ["runner"], s._delivered(j, j.payout, World.airfield(j.dest), true))


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
	if rows.any(func(r): return r.has("family")):
		sm["family"] = {"cons": _mean(rows, "family", "cons"), "loans": _mean(rows, "family", "loans"),
			"rat_rate": _rate(rows, "family", "rat"), "trial_rate": _rate(rows, "family", "gone"),
			"taxed_rate": _rate(rows, "family", "taxed"), "respect": _mean(rows, "family", "respect"),
			"tribute_paid": _stats(rows.map(func(r): return r.tribute_paid))}
	if rows.any(func(r): return r.has("island")):
		var sent := 0
		var caught := 0
		var spent := 0
		for r in rows:
			sent += int(r.sent_units)
			caught += int(r.island.caught) if r.has("island") else 0  # (the story opens it part-way)
			spent += int(r.spent_island)
		sm["island"] = {"shipments": _stats(rows.map(func(r): return r.shipped)), "units_sent": sent, "units_caught": caught,
			"catch_rate": float(caught) / maxf(1.0, sent), "closed_frac": _mean(rows, "island", "closed_frac"),
			"intercepts": _mean(rows, "island", "intercepts"), "relations": _mean(rows, "island", "relations"), "spent": spent}
	if rows.any(func(r): return r.has("payroll")):
		sm["payroll"] = {"crew": _mean(rows, "payroll", "crew"), "paid": _mean(rows, "payroll", "paid"), "lost": _mean(rows, "payroll", "lost"),
			"flips": _mean(rows, "payroll", "flips"), "loyalty": _mean(rows, "payroll", "loyalty"), "short_rate": _rate(rows, "payroll", "short")}
	sm["market"] = {"coke_lo": _mean(rows, "market", "coke_lo"), "coke_hi": _mean(rows, "market", "coke_hi"),
		"guns": _mean(rows, "market", "guns"), "disruption": _mean(rows, "market", "disruption"),
		"coke_lots": _mean(rows, "market", "coke_lots"), "gun_lots": _mean(rows, "market", "gun_lots")}
	if rows.any(func(r): return r.has("trade")):
		sm["trade"] = {}
		for k in rows.filter(func(r): return r.has("trade"))[0]["trade"]:
			sm["trade"][k] = _mean(rows, "trade", k)
	if rows.any(func(r): return r.has("war")):
		sm["war"] = {}
		for k in ["recruit", "upkeep", "arms", "fights", "org_lost", "rival_lost", "police_lost", "org_arrested", "squads", "rival_squads", "police_squads", "burned"]:
			sm["war"][k] = _mean(rows, "war", k)
	if rows.any(func(r): return r.has("logistics")):
		sm["logistics"] = {"cash_out": _mean(rows, "logistics", "cash_out"), "lost_cash": _mean(rows, "logistics", "lost_cash"),
			"lost_lb": _mean(rows, "logistics", "lost_lb"), "lost_seized": _mean(rows, "logistics", "lost_seized"),
			"lost_hijacked": _mean(rows, "logistics", "lost_hijacked"), "lost_raided": _mean(rows, "logistics", "lost_raided")}
	if rows.any(func(r): return r.has("story")):
		var reached := []
		for n in Story.CHAPTERS.size() + 1:
			var at := rows.filter(func(r): return r.has("story") and r.story.minutes.size() > n).map(func(r): return r.story.minutes[n])
			reached.append({"chapter": n + 1, "share": float(at.size()) / rows.size(), "min_p50": _pct(at, 0.5)})
		sm["story"] = {"chapter": _stats(rows.map(func(r): return r.story.chapter)), "reached": reached,
			"net_worth": _stats(rows.filter(func(r): return r.has("story")).map(func(r): return r.story.net_worth))}
	if rows.any(func(r): return r.has("agency")):
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
