extends TestCase
## The ground war: roads, Lanchester firefights, cover, the guerrilla and
## narcotics doctrines, trucks at checkpoints, turf, the AI commanders and the
## commands. Most tests switch the AI commanders off and place squads by hand.


func after_each() -> void:
	World.use_map(0)


func _war(seed := 3, ai := false) -> Session:
	var s := Session.new({"seed": seed, "map_seed": MapCity.SEED, "location": "QRY",
		"features": Session.SANDBOX_FEATURES, "ground_war": true})
	s.police.frozen = true
	if not ai:
		s.ground._started = true  # no opening deployment
		for f in s.ground.commanders:
			s.ground.commanders[f].ai = false
	s.update(1.0 / 30)
	return s


func _squad(g: GroundWar, f: String, at: Vector2, loadout: Dictionary, kind := "foot") -> GroundWar.Squad:
	var q = g.recruit(f, kind, at, false)
	var n := 0
	for t in loadout:
		n += int(loadout[t])
	g.arsenal(f).give_back(q.loadout)
	q.loadout = loadout.duplicate()
	q.men = n
	q.men0 = q.men
	q.ammo = q.men * 90
	q.morale = 0.8
	q.state = "holding"
	return q


## Where on the map a land-use class is (a point for cover tests).
func _find(w: World, cls: int) -> Vector2:
	for y in range(-12000, 12000, 250):
		for x in range(-12000, 12000, 250):
			if MapCity.at(w.map.land_use, x, y) == cls:
				return Vector2(x, y)
	return Vector2.ZERO


## Fight a and b out (rounds only, no movement); returns the winner's faction or "".
func _duel(g: GroundWar, a, b) -> String:
	g._open(a, b)
	for i in 120:
		g._rounds(GroundWar.ROUND_S)
		if a.fight == null or b.fight == null:
			break
	if a.state in ["routed", "gone"] or a.men <= 0:
		return b.faction
	if b.state in ["routed", "gone"] or b.men <= 0:
		return a.faction
	return ""


## Win rate of a fight set up by `make` (returns [a, b]) over n seeds.
func _rate(n: int, make: Callable) -> float:
	var s := _war()
	var g := s.ground
	var wins := 0
	for i in n:
		var r := PyRandom.new()
		r.seed(1000 + i)
		g.frng = r
		for q in g.squads.duplicate():
			g.squads.erase(q)
		g.fights.clear()
		var ab: Array = make.call(g)
		if _duel(g, ab[0], ab[1]) == ab[0].faction:
			wins += 1
	s.dispose()
	return float(wins) / n


# ------------------------------------------------------------------ roads
func test_every_stash_and_hq_is_on_the_road_network() -> void:
	var s := _war()
	var g := s.ground
	check(g.graph.road_nodes >= 20, "the city's roads make a graph (%d nodes)" % g.graph.road_nodes)
	for st in s.stash_net.stashes:
		for f in ["org", "rival", "police"]:
			check(g.graph.connected(g.hq(f), Vector2(st.x, st.y)), "%s can reach %s" % [f, st.name])
	var r := g.graph.route(g.hq("org"), Vector2(s.stash_net.stashes[0].x, s.stash_net.stashes[0].y))
	check(r[0].distance_to(g.hq("org")) < 1.0 and r[r.size() - 1].distance_to(Vector2(s.stash_net.stashes[0].x, s.stash_net.stashes[0].y)) < 1.0,
		"routes start and end where asked")
	check(RoadGraph.length(r) >= g.hq("org").distance_to(r[r.size() - 1]), "and follow the roads (no shorter than the crow)")
	s.dispose()


func test_squads_drive_the_roads() -> void:
	var s := _war()
	var g := s.ground
	var q := _squad(g, "org", g.hq("org"), {"rifle": 4}, "car")
	var st: Dictionary = s.stash_net.get_stash("lockup")
	check_eq(g.order(q, {"type": "guard", "stash": "lockup"}), "", "a guard order")
	var eta := RoadGraph.length(q.route) / GroundWar.SPEED.car
	for i in int(eta) + 20:
		g._move(1.0)
	check(q.pos().distance_to(Vector2(st.x, st.y)) < 5.0, "the car got there by road in about %.0f s" % eta)
	s.dispose()


