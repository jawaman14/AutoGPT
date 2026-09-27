extends TestCase
## Supply and demand on the street (Market, under Economy's prices): arrests,
## raids and informants break distribution networks; rival shipments flood and
## rival losses dry up their markets; the island's and the Family's fortunes
## move the source and the wholesale price; the street's own news moves
## demand; everything recovers. Off with Economy.REALISM.


func after_each() -> void:
	World.use_map(0)
	Economy.REALISM = true


func _sess(opts := {}) -> Session:
	var o := {"seed": 7, "map_seed": MapCity.SEED, "location": "HAR", "features": Session.SANDBOX_FEATURES}
	o.merge(opts, true)
	var s := Session.new(o)
	s.police.frozen = true
	s.update(1.0 / 30)
	return s


## Run the markets `minutes` forward (no police, no rivals: just time).
func _run(s: Session, minutes: float) -> void:
	for i in int(minutes * 6):
		s.econ.update(10.0, s.time + i * 10.0, [], [], {}, s.ground)
	s.time += minutes * 60.0


func test_supply_and_demand_set_the_street_price() -> void:
	var m := Market.new(Session._rng(1))
	check_near(m.factor("cocaine", "town"), 1.0, 1e-9, "normal: no change")
	m.flow("cocaine", "town", -0.5)
	check_near(m.factor("cocaine", "town"), pow(2.0, Market.ELASTICITY), 1e-6, "half the supply: %.2fx the price" % m.factor("cocaine", "town"))
	check_near(m.factor("cocaine", "west"), 1.0, 1e-9, "only in that market")
	m.flow("marijuana", "sea", 0.8)
	check(m.factor("marijuana", "sea") < 0.8, "a flood: cheaper (%.2f)" % m.factor("marijuana", "sea"))
	m.flow("guns", "north", -5.0)
	check(m.factor("guns", "north") <= 1.9, "clamped")
	check_near(m.factor("general", "town"), 1.0, 1e-9, "legal goods have no street")


func test_shocks_heal() -> void:
	var m := Market.new(Session._rng(2))
	m.disrupt("west", 0.8)
	m.source_shock("cocaine", -0.5)
	m.update(10.0, 0.0, null)
	m.update(600.0, 600.0, null)
	check(m.supply.cocaine.west < 0.6, "a broken network and a short source: little gets through (%.2f)" % m.supply.cocaine.west)
	check(m.wholesale("cocaine") > 1.3, "and the wholesale's up (%.2f)" % m.wholesale("cocaine"))
	for i in 12:
		m.update(600.0, 1200.0 + i * 600.0, null)
	check(m.disruption.west < 0.05 and absf(m.supply.cocaine.west - 1.0) < 0.15, "two hours on: back to normal (%.2f, %.2f)" % [m.disruption.west, m.supply.cocaine.west])


func test_a_raid_breaks_the_network_and_the_street_pays() -> void:
	var s := _sess()
	var st: Dictionary = s.stash_net.stashes[0]
	var zone: String = st.zone
	var other: String = "north" if zone != "north" else "west"
	_run(s, 2)  # the same (quiet) streets before and after
	var p0 := s.econ.mult("cocaine", zone) / s.econ.mult("cocaine", other)
	st.heat = 90.0
	s._raid(st.id)
	check(s.econ.market.disruption[zone] > 0.3, "the network in the %s is broken" % zone)
	_run(s, 5)
	var p1 := s.econ.mult("cocaine", zone) / s.econ.mult("cocaine", other)
	check(s.econ.market.factor("cocaine", zone) > 1.1, "short on the street there (%.2f)" % s.econ.market.factor("cocaine", zone))
	check(p1 > p0 * 1.08, "cocaine's dearer there than elsewhere (%.2f -> %.2f)" % [p0, p1])
	check(s.econ.market.why[zone] != "", "and the desk knows why: %s" % s.econ.market.why[zone])
	check(s.econ.news.any(func(n): return "raid" in n[1].to_lower()), "it's in the market news")
	s.dispose()


