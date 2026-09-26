extends TestCase
## On foot with a gun: FootCombat's rules (the armoury, the magazine, hits,
## squads shooting back, going down, arrests), Gunplay's aim (ray against the
## drawn men), and a walk out of the aircraft with a rifle.


func after_each() -> void:
	World.use_map(0)


func _sess(seed := 3) -> Session:
	var s := Session.new({"seed": seed, "map_seed": MapCity.SEED, "location": "HAR",
		"features": Session.SANDBOX_FEATURES, "ground_war": true})
	s.police.frozen = true
	s.ground._started = true
	for f in s.ground.commanders:
		s.ground.commanders[f].ai = false
	s.update(1.0 / 30)
	return s


func _squad(s: Session, f: String, at: Vector2, loadout: Dictionary) -> GroundWar.Squad:
	var q = s.ground.recruit(f, "foot", at, false)
	s.ground.arsenal(f).give_back(q.loadout)
	q.loadout = loadout
	var n := 0
	for t in loadout:
		n += int(loadout[t])
	q.men = n
	q.men0 = n
	q.state = "holding"
	return q


func test_draw_fire_reload_holster() -> void:
	var s := _sess()
	var f := s.foot
	var ars: Arsenal = s.arsenals.org
	var r0: int = ars.stock.rifle
	f.enter(0, 0)
	check_eq(f.draw("rifle"), "", "a rifle from the armoury")
	check_eq(ars.stock.rifle, r0 - 1, "one fewer on the rack")
	check_eq(f.mag, 30, "a full magazine")
	for i in 30:
		check(f.fire(), "bang")
	check(not f.fire(), "click: empty")
	check(f.reload(), "reload")
	check_eq(f.mag, 30, "full again")
	check(f.draw("rpg") != "", "no RPGs in the armoury")
	f.leave()
	check_eq(ars.stock.rifle, r0, "the rifle's back on the rack")
	check_eq(f.tier, "", "empty-handed")
	s.dispose()


func test_hits_drop_men_and_have_consequences() -> void:
	var s := _sess()
	var f := s.foot
	f.enter(0, 0)
	f.draw("rifle")
	var cop := _squad(s, "police", Vector2(80, 0), {"pistol": 3})
	var c = s.police.case("runner")
	check_eq(f.hit(cop.id, 80.0), "hit", "one rifle round: wounded")
	check_eq(f.hit(cop.id, 80.0), "down", "two: down")
	check_eq(cop.men, 2, "a man down")
	check_eq(s.ground.officers_down, 1, "an officer down")
	check(c.suspicion >= 20.0, "and the task force knows who did it")
	check(f.hostile(cop), "they're shooting back now")
	check_eq(f.hit(cop.id, 900.0), "", "out of rifle range: doesn't count")
	var p0: int = s.arsenals.org.stock.pistol
	f.hit(cop.id, 80.0)
	f.hit(cop.id, 80.0)
	check_eq(s.arsenals.org.stock.pistol, p0 + 1, "you pick his pistol up")
	s.dispose()


func test_hostile_squads_shoot_back_and_you_go_down() -> void:
	var s := _sess()
	var f := s.foot
	f.enter(0, 0)
	f.draw("pistol")
	var riv := _squad(s, "rival", Vector2(40, 0), {"rifle": 4})
	f.shot_rival_t = s.time  # you started it
	var m0 := s.money
	for i in 600:
		f.update(0.5)
		if f.down != "":
			break
	check(f.hits_taken > 0, "they hit you")
	check_eq(f.down, "hospital", "no police around: you wake up by the aircraft")
	check(s.money < m0, "a doctor's bill")
	check_eq(f.tier, "", "and the gun is gone")
	check(riv.men == 4, "")
	s.dispose()


func test_a_downed_man_with_police_near_is_arrested() -> void:
	var s := _sess()
	var f := s.foot
	f.enter(0, 0)
	f.draw("pistol")
	var cop := _squad(s, "police", Vector2(60, 0), {"rifle": 4})
	f.shot_police_t = s.time
	for i in 600:
		f.update(0.5)
		if f.down != "":
			break
	check_eq(f.down, "arrested", "shot and arrested")
	check_eq(s.phase, "busted", "the bust")
	s.dispose()