# ------------------------------------------------------------------ firefights
func test_numbers_win_twice_over() -> void:
	var big := _rate(40, func(g): return [_squad(g, "org", Vector2(0, 0), {"rifle": 8}), _squad(g, "rival", Vector2(100, 0), {"rifle": 4})])
	check(big >= 0.9, "eight rifles beat four (%.0f%%)" % (big * 100))
	var arms := _rate(40, func(g): return [_squad(g, "org", Vector2(0, 0), {"rifle": 4}), _squad(g, "rival", Vector2(100, 0), {"pistol": 4})])
	check(arms >= 0.75, "rifles beat pistols (%.0f%%)" % (arms * 100))


## A city-block cell with open ground (grass, farm or beach) within 150 m.
func _edge(w: World) -> Array:
	for y in range(-11000, 11000, 200):
		for x in range(-11000, 11000, 200):
			if MapCity.at(w.map.land_use, x, y) != MapCity.URBAN:
				continue
			for o in [Vector2(150, 0), Vector2(-150, 0), Vector2(0, 150), Vector2(0, -150)]:
				var p: Vector2 = Vector2(x, y) + o
				if MapCity.at(w.map.land_use, p.x, p.y) in [MapCity.GRASS, MapCity.FARM, MapCity.BEACH]:
					return [Vector2(x, y), p]
	return []


func test_cover_matters() -> void:
	var s := _war()
	var e := _edge(s.world)
	check(not e.is_empty(), "found the edge of town")
	check(s.ground.cover(_squad(s.ground, "org", e[0], {"rifle": 1})) < s.ground.cover(_squad(s.ground, "org", e[1], {"rifle": 1})),
		"the city blocks are cover")
	s.dispose()
	var covered := _rate(60, func(g): return [_squad(g, "org", e[0], {"rifle": 4}), _squad(g, "rival", e[1], {"rifle": 4})])
	check(covered >= 0.65, "the side in the city blocks wins more (%.0f%%)" % (covered * 100))


## Casualties inflicted per casualty taken by the first squad, over n seeds.
func _exchange(n: int, make: Callable) -> float:
	var s := _war()
	var g := s.ground
	var given := 0
	var taken := 0
	for i in n:
		var r := PyRandom.new()
		r.seed(2000 + i)
		g.frng = r
		for q in g.squads.duplicate():
			g.squads.erase(q)
		g.fights.clear()
		var ab: Array = make.call(g)
		var a0: int = ab[0].men
		var b0: int = ab[1].men
		_duel(g, ab[0], ab[1])
		given += b0 - maxi(0, ab[1].men)
		taken += a0 - maxi(0, ab[0].men)
	s.dispose()
	return float(given) / maxf(1.0, taken)


func test_an_ambush_trades_better_than_an_open_fight() -> void:
	var open := _exchange(60, func(g): return [_squad(g, "org", Vector2(0, 0), {"rifle": 4}), _squad(g, "police", Vector2(100, 0), {"rifle": 4})])
	var ambush := _exchange(60, func(g):
		var a := _squad(g, "org", Vector2(0, 0), {"rifle": 4})
		g.order(a, {"type": "ambush", "x": 0.0, "y": 0.0})
		a.route = PackedVector2Array()
		return [a, _squad(g, "police", Vector2(100, 0), {"rifle": 4})])
	check(ambush > open * 1.5, "an ambush hits and runs: %.2f casualties given per one taken vs %.2f in the open" % [ambush, open])


func test_police_hold_fire_until_fired_upon() -> void:
	var s := _war()
	var g := s.ground
	var cop := _squad(g, "police", Vector2(0, 0), {"rifle": 4})
	var perp := _squad(g, "org", Vector2(100, 0), {"rifle": 4})
	g._open(cop, perp)
	check_eq(g._losses(cop, perp, cop.fight), 0, "no police shot in the first round")
	s.dispose()


func test_a_hopeless_squad_surrenders_and_its_guns_go_to_the_police() -> void:
	var s := _war()
	var g := s.ground
	var law0: int = s.arsenals.law.count()
	var cop := _squad(g, "police", Vector2(0, 0), {"rifle": 8}, "truck")
	var perp := _squad(g, "org", Vector2(80, 0), {"pistol": 2})
	g._contacts()
	check_eq(perp.state, "gone", "they put their hands up")
	check(g.arrests_total == 2, "two arrested")
	check_eq(s.arsenals.law.count(), law0 + 2, "their pistols are evidence, then the arsenal's")
	check(s.police.case("runner").suspicion > 0.0, "and they talk: heat on the organisation")
	s.dispose()


