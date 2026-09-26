extends TestCase
## Costa Brava (MapCity): the strips usable, the regions where they belong,
## the city clear of every glide path, the HQs and stash houses on dry land,
## and the stash runs: the truck, the roadblock, the raid.

func after_each() -> void:
	World.use_map(0)


func _world() -> World:
	World.use_map(MapCity.SEED)
	return World.new()


func test_strips_are_flat_clear_and_approachable() -> void:
	var w := _world()
	check_eq(w.airfields.size(), 9, "nine strips")
	for af in w.airfields:
		var elev: float = w.airfield_elev(af)
		check(elev > 0, "%s above the sea (%.1f)" % [af.code, elev])
		for along in [-0.5, 0, 0.5]:
			for across in [-0.5, 0, 0.5]:
				var x: float = af.x + af.ux * along * af.length + af.uy * across * af.width
				var y: float = af.y + af.uy * along * af.length - af.ux * across * af.width
				check_near(w.ground(x, y), elev, 1e-6 * maxf(1.0, elev), "%s flat" % af.code)
				check(not w.tree_hit(x, y, elev + 2), "%s clear of trees and buildings" % af.code)
		check(MapGen._clear_approach(w.terrain, af.x, af.y, af.ux, af.uy, af.length, elev), "%s terrain approach" % af.code)
		# and no tree or building in the way at 3.5 degrees from one end, 200 m to 1.5 km out
		var clear_end := false
		for end in [-1.0, 1.0]:
			var ok := true
			for d in range(200, 1500, 100):
				var x: float = af.x + end * af.ux * (af.length / 2 + d)
				var y: float = af.y + end * af.uy * (af.length / 2 + d)
				if w.obstacle_top(x, y, 30.0) > elev + d * tan(deg_to_rad(3.5)):
					ok = false
					break
			clear_end = clear_end or ok
		check(clear_end, "%s has an obstacle-free approach" % af.code)
		for other in w.airfields:
			if other != af:
				check(PyMath.hypot(other.x - af.x, other.y - af.y) > 2500, "%s/%s spacing" % [af.code, other.code])


func test_every_region_is_there() -> void:
	var w := _world()
	var census := {}
	for c in w.map.land_use:
		census[c] = census.get(c, 0) + 1
	for c in [MapCity.URBAN, MapCity.PORT, MapCity.MANGROVE, MapCity.SWAMP, MapCity.FARM, MapCity.JUNGLE, MapCity.SCRUB, MapCity.BEACH]:
		check(census.get(c, 0) > 150, "%s: %d cells" % [MapCity.CLASS_NAMES[c], census.get(c, 0)])
	check(w.map.buildings.size() > 2000, "a city: %d buildings" % w.map.buildings.size())
	check(w.map.buildings.any(func(b): return b.style == "crane"), "cranes on the docks")
	check(w.height(-1000, -11700) < -5, "the harbour basin is deep water")
	# the river runs to the sea
	var c := MapCity.river_course()
	check(w.height(c[c.size() / 2].x, c[c.size() / 2].y) < 0, "water in the river mid-course")


func test_no_trees_on_the_roads_or_in_the_fields() -> void:
	var w := _world()
	var trees := w.terrain.get_trees()
	var mask := MapCity.road_mask(w.map.roads)
	var on_road := 0
	var in_fields := 0
	var in_town := 0
	for k in trees.size() / 4:
		var x: float = trees[k * 4]
		var y: float = trees[k * 4 + 1]
		if MapCity.on_road(mask, x, y) and MapCity.road_dist(w.map.roads, x, y) < 7.0:
			on_road += 1  # a tree or a building on the carriageway
		var cls := MapCity.at(w.map.land_use, x, y)
		if cls == MapCity.FARM:
			in_fields += 1
	check_eq(on_road, 0, "nothing stands on a road")
	check(in_fields < 4000, "fields mostly open: %d hedgerow trees" % in_fields)