func test_a_patrol_arrests_a_wanted_man_who_keeps_his_hands_down() -> void:
	var s := _sess()
	var f := s.foot
	f.enter(0, 0)
	s.police.case("runner").wanted = true
	_squad(s, "police", Vector2(25, 0), {"pistol": 2})
	f.update(2.1)
	check_eq(f.down, "arrested", "hands up")
	check_eq(s.phase, "busted", "busted on foot")
	s.dispose()


func test_friendly_soldiers_never_shoot_you() -> void:
	var s := _sess()
	var f := s.foot
	f.enter(0, 0)
	var ours := _squad(s, "org", Vector2(20, 0), {"rifle": 4})
	check(not f.hostile(ours), "our own")
	for i in 60:
		f.update(0.5)
	check_eq(f.hits_taken, 0, "untouched")
	s.dispose()


# ------------------------------------------------------------------ aiming
func test_ray_capsule() -> void:
	var t := Gunplay._ray_capsule(Vector3(0, 1, 0), Vector3(0, 0, -1), Vector3(0, 0.3, -20), Vector3(0, 1.75, -20), 0.32)
	check_near(t, 20.0, 0.4, "straight at him: ~20 m")
	check_eq(Gunplay._ray_capsule(Vector3(0, 1, 0), Vector3(0, 0, -1), Vector3(2, 0.3, -20), Vector3(2, 1.75, -20), 0.32), -1.0, "2 m wide: a miss")
	check_eq(Gunplay._ray_capsule(Vector3(0, 1, 0), Vector3(0, 0, 1), Vector3(0, 0.3, -20), Vector3(0, 1.75, -20), 0.32), -1.0, "behind you: a miss")


func test_aim_takes_the_nearest_man_drawn() -> void:
	var s := _sess()
	var near := _squad(s, "rival", Vector2(-1640, -10660), {"rifle": 2})
	var far := _squad(s, "police", Vector2(-1640, -10600), {"rifle": 2})
	var r := SquadRender.new()
	r.setup(s.world, "medium")
	Engine.get_main_loop().root.add_child(r)
	r.sync(s.ground.squads.map(func(q): return q.dict()), [], Vector3(-1640, 10, 10700), s.time, 0.1)
	var g := Gunplay.new()
	g.squads = r
	var man: Vector3 = r.men_pts.filter(func(m): return m[0] == near.id)[0][1]
	var eye := Vector3(man.x, man.y + 1.5, man.z + 30.0)
	var hit := g.aim(eye, (man + Vector3(0, 1.2, 0) - eye).normalized(), 300.0)
	check_eq(hit[0], near.id, "the man in front")
	check_near(hit[1], 30.0, 1.5, "30 m off")
	check(far.id != hit[0], "not the one behind him")
	g.free()
	r.free()
	s.dispose()


func test_walk_out_with_a_rifle_and_shoot() -> void:
	var s := _sess()
	var app := PilotApp.new()
	Engine.get_main_loop().root.add_child(app)
	app.setup(s, "low")
	app._process(1.0 / 30)
	app._toggle_on_foot()
	check(app.on_foot and app.gun != null, "on foot, with a gun hand")
	check(s.foot.active, "the session knows you're out")
	check(app.gun.key("2"), "2: the rifle")
	check_eq(s.foot.tier, "rifle", "drawn")
	var target := _squad(s, "rival", Vector2(app.walker.game_xy()[0], app.walker.game_xy()[1]) + Vector2(0, 40), {"pistol": 2})
	app._sync_squads(0.1)
	# aim straight at the nearest drawn man
	var man: Vector3 = app.squads.men_pts.filter(func(m): return m[0] == target.id)[0][1]
	app.walker.look_at(Vector3(man.x, app.walker.global_position.y, man.z), Vector3.UP)
	app.walker.cam.look_at(man + Vector3(0, 1.2, 0), Vector3.UP)
	var res := app.gun.trigger()
	check(res in ["hit", "down", "miss"], "a shot: %s" % res)
	check_eq(s.foot.mag, 29, "one round gone")
	app._toggle_on_foot()  # climb back in (still next to the aircraft)
	check(not app.on_foot and app.gun == null, "back in the aircraft")
	check(not s.foot.active, "and off your feet")
	app.free()
	s.dispose()