func test_arrests_move_markets() -> void:
	var s := _sess({"payroll": true, "ground_war": true})
	var org_zones := {}
	for st in s.stash_net.live():
		org_zones[st.zone] = true
	var z: String = org_zones.keys()[0]
	# a bust: the organisation's corners go dry
	s.bus.emit("busted", s.time, "", ["runner", "law"], {})
	check(s.econ.market.disruption[z] >= 0.3, "the pilot's bust hits the organisation's markets")
	# an arrested worker
	var d0: float = s.econ.market.disruption[z]
	var w: Dictionary = s.payroll._person("org", "soldier")
	s.payroll.candidates.org.append(w)
	s.money = 100000
	s.payroll.hire("org", w.id)
	s.payroll.lose(w.id, "arrested")
	check(s.econ.market.disruption.values().any(func(v): return v > 0.0), "a worker arrested: more damage")
	check(s.econ.market.disruption[z] >= d0, "")
	s.dispose()


func test_a_gunfight_closes_the_corners() -> void:
	var s := _sess({"ground_war": true})
	s.ground._started = true
	for f in s.ground.commanders:
		s.ground.commanders[f].ai = false
	var a = s.ground.recruit("org", "foot", MapCity.CITY_C, false)
	var b = s.ground.recruit("police", "foot", MapCity.CITY_C + Vector2(40, 0), false)
	s.ground._open(a, b)
	var f = s.ground.fights.back()
	var m: String = GroundWar.market_at(f.x, f.y)
	_run(s, 1)
	check(s.econ.market.disruption[m] > 0.1, "a fight in the %s: its corners close (%.2f)" % [m, s.econ.market.disruption[m]])
	var d0: float = s.econ.market.disruption[m]
	f.arrests += 4
	_run(s, 0.2)
	check(s.econ.market.disruption[m] > d0 + 0.15, "four arrested: dealers off the street")
	s.dispose()


func test_rival_shipments_flood_and_the_island_sets_the_wholesale() -> void:
	var s := _sess({"island": true, "ground_war": true})
	var sea0: float = s.econ.market.supply.cocaine.sea
	s.bus.emit("rival_shipment", s.time, "", ["law"], {"market": "sea"})
	check(s.econ.market.supply.cocaine.sea > sea0 + 0.1, "a Los Cuervos container: more on the docks")
	# the island: a hurricane chokes the source, the wholesale and the wait go up
	var w0 := s.econ.wholesale("cocaine")
	s.island.status = "hurricane"
	s.bus.emit("island_status", s.time, "", ["runner", "law"], {"status": "hurricane"})
	check(s.econ.wholesale("cocaine") > w0 * 1.2, "a hurricane: the island's wholesale is up (%.2f)" % s.econ.wholesale("cocaine"))
	check(s.econ.restock_mult("cocaine") > 1.15, "and the connection needs longer between loads (x%.2f)" % s.econ.restock_mult("cocaine"))
	_run(s, 150)
	check(s.econ.wholesale("cocaine") < w0 * 1.1, "and it recovers (%.2f)" % s.econ.wholesale("cocaine"))
	var sea1: float = s.econ.market.supply.cocaine.sea
	s.bus.emit("island_status", s.time, "", ["runner", "law"], {"status": "glut"})
	check(s.econ.market.supply.cocaine.sea > sea1, "a glut on the island reaches the docks")
	s.dispose()


func test_the_familys_fall_takes_the_guns_and_rivals_sell_at_street_prices() -> void:
	var s := _sess({"island": true, "ground_war": true, "family": true})
	var g0: float = s.econ.market.source.guns
	s.bus.emit("commission_trial", s.time, "", ["runner", "law"], {"stashes": 0})
	check(s.econ.market.source.guns < g0 - 0.3, "no more fence: guns are hard to find")
	check(s.econ.market.disruption.town >= 0.4, "and the town's network is gone with the Family")
	# Los Cuervos sell their island loads at what the street pays: dry markets pay them more
	s.ground.commanders.rival.cash = 1000000.0
	s.island.rng = Session._rng(5)
	var c0: float = s.ground.commanders.rival.cash
	s.island._rival_trade()
	var normal: float = s.ground.commanders.rival.cash - c0
	s.econ.market.flow("cocaine", "sea", -0.6)
	s.island.rng = Session._rng(5)
	c0 = s.ground.commanders.rival.cash
	s.island._rival_trade()
	check(s.ground.commanders.rival.cash - c0 > normal, "a dry market: their load's worth more")
	s.dispose()


func test_the_street_has_its_own_news() -> void:
	var s := _sess()
	_run(s, 240)
	check(s.econ.news.any(func(n): return Market.STREET_NEWS.any(func(x): return x[4] == n[1])), "a street headline in four hours")
	var b := s.econ.board()
	check(b.street.goods.has("cocaine") and b.street.disruption.has("town"), "the board carries the street")
	check(Snapshot.build(s, Roles.BOSS).market.has("street"), "and so does the desk's snapshot")
	s.dispose()


