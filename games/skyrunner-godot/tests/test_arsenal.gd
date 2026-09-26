extends TestCase
## Arsenals and gun running: gun runs to sell or to stock, the fence and the
## dealer, and every seizure arming the police.


func after_each() -> void:
	World.use_map(0)


func _city(opts := {}) -> Session:
	var o := {"seed": 4, "map_seed": MapCity.SEED, "location": "QRY", "features": Session.SANDBOX_FEATURES}
	o.merge(opts, true)
	var s := Session.new(o)
	s.update(1.0 / 30)
	s.police.frozen = true
	return s


func _gun_job(s: Session, stash := "") -> Jobs.Job:
	for i in 40:
		var j = Arsenal.gun_run(World.airfield("QRY"), s.world.airfields, s.stash_net, s.arng)
		if j != null and (stash == "") == (j.stash == ""):
			return j
	return null


func test_issue_best_first_and_power() -> void:
	var a := Arsenal.new("x", false)
	a.add("pistol", 5)
	a.add("rifle", 2)
	a.add("mg", 1)
	var l := a.issue(6)
	check_eq(l, {"mg": 1, "rifle": 2, "pistol": 3}, "the best weapons go out first")
	check_eq(a.count(), 2, "two pistols left")
	check(Arsenal.power(l, 6) > Arsenal.power({"pistol": 6}, 6) * 1.5, "machine guns and rifles outgun pistols")
	check_near(Arsenal.power({}, 4), Arsenal.UNARMED_FIRE, 1e-9, "unarmed men still count a little")
	a.give_back(l)
	check_eq(a.count(), 8, "and it all comes back")
	var d := Arsenal.from_dict(a.to_dict())
	check_eq(d.stock, a.stock, "round trip")


func test_everyone_starts_armed_the_police_best() -> void:
	var s := _city()
	check(s.arsenals.org.count() > 0 and s.arsenals.rival.count() > 0, "the gangs have guns")
	check(s.arsenals.law.count() > s.arsenals.org.count(), "the task force has more")
	s.dispose()


func test_gun_runs_on_the_board() -> void:
	var s := _city()
	var found := false
	for i in 12:
		s.refresh_board("QRY")
		if s.boards["QRY"].any(func(j): return not j.weapons.is_empty()):
			found = true
			break
	check(found, "gun runs are offered at the shady strips")
	var j := _gun_job(s)
	check(j != null and j.hot() and Economy.good_of(j) == "guns", "weapons crates are hot and priced as guns")
	check(j.items.size() >= 1 and j.payout > 0, "crates and a price")
	s.dispose()


func test_sell_pays_stock_arms_the_organisation() -> void:
	var s := _city()
	var j := _gun_job(s)
	var dest := World.airfield(j.dest)
	s.active_jobs.append(j)
	var m0 := s.money
	var c0: int = s.arsenals.org.count()
	s._complete_delivery(j, dest)
	check(s.money > m0, "sold: paid")
	check_eq(s.arsenals.org.count(), c0, "and the guns are gone")
	var k := _gun_job(s)
	s.active_jobs.append(k)
	check(s.command(Roles.PILOT, "gun_mode", {"job_id": k.id, "mode": "stock"})[0], "the pilot keeps this one")
	var m1 := s.money
	s._complete_delivery(k, World.airfield(k.dest))
	check_eq(s.money, m1, "stocked: no pay")
	var n := 0
	for t in k.weapons:
		n += int(k.weapons[t])
	check_eq(s.arsenals.org.count(), c0 + n, "the weapons are in the armoury")
	s.dispose()