func test_melted_squads_are_found_only_close_in() -> void:
	var s := _war()
	var g := s.ground
	var q := _squad(g, "org", Vector2(0, 0), {"rifle": 4})
	q.hidden = true
	q.tactic = "melt"
	var cop := _squad(g, "police", Vector2(200, 0), {"rifle": 4})
	g._contacts()
	check(q.fight == null, "at 200 m the patrol walks past")
	cop.x = 90.0
	check(g.can_see("police", q), "at 90 m they're found")
	s.dispose()


func test_perimeter_raids_let_nobody_escape() -> void:
	var escaped := {true: 0, false: 0}
	for cordon in [true, false]:
		for i in 30:
			var s := _war(10 + i)
			var g := s.ground
			var cop := _squad(g, "police", Vector2(0, 0), {"rifle": 8}, "truck")
			cop.order = {"type": "raid", "perimeter": cordon}
			var guard := _squad(g, "org", Vector2(50, 0), {"pistol": 4})
			g._open(cop, guard)
			var men := guard.men
			var a0 := g.arrests_total
			g._rout(guard, cop.fight)
			escaped[cordon] += men - (g.arrests_total - a0)
			s.dispose()
	check_eq(escaped[true], 0, "a cordon: every guard arrested")
	check(escaped[false] > 0, "no cordon: some get away (%d)" % escaped[false])


# ------------------------------------------------------------------ trucks
func _truck(s: Session, stash := "lockup") -> StashNet.Truck:
	var jid := Jobs.new_id()
	var st: Dictionary = s.stash_net.get_stash(stash)
	var job := Jobs.Job.new(jid, "t", "contraband", "QRY", st.strip,
		[Jobs.item("Kilo brick crate", "cargo", 20, jid, {"hot": true})], 3000, {"stash": stash})
	s.active_jobs.append(job)
	s._truck_out(job, World.airfield(st.strip))
	return s.stash_net.trucks.back()


func test_trucks_follow_the_roads() -> void:
	var s := _war()
	var t := _truck(s)
	check(t.route.size() >= 2, "the truck has a road route")
	check_eq(t.stop_at, -1.0, "no dice-roll roadblock: the checkpoints are on the ground")
	s.dispose()


func test_a_checkpoint_stops_an_unescorted_truck() -> void:
	var s := _war()
	var g := s.ground
	var st: Dictionary = s.stash_net.get_stash("lockup")
	st.intel = 60.0  # they know the house: stop it, don't tail it
	var t := _truck(s)
	var mid := RoadGraph.along(t.route, RoadGraph.length(t.route) * 0.5)
	var cp := _squad(g, "police", mid, {"rifle": 4}, "car")
	g.order(cp, {"type": "checkpoint", "x": mid.x, "y": mid.y})
	cp.route = PackedVector2Array()
	var seized := false
	for i in int(t.dur) + 60:
		s.update(1.0)
		if s.stash_net.trucks.is_empty():
			seized = s.messages.any(func(m): return "was stopped" in m[1])
			break
	check(seized, "stopped at the checkpoint")
	s.dispose()


func test_an_escort_fights_the_checkpoint_instead() -> void:
	var s := _war()
	var g := s.ground
	s.stash_net.get_stash("lockup").intel = 60.0
	var t := _truck(s)
	var mid := RoadGraph.along(t.route, RoadGraph.length(t.route) * 0.5)
	var cp := _squad(g, "police", mid, {"pistol": 3}, "car")
	g.order(cp, {"type": "checkpoint", "x": mid.x, "y": mid.y})
	cp.route = PackedVector2Array()
	var e := _squad(g, "org", Vector2(t.x0, t.y0), {"rifle": 6, "mg": 2}, "truck")
	g.order(e, {"type": "escort", "job_id": t.job_id})
	var fought := false
	for i in int(t.dur) * 2:
		s.update(1.0)
		fought = fought or not g.fights.is_empty()
		if s.stash_net.trucks.is_empty():
			break
	check(fought, "the escort opened up on the checkpoint")
	check(s.messages.any(func(m): return "Truck in at" in m[1]), "and the truck got through")
	s.dispose()