func test_the_market_page_shows_the_street() -> void:
	var s := _sess()
	s.bus.emit("stash_raided", s.time, "", ["runner", "law"], {"stash": s.stash_net.stashes[0].id})
	var jm := JobMenu.new()
	jm.setup(s)
	Engine.get_main_loop().root.add_child(jm)
	jm.page = 1
	jm.refresh()
	check("Networks broken" in jm.footer.text, "the footer names the broken network: %s" % jm.footer.text)
	jm.queue_free()
	s.dispose()


func test_off_means_flat() -> void:
	var s := _sess()
	s.econ.market.flow("cocaine", "town", -0.6)
	s.econ.market.source_shock("cocaine", -0.5)
	Economy.REALISM = false
	check_eq(s.econ.mult("cocaine", "town"), 1.0, "no street effect in the Python replays")
	check_eq(s.econ.wholesale("cocaine"), 1.0, "nor on the island's price")
	check_eq(s.econ.restock_mult("cocaine"), 1.0, "nor its wait")
	Economy.REALISM = true
	s.dispose()


## The Company's pipeline: cocaine north, guns south, and the markets feel both.
func test_the_contra_pipeline_moves_both_markets() -> void:
	var s := _sess({"agency": true})
	var a := s.agency
	a.prng = Session._rng(3)
	var c0 := {}
	for m in ["town", "north", "sea"]:
		c0[m] = s.econ.market.supply.cocaine[m]
	var g0: float = s.econ.market.supply.guns.town
	var gp0 := s.econ.market.factor("guns", "town")
	var e0 := a.exposure
	var w0 := s.econ.wholesale("cocaine")
	for i in 4:
		a._pipe_t = Agency.PIPE_S
		a._pipeline(0.0)
	check(a.coke_lots >= 4, "cocaine flown north (%d lots)" % a.coke_lots)
	var flooded := ["town", "north", "sea"].filter(func(m): return s.econ.market.supply.cocaine[m] > c0[m] + 0.1)
	check(not flooded.is_empty(), "a street flooded with the Company's cocaine: %s" % [flooded])
	check(s.econ.market.factor("cocaine", flooded[0]) < 0.95, "cheap there (%.2f)" % s.econ.market.factor("cocaine", flooded[0]))
	check(a.gun_lots > 0 and s.econ.market.supply.guns.town < g0, "the proceeds bought guns off the street")
	check(s.econ.market.factor("guns", "town") > gp0 * 1.05, "guns are dear (%.2f -> %.2f)" % [gp0, s.econ.market.factor("guns", "town")])
	check(s.econ.wholesale("cocaine") > w0, "the Company buying upstream tightens the island's wholesale")
	check(a.exposure > e0, "and it leaves a trail (exposure %.0f)" % a.exposure)
	check(a.view("runner").pipeline != "", "the desk sees it: %s" % a.view("runner").pipeline)
	check(a.view("law").pipeline_lots == a.coke_lots, "the task force counts the lots")
	s.dispose()


func test_the_pipeline_pauses_when_hung_out_and_stops_when_exposed() -> void:
	var s := _sess({"agency": true})
	var a := s.agency
	a.prng = Session._rng(4)
	a.hung_out = true
	a._pipe_t = Agency.PIPE_S
	a._pipeline(0.0)
	check_eq(a.coke_lots, 0, "hung out: it covers itself first")
	a.burned = true
	a.update(Agency.PIPE_S * 10)
	check_eq(a.coke_lots, 0, "exposed: the pipeline's over")
	s.dispose()


func test_a_war_chest_puts_return_legs_on_the_board() -> void:
	var s := _sess({"agency": true})
	var a := s.agency
	a.prng = Session._rng(5)
	a.war_chest = 100000.0
	var legs := 0
	for i in 60:
		var j = a.job_from(World.airfield("QRY") if World.AIRFIELD_BY_CODE.has("QRY") else s.world.airfields.filter(func(x): return x.kind == "shady")[0], s.world.airfields)
		if j != null and j.title.begins_with("Return leg"):
			legs += 1
			check(j.agency and Economy.good_of(j) == "cocaine", "a protected cocaine flight north")
	check(legs > 5, "return legs offered (%d of 60)" % legs)
	s.dispose()
