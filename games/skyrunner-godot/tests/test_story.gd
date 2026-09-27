extends TestCase
## The story (Costa Brava 1979-1989): chapters open the game's systems and locks
## one at a time; the open mode has all of them from the start.


func after_each() -> void:
	World.use_map(0)


func _story(index := 0) -> Session:
	var s := Session.new({"seed": 5, "map_seed": MapCity.SEED, "fog": true, "career": true})
	Story.new(index).attach(s)
	return s


func _open_session() -> Session:
	var o := {"seed": 5, "map_seed": MapCity.SEED}
	for k in Session.SYSTEMS:
		o[k] = true
	o["trade"] = true
	return Session.new(o)


func test_1979_is_grass_and_corners() -> void:
	var s := _story()
	check(s.trade != null and s.payroll != null and s.chronicle != null, "the trade, the hiring hall and the papers")
	check(not s.trade.connected, "no cocaine until the connection calls")
	for sys in [s.logistics, s.ground, s.family, s.agency, s.island, s.court]:
		check(sys == null, "the rest waits for its chapter")
	check(not s.unlocked("guns"), "no guns yet")
	check(s.unlocked("role_driver"), "roles nobody locks are open")
	check_eq(s.command(Roles.PILOT, "buy_weapons", {"tier": "rifle", "n": 1})[1], "No gun dealer will talk to us yet.")
	for w in s.payroll.candidates["org"]:
		check(not (w.role in ["soldier", "mule"]), "no soldiers or mules in the hall (%s)" % w.role)
	for af in s.world.airfields:
		if af.kind in ["shady", "bush"]:
			s.refresh_board(af.code)
			for j in s.boards[af.code]:
				check(j.weapons.is_empty(), "no gun runs on the boards")
	check(s.narrative == s.story, "the HUD shows the story's chapter")
	check_eq(s.story.chapter.year, 1979)
	s.dispose()


func test_the_goals_count_what_happens() -> void:
	var s := _story()
	for i in 2:
		s.bus.emit("job_delivered", s.time, "", ["runner"], {"job_id": "J", "pay": 0, "dest": "X", "hot": true, "good": "marijuana", "lb": 150.0})
	s.story.tick(s)
	check_near(s.story.progress["weed_lb"], 300.0, 0.01, "300 lb of grass counted")
	check(s.story.index == 0, "but no dealer yet, no money: still 1979")
	s.trade.earned = 5000
	s.story.tick(s)
	check_eq(s.story.index, 0, "still needs a dealer on a corner")
	s.dispose()


func test_chapters_open_the_game_in_order() -> void:
	var s := _story()
	s.trade.stock.marijuana = 250.0  # grass held the 1979 way: one pool
	s.story.advance()
	check_eq(s.story.chapter.title, "The Connection")
	check(s.ground == null, "1980: still no war")
	check(s.logistics != null, "1980: logistics - product and cash have places now")
	check_near(s.logistics.total("marijuana"), 250.0, 0.01, "what we held is in a stash")
	s.story.advance()
	check(s.trade.connected, "1981: the Colombians have called")
	check(s.ground != null and s.foot != null, "Los Cuervos and the street war")
	check(s.unlocked("guns") and s.unlocked("role_soldier"), "guns and soldiers")
	check(not s.unlocked("role_mule"), "mules wait for the island")
	s.story.advance()
	check(s.family != null, "1982: the Morettis")
	s.story.advance()
	check(s.court != null, "1983: the federal court")
	s.story.advance()
	check(s.island != null and s.unlocked("role_mule"), "1984: Isla Soberana, and mules")
	check_eq(s.police.territory_y, Island.TERRITORY_Y, "the task force stops at the island's line")
	check(s.agency == null, "no Company yet")
	s.story.advance()
	check(s.agency != null and s.agency.prng != null, "1985: the Company and its pipeline")
	s.story.advance()
	check_eq(s.story.chapter.title, "Kingpin")
	s.money = 300000
	s.story.tick(s)
	check(s.story.completed_all, "a quarter of a million: the end")
	for k in Story.LOCKS:
		check(s.unlocked(k), k + " open after the end")
	s.dispose()


func test_the_war_can_arrive_mid_game() -> void:
	var s := _story(1)
	for i in 120:
		s.update(1.0, ControlMapper.InputFrame.new(), null)
	s.story.advance()
	for i in 120:
		s.update(1.0, ControlMapper.InputFrame.new(), null)
	check(s.ground.squads.size() > 0, "squads on the streets once the war opens (%d)" % s.ground.squads.size())
	s.dispose()


func test_a_saved_story_rebuilds_its_chapters() -> void:
	var d := {"index": 5, "progress": {"island_runs": 1.0}, "done": false}
	var s := Session.new({"seed": 5, "map_seed": MapCity.SEED, "career": true})
	var st := Story.from_dict(d)
	st.attach(s)
	check_eq(st.chapter.title, "Isla Soberana")
	check_near(st.progress["island_runs"], 1.0, 0.01, "progress kept")
	check(s.trade.connected, "the connection stays made")
	for sys in [s.trade, s.logistics, s.payroll, s.ground, s.family, s.court, s.island]:
		check(sys != null, "chapters 1-6 built")
	check(s.agency == null, "chapter 7 not yet")
	check_eq(Story.from_dict(st.to_dict()).index, 5, "round trip")
	s.dispose()


func test_open_mode_has_everything() -> void:
	var s := _open_session()
	check(s.story == null, "no story")
	for sys in [s.trade, s.payroll, s.ground, s.family, s.court, s.agency, s.island, s.chronicle]:
		check(sys != null, "every system from the first minute")
	for k in Story.LOCKS:
		check(s.unlocked(k), k)
	check(s.trade.connected, "cocaine from the start (no career)")
	s.dispose()


func test_the_chapter_list() -> void:
	check_eq(Story.CHAPTERS.size(), 8)
	var years := Story.CHAPTERS.map(func(c): return c[0])
	var sorted := years.duplicate()
	sorted.sort()
	check_eq(years, sorted, "in date order")
	var opened := Story.opens_through(8)
	for k in Session.SYSTEMS:
		check(k in opened, "chapter by chapter, every system opens: " + k)
	for k in Story.LOCKS:
		check(k in opened, "and every lock: " + k)


func test_no_softlocks_when_a_faction_is_gone() -> void:
	var s := _story(3)
	check_eq(s.story.chapter.title, "Family Business")
	s.family.gone = true
	s.money = 70000
	s.story.tick(s)
	check_eq(s.story.chapter.title, "The Task Force", "the Morettis convicted first: the chapter still ends")
	s.story.advance()
	s.story.advance()
	check_eq(s.story.chapter.title, "The Company")
	s.agency.hung_out = true
	s.story.tick(s)
	check_eq(s.story.chapter.title, "Kingpin", "the Company cut us loose: on to the end")
	s.dispose()