func test_a_tail_finds_the_stash() -> void:
	var s := _war()
	var g := s.ground
	var st: Dictionary = s.stash_net.get_stash("lockup")
	var t := _truck(s)
	var cop := _squad(g, "police", Vector2(t.x0, t.y0), {"pistol": 2}, "car")
	cop.tactic = "tail"
	cop.order = {"type": "tail", "job_id": t.job_id}
	g.tails[t.job_id] = [cop.id, "lockup"]
	for i in int(t.dur) + 30:
		s.update(1.0)
		if not g.tails.has(t.job_id):
			break
	check(st.intel >= StashNet.KNOWN_HEAT, "followed it home: the task force knows %s (intel %.0f)" % [st.name, st.intel])
	check(s.stash_net.known().has(st), "it's a known stash now")
	s.dispose()


# ------------------------------------------------------------------ turf and AI
func test_turf_follows_who_is_on_the_street() -> void:
	var s := _war()
	var g := s.ground
	var c: Array = Economy.centre("north")
	for k in 3:
		_squad(g, "rival", Vector2(c[0] + k * 50, c[1]), {"rifle": 4})
	for i in 30:
		g._control(60.0)
	check(g.rival_share("north") > 0.9, "Los Cuervos hold the north (%.2f)" % g.rival_share("north"))
	var t := g.turf({})
	check(t.north > 0.5, "and the market sees it (%.2f)" % t.north)
	check_eq(g.rival_share("sea"), -1.0, "nobody at sea: no say")
	check(absf(g.turf_delta("north")) <= 0.06, "the season nudge is capped")
	s.dispose()


func test_the_ai_commanders_run_it_within_their_means() -> void:
	var s := _war(7, true)
	s.money = 40000
	s.law_funds = 20000.0
	var t0 := Time.get_ticks_msec()
	for i in 3600:
		s.update(1.0)
	var ms := Time.get_ticks_msec() - t0
	var g := s.ground
	for f in GroundWar.CAP:
		check(g.of(f).size() <= GroundWar.CAP[f], "%s within its cap" % f)
	check(g.squads.size() <= GroundWar.MAX_SQUADS, "within the global cap")
	check(g.squads.all(func(q): return q.state != "gone" and q.men > 0), "no dead squads left on the books")
	check(s.law_log.size() > 0, "the desk heard about it")
	check(ms < 30000, "an hour of war in %d ms" % ms)
	s.dispose()


func test_commands_from_the_seats() -> void:
	var s := _war()
	var g := s.ground
	s.money = 10000
	check(s.command(Roles.BOSS, "recruit_squad", {"kind": "car"})[0], "the boss raises a squad")
	check_eq(s.money, 10000 - GroundWar.COST.car, "and pays for it")
	var q: GroundWar.Squad = g.of("org").back()
	check(s.command(Roles.BOSS, "squad_order", {"id": q.id, "order": {"type": "guard", "stash": "barn"}})[0], "orders it")
	check(q.human, "a human's order: the AI leaves it alone")
	check(not s.command(Roles.CONTROLLER, "squad_order", {"id": q.id, "order": {"type": "hold"}})[0], "the desk can't order the gang")
	check(s.command(Roles.CHIEF, "recruit_squad", {"kind": "car"})[0], "the chief raises a patrol")
	check(s.command(Roles.BOSS, "disband_squad", {"id": q.id})[0], "and stands it down")
	check(g.get_squad(q.id) == null, "gone")
	s.dispose()


func test_the_snapshot_shows_each_side_what_it_can_see() -> void:
	var s := _war()
	var g := s.ground
	var mine := _squad(g, "org", g.hq("org"), {"rifle": 4})
	var far := _squad(g, "police", Vector2(12000, 9000), {"rifle": 4})
	var snap := g.snapshot("org")
	var ids: Array = snap.squads.map(func(d): return d.id)
	check(ids.has(mine.id), "our own")
	check(not ids.has(far.id), "not a patrol across the island")
	s.dispose()


func test_off_means_no_war() -> void:
	GroundWar.ENABLED = false
	var s := Session.new({"seed": 3, "map_seed": MapCity.SEED, "location": "QRY", "ground_war": true})
	check(s.ground == null, "no ground war")
	s.dispose()
	GroundWar.ENABLED = true