func test_a_stocked_truck_leaves_the_guns_at_the_stash_and_a_raid_takes_them() -> void:
	var s := _city()
	var j := _gun_job(s, "x")
	check(j != null and j.stash != "", "a gun run to a stash")
	j.gun_mode = "stock"
	s.active_jobs.append(j)
	s._truck_out(j, World.airfield(j.dest))
	for t in s.stash_net.trucks:
		t.stop_at = -1.0
	for i in 60 * 60:  # up to half an hour on the road
		s.update(0.5)
		if s.stash_net.trucks.is_empty():
			break
	check(s.stash_net.trucks.is_empty(), "the truck got in")
	check_eq(s.arsenals.org.cache, j.stash, "the armoury is at that stash now")
	var law0: int = s.arsenals.law.count()
	var org_n: int = s.arsenals.org.count()
	s.stash_net.get_stash(j.stash).heat = 80.0
	check(s._raid(j.stash) == null, "the task force raids it")
	check_eq(s.arsenals.org.count(), 0, "the armoury is gone")
	check_eq(s.arsenals.law.count(), law0 + org_n, "into the police arsenal")
	check(s.law_log.any(func(m): return "issued to the patrols" in m[1]), "the desk hears it")
	s.dispose()


func test_seized_trucks_and_busts_arm_the_police() -> void:
	var s := _city()
	var j := _gun_job(s, "x")
	s.active_jobs.append(j)
	s._truck_out(j, World.airfield(j.dest))
	s.stash_net.trucks[0].stop_at = 0.0
	var law0: int = s.arsenals.law.count()
	s.update(1.0)
	var n := 0
	for t in j.weapons:
		n += int(j.weapons[t])
	check_eq(s.arsenals.law.count(), law0 + n, "the stopped truck's guns go to the police")
	check(s.econ.scarcity["guns"] > 0.0, "and guns get scarce on the street")
	# a bust with unmarked crates on board
	var r := PyRandom.new()
	r.seed(1)
	var jid := Jobs.new_id()
	var crate := Jobs.Job.new(jid, "crates", "contraband", "QRY", "FRM",
		[Jobs.item("Unmarked crate", "cargo", 40, jid, {"hot": true}), Jobs.item("Unmarked crate", "cargo", 40, jid, {"hot": true})], 3000)
	s.active_jobs.append(crate)
	var law1: int = s.arsenals.law.count()
	s._bust("test")
	check_eq(s.arsenals.law.count(), law1 + 4, "two unmarked crates: four rifles seized")
	s.dispose()


func test_the_fence_and_the_dealer() -> void:
	var s := _city()
	s.money = 20000
	check(s.command(Roles.BOSS, "buy_weapons", {"tier": "mg", "n": 1})[0], "the boss buys a machine gun")
	check(s.money < 20000 - 3500, "at a mark-up")
	var m := s.money
	check(s.command(Roles.BOSS, "sell_weapons", {"tier": "mg", "n": 1})[0], "and sells it back")
	check(s.money - m < 20000 - m, "at the fence's cut")
	check(not s.command(Roles.BOSS, "sell_weapons", {"tier": "rpg", "n": 1})[0], "can't sell what you haven't got")
	check(not s.command(Roles.CONTROLLER, "buy_weapons", {"tier": "rifle"})[0], "the desk doesn't shop for guns")
	s.dispose()


func test_the_armoury_is_saved() -> void:
	var path := OS.get_user_data_dir().path_join("test_arsenal_save.json")
	var s := _city({"save_path": path})
	s.arsenals.org.add("rpg", 2)
	s.save()
	s.dispose()
	var t := Session.load_or_new(path, {"features": Session.SANDBOX_FEATURES})
	check_eq(int(t.arsenals.org.stock.rpg), 2, "the RPGs are still there")
	t.dispose()
	DirAccess.remove_absolute(path)


func test_snapshots_show_each_side_its_own() -> void:
	var s := _city()
	check(Snapshot.build(s, Roles.COPILOT).arsenal.side == "org", "the crew sees the organisation's")
	check(Snapshot.build(s, Roles.CONTROLLER).arsenal.side == "law", "the desk sees the task force's")
	s.dispose()


func test_off_means_no_guns() -> void:
	Arsenal.REALISM = false
	var s := _city()
	check(s.arsenals.is_empty(), "no arsenals")
	for i in 6:
		s.refresh_board("QRY")
		check(not s.boards["QRY"].any(func(j): return not j.weapons.is_empty()), "no gun runs")
	s.dispose()
	Arsenal.REALISM = true
