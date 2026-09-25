extends TestCase
## Generated islands: every strip usable, the zones and HQs where the rules
## need them, sessions and bots working on them, saves remembering them.
## Each test puts the classic island back, because the rest of the suite (and
## the Python parity fixtures) live on it.

const SEEDS := [11, 29, 4242]


func after_each() -> void:
	World.use_map(0)


func test_generated_strips_are_flat_dry_clear_and_approachable() -> void:
	for seed in SEEDS:
		World.use_map(seed)
		var w := World.new()
		check_eq(w.airfields.size(), 10, "seed %d strips" % seed)
		for af in w.airfields:
			var elev: float = w.airfield_elev(af)
			check(elev > 0, "%d %s above sea (%.1f)" % [seed, af.code, elev])
			for along in [-0.5, 0, 0.5]:
				for across in [-0.5, 0, 0.5]:
					var x: float = af.x + af.ux * along * af.length + af.uy * across * af.width
					var y: float = af.y + af.uy * along * af.length - af.ux * across * af.width
					check_near(w.ground(x, y), elev, 1e-6 * maxf(1.0, elev), "%d %s flat" % [seed, af.code])
					check(not w.tree_hit(x, y, elev + 2), "%d %s clear of trees" % [seed, af.code])
			check(MapGen._clear_approach(w.terrain, af.x, af.y, af.ux, af.uy, af.length, elev), "%d %s approach" % [seed, af.code])
			for other in w.airfields:
				if other != af:
					check(PyMath.hypot(other.x - af.x, other.y - af.y) > 2500, "%d %s/%s spacing" % [seed, af.code, other.code])


func test_zones_hqs_and_aerostat_follow_the_map() -> void:
	World.use_map(SEEDS[0])
	var w := World.new()
	for z in HQ.ZONES:
		check(HQ.ZONE_CENTRE.has(z), "zone centre " + z)
		for code in HQ.ZONE_FIELDS[z]:
			check(World.AIRFIELD_BY_CODE.has(code), "zone %s strip %s exists" % [z, code])
	check(w.height(HQ.ZONE_CENTRE["sea"][0], HQ.ZONE_CENTRE["sea"][1]) < 0, "sea zone centre is at sea")
	check_eq(SensorNet.AEROSTAT_POS, w.map.aerostat_pos, "aerostat moved with the map")
	for k in ["org", "law", "rival"]:
		var hq: Dictionary = w.map.hqs[k]
		check(w.ground(hq.x, hq.y) > 2, "%s HQ on dry land" % k)
		check(w.airfield_at(hq.x, hq.y, 40) == null, "%s HQ off the runways" % k)
	# and back: the classic island has HQs too
	World.use_map(0)
	var c := World.new()
	check_eq(c.airfields.size(), 8, "classic strips")
	check_eq(HQ.ZONE_CENTRE["sea"], [13000.0, -11000.0], "classic zones restored")
	check(c.map.hqs.has("org") and c.map.hqs.has("rival"), "classic HQs sited")


func test_generation_is_deterministic() -> void:
	var a := MapGen.generate(SEEDS[1])
	var b := MapGen.generate(SEEDS[1])
	for i in a.airfields.size():
		check_eq([a.airfields[i].code, a.airfields[i].x, a.airfields[i].y, a.airfields[i].heading],
			[b.airfields[i].code, b.airfields[i].x, b.airfields[i].y, b.airfields[i].heading], "strip %d" % i)
	var c := MapGen.generate(SEEDS[1] + 1)
	check(a.airfields[0].x != c.airfields[0].x, "another seed, another island")


func test_session_jobs_and_a_bot_flight_on_a_generated_island() -> void:
	var s := Session.new({"seed": 5, "map_seed": SEEDS[2], "location": "HAR", "features": []})
	check_eq(s.map_seed, SEEDS[2])
	check(s.boards.has("HAR") and not s.boards["HAR"].is_empty(), "job board at the hub")
	var dests := {}
	for i in 25:
		s.refresh_board("HAR")
		for j in s.boards["HAR"]:
			dests[j.dest] = true
	check(dests.has("MSN") and dests.has("LGN"), "the new strips get work: %s" % [dests.keys()])
	s.police.frozen = true
	var val := World.airfield("VAL")
	var bot := PilotBot.new(s, [PilotBot.Leg.new("land", val.x, val.y, "VAL")])
	check_eq(PilotBot.fly(s, bot, 1200), "landed", "HAR -> VAL on island %d" % SEEDS[2])
	s.dispose()


func test_saves_remember_the_island() -> void:
	var path := "user://test_map_save.json"
	var s := Session.new({"seed": 1, "map_seed": SEEDS[0], "save_path": path})
	s.save()
	s.dispose()
	World.use_map(0)
	var t := Session.load_or_new(path)
	check_eq(t.map_seed, SEEDS[0], "reloaded on the same island")
	check_eq(World.layout.map_seed, SEEDS[0], "layout switched back")
	t.dispose()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
