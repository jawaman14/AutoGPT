extends TestCase
## Upgrade trees (Upgrades): the data holds together, buying needs the parent
## and the money, and each node does what it says - counter-surveillance,
## espionage, the airframe, weaponry on the runner's side; sensors, signals,
## intelligence and interdiction on the task force's.


func _s(opts := {}) -> Session:
	var o := {"seed": 5, "location": "HAR", "features": Session.SANDBOX_FEATURES}
	o.merge(opts, true)
	var s := Session.new(o)
	s.update(1.0 / 30)
	return s


func test_the_trees_hold_together() -> void:
	var seen := {}
	for side in Upgrades.TREES:
		for tree in Upgrades.TREES[side]:
			for n in tree[2]:
				check(not seen.has(n.id), "unique id " + n.id)
				seen[n.id] = true
				check(int(n.cost) > 0 and str(n.desc) != "", n.id + " has a price and a description")
				for r in n.req:
					check_eq(Upgrades.side_of(r), side, "%s needs %s on the same side" % [n.id, r])
	for g in Upgrades.GEAR_NODES:
		check(Session.GEAR.has(g), g + " is hangar gear too")


func test_a_node_needs_its_parent_and_the_money() -> void:
	check_eq(Upgrades.blocker("runner", "mole", {}, 99999), "Needs Bug sweeps first.", "parent first")
	check(Upgrades.blocker("runner", "bug_sweep", {}, 100).begins_with("Costs"), "and the money")
	check_eq(Upgrades.blocker("runner", "bug_sweep", {}, 3000), "", "then it can be bought")
	check_eq(Upgrades.blocker("runner", "bug_sweep", {"bug_sweep": true}, 3000), "Already have it.", "once")
	check_eq(UpgradeTree.depth("runner", "double_agent"), 2, "double agent sits two below bug sweeps")


func test_the_runner_pays_from_their_money() -> void:
	var s := _s()
	s.money = 5000
	check(s.command(Roles.PILOT, "upgrade", {"id": "bug_sweep"})[0], "bought")
	check_eq(s.money, 2000, "$3,000 gone")
	check(not s.command(Roles.PILOT, "upgrade", {"id": "mole"})[0], "the mole costs more than is left")
	check(not s.command(Roles.PILOT, "upgrade", {"id": "doppler"})[0], "a runner can't buy the task force's radar")
	s.dispose()


func test_the_task_force_pays_from_its_funds() -> void:
	var s := _s()
	var f0 := s.law_funds
	check(s.command(Roles.CONTROLLER, "upgrade", {"id": "doppler"})[0], "the desk buys Doppler")
	check_near(s.law_funds, f0 - 6000.0, 1.0, "out of the task force's funds")
	check_near(s.police.sensors.mti_min, SensorNet.MTI_MIN_MS * 0.5, 1e-9, "the MTI notch halves")
	for i in 30 * 60:
		s.update(1.0 / 30)
	check_near(s.law_funds, f0 - 6000.0 + 40.0, 1.0, "the budget pays $40 a minute")
	s.dispose()


func test_new_radar_sites() -> void:
	var s := _s({"upgrades": {"law": ["coastal_radar", "doppler", "aew"]}})
	check(s.police.sensors.site("CST") != null, "a coastal radar")
	var aew: SensorNet.RadarSite = s.police.sensors.site("AEW")
	check(aew != null and aew.range_m >= 60000.0, "and an AEW orbit with a long reach")
	s.apply_upgrades()
	check_eq(s.police.sensors.sites.filter(func(st): return st.code == "CST").size(), 1, "applying twice adds nothing")
	s.dispose()


func test_counter_surveillance_electronics() -> void:
	var s := _s({"upgrades": {"runner": ["scanner", "prog_scanner"]}})
	check_eq(s.scanner_channels, ["police", "police_tac"], "the programmable scanner hears the tactical channel")
	s.gear["detector"] = true
	s.spawn_airborne(World.airfield("HAR").x, World.airfield("HAR").y - 6000, 0, 600, 100)
	for i in 30 * 6:
		s.update(1.0 / 30)
	check(Snapshot.build(s, Roles.COPILOT).aircraft.painters.is_empty(), "a plain detector beeps, it doesn't say who")
	s.upgrades["runner"]["bearing_detector"] = true
	for i in 30 * 6:
		s.update(1.0 / 30)
	check(not Snapshot.build(s, Roles.COPILOT).aircraft.painters.is_empty(), "the DF detector names the site")
	s.dispose()


func test_paint_and_prop_shrink_how_far_you_are_seen() -> void:
	var s := _s()
	s.spawn_airborne(0, 0, 0, 600, 100)
	s.update(1.0 / 30)
	check_near(s.runner_signature().visual, 1.0, 1e-9, "bare aluminium")
	s.upgrades["runner"]["dark_paint"] = true
	check_near(s.runner_signature().visual, 0.8, 1e-9, "matte grey")
	s.upgrades["runner"]["quiet_prop"] = true
	check_near(s.runner_signature().visual, 0.7, 1e-9, "and a quiet prop")
	s.transponder = true
	s.upgrades["runner"]["spoofer"] = true
	check(s.runner_signature().spoofed, "the spoofer squawks someone else")
	s.dispose()


