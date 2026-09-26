extends TestCase
## The markets (Economy): rival gangs, police presence, the type of goods,
## fuel, scarcity, glut, weather and the news move what a load is worth.


func _econ(seed := 1) -> Economy:
	var r := PyRandom.new()
	r.seed(seed)
	var e := Economy.new(r)
	for g in e.walk:  # start flat so each test sees only its own factor
		for m in Economy.MARKETS:
			e.walk[g][m] = 1.0
	return e


const NO_TURF := {"town": 0.0, "west": 0.0, "north": 0.0, "sea": 0.0}


## One tick of the factors, without the random walk's noise.
func _tick(e: Economy, police := [], rivals := [], turf := NO_TURF) -> void:
	e.update(Economy.TICK_S, 0.0, police, rivals, turf)
	for g in e.walk:
		for m in Economy.MARKETS:
			e.walk[g][m] = 1.0
	e.fuel_walk = 1.0


func test_the_goods_and_the_markets() -> void:
	check_eq(Economy.market_of("HAR"), "town", "the hub is the town market")
	check_eq(Economy.market_of("COV"), "sea", "the cove sells to the sea zone")
	check_eq(Economy.market_of("SEA"), "sea", "airdrops too")
	var r := PyRandom.new()
	r.seed(2)
	var job := Jobs.airdrop_job(World.airfield("HAR"), [9000.0, -12000.0], r, 3)
	check_eq(Economy.good_of(job), "marijuana", "bales are grass")
	check_eq(Economy.job_market(job), "sea", "sold at sea")


func test_rivals_undercut_drugs_but_buy_guns() -> void:
	var e := _econ()
	_tick(e, [], [], {"west": 0.0, "north": 0.0, "sea": 0.0, "town": 0.0})
	var coke0 := e.mult("cocaine", "west")
	var guns0 := e.mult("guns", "west")
	_tick(e, [], [], {"west": 0.9, "north": 0.0, "sea": 0.0, "town": 0.0})
	check(e.mult("cocaine", "west") < coke0 * 0.8, "Los Cuervos own the west: cocaine pays less there (%.2f)" % e.mult("cocaine", "west"))
	check(e.mult("guns", "west") > guns0 * 1.1, "and they're buying guns (%.2f)" % e.mult("guns", "west"))
	var c: Array = Economy.centre("north")
	var before := e.mult("cocaine", "north")
	_tick(e, [], [[c[0], c[1]], [c[0] + 500, c[1]]], {"west": 0.9, "north": 0.0, "sea": 0.0, "town": 0.0})
	check(e.mult("cocaine", "north") < before, "rival flights in the north undercut there too")


func test_police_presence_is_a_risk_premium() -> void:
	var e := _econ()
	_tick(e)
	var quiet := e.mult("cocaine", "town")
	var legal := e.mult("general", "town")
	var c: Array = Economy.centre("town")
	var cops := [[c[0], c[1]], [c[0] + 800, c[1]], [c[0], c[1] + 900]]
	_tick(e, cops)
	check(e.mult("cocaine", "town") > quiet * 1.08, "cops all over town: the street pays for danger (%.2f)" % e.mult("cocaine", "town"))
	check_near(e.mult("general", "town"), legal, 1e-9, "legal freight doesn't care")
	check_near(e.mult("cocaine", "sea"), quiet, 1e-9, "only where they are")


func test_seizures_make_it_scarce_and_deliveries_flood_it() -> void:
	var e := _econ()
	_tick(e)
	var p0 := e.mult("marijuana", "sea")
	e.record_seizure("marijuana", "sea")
	e.record_seizure("marijuana", "sea")
	check(e.mult("marijuana", "west") > p0 * 1.15, "boats seized: grass is scarce island-wide")
	var e2 := _econ()
	_tick(e2)
	for i in 4:
		e2.record_delivery("cocaine", "north")
	check(e2.mult("cocaine", "north") < 0.85, "four loads into the north: the market is flooded")
	check_near(e2.mult("cocaine", "west"), e2.mult("cocaine", "town"), 0.05, "the other markets aren't")
	for i in 540:  # an hour and a half
		e2.update(Economy.TICK_S, i * Economy.TICK_S, [], [], {})
	check(e2.glut["cocaine"]["north"] < 0.01, "the glut clears in time")