func test_hqs_and_stashes_sit_on_dry_land() -> void:
	var w := _world()
	for k in ["org", "law", "rival"]:
		var hq: Dictionary = w.map.hqs[k]
		check(w.ground(hq.x, hq.y) > 2, "%s on dry land" % k)
		check(not w.tree_hit(hq.x, hq.y, w.ground(hq.x, hq.y) + 2, 8.0), "%s: nothing standing on the plot" % k)
		check(w.airfield_at(hq.x, hq.y, 40) == null, "%s off the runways" % k)
	check_eq(w.map.hqs["org"].style, "nightclub", "the organisation runs a nightclub")
	check_eq(w.map.hqs["law"].style, "customs", "the task force works from the customs house")
	for st in w.map.stashes:
		check(w.ground(st.x, st.y) > 1, "%s on dry land" % st.id)
		var af := World.airfield(st.strip)
		check(PyMath.hypot(af.x - st.x, af.y - st.y) < 8000, "%s within a truck ride of %s" % [st.id, st.strip])
	for z in HQ.ZONES:
		for code in HQ.ZONE_FIELDS[z]:
			check(World.AIRFIELD_BY_CODE.has(code), "zone %s strip %s" % [z, code])
	check(w.height(SensorNet.AEROSTAT_POS[0], SensorNet.AEROSTAT_POS[1]) < 0, "the aerostat moors at sea")


func test_generation_is_deterministic() -> void:
	var a := MapCity.generate()
	var b := MapCity.generate()
	for i in a.airfields.size():
		check_eq([a.airfields[i].x, a.airfields[i].y, a.airfields[i].heading], [b.airfields[i].x, b.airfields[i].y, b.airfields[i].heading],
			a.airfields[i].code)


func _stash_session() -> Array:
	var s := Session.new({"seed": 3, "map_seed": MapCity.SEED, "location": "FRM", "features": Session.SANDBOX_FEATURES})
	s.update(1.0 / 30)
	s.police.frozen = true
	var job = null
	for i in 20:
		job = Py.first(s.boards["FRM"], func(j): return j.stash != "")
		if job != null:
			break
		s.refresh_board("FRM")
	check(job != null, "a stash job on the farm strip's board")
	job.dest = "FRM"  # pretend we flew it in
	job.stash = "barn"
	s.accept_job(job)
	s.loadout.pending.clear()
	s._arrive(s.airfield, s.state)
	return [s, job]


func test_a_stash_run_lands_then_trucks_in() -> void:
	var r := _stash_session()
	var s: Session = r[0]
	var job: Jobs.Job = r[1]
	check(not (job in s.active_jobs), "the job is off the aircraft")
	check(s.loadout.items.values().all(func(i): return i.job_id != job.id), "the crates are on the truck")
	check_eq(s.stash_net.trucks.size(), 1, "one truck on the road")
	var t: StashNet.Truck = s.stash_net.trucks[0]
	t.stop_at = -1.0  # no roadblock this time
	var money := s.money
	for i in int(t.dur / 0.5) + 4:
		s.update(0.5)
	check(s.stash_net.trucks.is_empty(), "the truck arrived")
	check_eq(s.money, money + t.pay, "paid on arrival")
	check_near(s.stash_net.get_stash("barn").heat, StashNet.HEAT_DELIVERY, 1.0, "the barn warms up")
	s.dispose()


func test_the_police_stop_the_truck_and_raid_the_stash() -> void:
	var r := _stash_session()
	var s: Session = r[0]
	var t: StashNet.Truck = s.stash_net.trucks[0]
	t.stop_at = 0.5
	var funds := s.law_funds
	var money := s.money
	for i in int(t.dur / 0.5) + 4:
		s.update(0.5)
	check(s.stash_net.trucks.is_empty() and s.money == money, "stopped: no pay")
	check(s.law_funds > funds + 2000.0, "the task force forfeits the load")
	check(s.messages.any(func(m): return "stopped" in m[1]), "the runner hears about it")
	var why = s.command(Roles.CONTROLLER, "raid_stash", {"id": "shack"})
	check(not why[0], "no intelligence on a cold stash")
	s.stash_net.get_stash("barn").heat = 40.0
	check(s.command(Roles.CONTROLLER, "raid_stash", {"id": "barn"})[0], "the barn is known: raided")
	check(s.stash_net.get_stash("barn").burned, "burned")
	for i in 30:
		s.refresh_board("FRM")
		s.refresh_board("QRY")
		for j in s.boards["FRM"] + s.boards["QRY"]:
			check(j.stash != "barn", "no more work for a burned stash")
	s.dispose()


func test_classic_island_has_no_stashes() -> void:
	var s := Session.new({"seed": 3, "location": "FRM", "features": Session.SANDBOX_FEATURES})
	check(s.stash_net == null, "the classic island: no stash houses, the jobs as before")
	s.dispose()