func test_the_mole_hears_orders_until_the_hunt_finds_him() -> void:
	var s := _s({"upgrades": {"runner": ["bug_sweep", "mole"]}})
	s.police.law_events.append("Hawk-1 launch, vector 180")
	s.update(1.0 / 30)
	check(s.messages.any(func(m): return m[1].begins_with("[mole]")), "the mole passes it on")
	s.law_funds = 10000.0
	check(s.command(Roles.CONTROLLER, "upgrade", {"id": "counter_mole"})[0], "mole hunt")
	check(not s.upgrades["runner"].has("mole"), "the mole is burned")
	check(s.messages.back()[1].contains("found and fired"), "and the runner hears about it")
	s.dispose()


func test_the_jammer_van() -> void:
	var s := _s()
	check(not s.command(Roles.CONTROLLER, "jam", {"x": 0.0, "y": 0.0})[0], "no van yet")
	s.upgrades["law"]["jammer"] = true
	check(s.command(Roles.CONTROLLER, "jam", {"x": 1000.0, "y": 2000.0})[0], "on station")
	var m := s.radio.transmit(s.time, "boat", "N1", "come to me", [1500.0, 2000.0, 300.0])
	check(m.jammed, "a call inside the zone is lost")
	check_eq(Snapshot.build(s, Roles.CONTROLLER).jammed.size(), 1, "the desk sees the zone")
	for i in 30 * 181:
		s.update(1.0 / 30)
	check(not s.radio.transmit(s.time, "boat", "N1", "come to me", [1500.0, 2000.0, 300.0]).jammed, "three minutes later it's gone")
	s.dispose()


func test_weaponry_and_interdiction_change_the_numbers() -> void:
	var s := _s({"upgrades": {"runner": ["armed_boat", "strip_guards"]}})
	check_near(s.maritime.seize_mult, 2.0, 1e-9, "an armed crew doubles the boarding time")
	check_near(s.police.raid_escape, 0.4, 1e-9, "guards turn 40% of raids away")
	s.upgrades["law"]["fast_cutter"] = true
	s.upgrades["law"]["armed_heli"] = true
	s.upgrades["law"]["blackhawk"] = true
	s.apply_upgrades()
	check_near(s.maritime.seize_mult, 2.0 / 1.3, 1e-9, "a fast patrol boat boards quicker")
	check_near(s.maritime.cutter_speed, 1.25, 1e-9, "and runs faster")
	check_near(s.police.heli_bust_mult, 1.3, 1e-9, "warning shots")
	check_near(s.police.heli_speed_mult, 1.3, 1e-9, "Blackhawks")
	s.dispose()


func test_espionage_on_a_hot_job() -> void:
	var s := _s({"upgrades": {"runner": ["bug_sweep", "mole", "double_agent"]}})
	var n0 := s.police.tips.size()
	var job = null
	for j in s.boards["HAR"]:
		if j.hot():
			job = j
			break
	if job == null:
		job = Jobs.airdrop_job(World.airfield("HAR"), Maritime.random_drop_point(s.world, s.rng, s.maritime.cove), s.rng, 2)
		s.boards["HAR"].append(job)
	s._spy_roll(job)
	check(s.police.tips.size() > n0, "the double agent plants a tip")
	check(not s.police.tips.back().text.contains(s.squawk), "and it doesn't name you")
	s.dispose()


func test_the_ai_chief_buys_the_cheapest_thing_it_can() -> void:
	check_eq(Upgrades.ai_pick({}, 3500), "encryption", "$3,000 encryption first")
	check_eq(Upgrades.ai_pick({}, 100), "", "nothing when broke")
	var s := _s({"ai_law_upgrades": true})
	s.law_funds = 20000.0
	for i in 30 * 100:
		s.update(1.0 / 30)
	check(s.upgrades["law"].has("encryption"), "the AI chief shops: %s" % [s.upgrades["law"].keys()])
	s.dispose()
	var q := _s()
	q.law_funds = 20000.0
	for i in 30 * 100:
		q.update(1.0 / 30)
	check(q.upgrades["law"].is_empty(), "but not unless asked (sims and replays)")
	q.dispose()


func test_upgrades_survive_a_save() -> void:
	var path := "user://test_upgrades_save.json"
	var s := _s({"save_path": path})
	s.upgrades["runner"]["lookouts"] = true
	s.save()
	s.dispose()
	var t := Session.load_or_new(path, {"features": Session.SANDBOX_FEATURES})
	check(t.upgrades["runner"].has("lookouts"), "lookouts are still on the payroll")
	t.dispose()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_the_tree_widget_shows_state() -> void:
	var t := UpgradeTree.new().setup("runner")
	t.update({"bug_sweep": true}, 2500)
	var rows := {}
	for i in t.ids.size():
		if t.ids[i] != "":
			rows[t.ids[i]] = t.table.cell(i, 2)
	check_eq(rows["bug_sweep"], "OWNED", "owned")
	check_eq(rows["scanner"], "buy", "affordable")
	check(rows["mole"].begins_with("Costs"), "too dear: " + rows["mole"])
	check(rows["double_agent"].begins_with("Needs"), "locked: " + rows["double_agent"])
	var got := []
	t.buy.connect(func(id): got.append(id))
	t.table.select(t.ids.find("scanner"))
	t.activate()
	check_eq(got, ["scanner"], "ENTER buys the selected node")
	t.free()