func test_fuel_passes_through() -> void:
	var e := _econ()
	_tick(e)
	e.fuel_walk = 1.3  # after the tick (which flattens it)
	check_near(e.mult("fuel_drums", "town"), 1.3, 1e-6, "fuel drums pay what fuel costs")
	check(e.mult("passengers", "town") > 1.15, "fares carry a fuel surcharge")
	check_near(e.mult("cocaine", "town"), 1.0, 0.25, "cocaine barely notices")
	var s := Session.new({"seed": 3, "location": "HAR"})
	s.update(1.0 / 30)
	var base: float = s.fuel_source()[0]
	s.econ.fuel_walk = 1.5
	check_near(s.fuel_source()[0], base * 1.5, 1e-6, "and the pump price follows")
	s.dispose()


func test_the_walk_stays_sane_for_a_season() -> void:
	var e := _econ(9)
	var lo := 9.0
	var hi := 0.0
	var sum := 0.0
	var n := 0
	for i in 6 * 60 * 10:  # ten hours of ticks
		e.update(Economy.TICK_S, i * Economy.TICK_S, [], [], {})
		for g in Economy.GOODS:
			var m := e.mult(g, "west")
			lo = minf(lo, m)
			hi = maxf(hi, m)
			sum += e.walk[g]["west"]
			n += 1
	check(lo >= 0.4 and hi <= 2.5, "clamped: %.2f..%.2f" % [lo, hi])
	check_near(sum / n, 1.0, 0.08, "the walk reverts to the usual price")
	check(not e.news.is_empty(), "and there was news")


func test_boards_and_deliveries_follow_the_market() -> void:
	var s := Session.new({"seed": 3, "location": "QRY", "features": Session.SANDBOX_FEATURES})
	s.update(1.0 / 30)
	for g in s.econ.walk:
		for m in Economy.MARKETS:
			s.econ.walk[g][m] = 1.0
	s.econ.scarcity["guns"] = 0.5
	s.econ.scarcity["marijuana"] = 0.5
	s.econ.scarcity["cocaine"] = 0.5
	s.refresh_board("QRY")
	var hot = Py.first(s.boards["QRY"], func(j): return j.hot() and not j.is_airdrop() and j.kind == "contraband")
	check(hot != null and hot.price_mult > 1.3, "scarce goods: the board pays more (%.2f)" % (hot.price_mult if hot else 0.0))
	# the price falls while we fly: paid at the street price
	s.econ.scarcity[Economy.good_of(hot)] = 0.0
	var g := s._grade(hot)
	check(g[0] < hot.payout * 0.85, "the market fell: $%d for a $%d board price" % [g[0], hot.payout])
	check("street price" in g[1], "and the note says why: " + g[1])
	s.dispose()


func test_news_reaches_the_pilot_and_the_desk_sees_the_market() -> void:
	var s := Session.new({"seed": 3, "location": "HAR"})
	s.update(1.0 / 30)
	s.econ.news.append([s.time, "Tourist season: charter fares up"])
	s.update(1.0 / 30)
	check(s.messages.any(func(m): return m[1] == "Market news: Tourist season: charter fares up"), "the pilot hears it")
	var snap := Snapshot.build(s, Roles.CONTROLLER)
	check(snap.has("market") and snap.market.goods.size() == Economy.GOODS.size(), "the desk has the market")
	check(Snapshot.build(s, Roles.COPILOT).has("market"), "so does the crew")
	s.dispose()


func test_off_means_flat() -> void:
	Economy.REALISM = false
	var e := _econ()
	e.record_seizure("cocaine", "west")
	e.fuel_walk = 1.4
	for g in Economy.GOODS:
		check_eq(e.mult(g, "west"), 1.0, g + " at the Python price")
	check_eq(e.fuel_mult(), 1.0, "fuel too")
	Economy.REALISM = true
