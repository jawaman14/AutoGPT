extends TestCase
## The optional tutorial: lessons finish when you do the thing; a system's
## lesson waits until the system is in the game; tips come once; F10 skips,
## off hides it; progress rides in the save.


func after_each() -> void:
	World.use_map(0)


func _sess(opts := {}) -> Session:
	var o := {"seed": 4, "map_seed": MapCity.SEED, "location": "HAR", "features": Session.SANDBOX_FEATURES}
	o.merge(opts, true)
	var s := Session.new(o)
	s.police.frozen = true
	Tutorial.new().attach(s)
	return s


func _ids(s: Session) -> String:
	var c = s.tutorial.current()
	return c[0] if c != null else ""


func test_the_basics_follow_what_you_do() -> void:
	var s := _sess()
	check_eq(_ids(s), "welcome")
	s.time += 13.0
	s.tutorial.tick(s)
	check_eq(_ids(s), "jobs", "the welcome goes by itself")
	s.refresh_board("HAR")
	var j = Py.first(s.boards["HAR"], func(x): return not x.hot())
	check(s.accept_job(j) == null, "took a legal job")
	check_eq(_ids(s), "load", "taking a job finishes 'find work'")
	s.tutorial.note("menu_l")
	s.tutorial.tick(s)
	check_eq(_ids(s), "takeoff")
	s.bus.emit("job_delivered", s.time, "", ["runner"], {"job_id": j.id, "pay": 100, "hot": false})
	check(s.tutorial.done.has("deliver"), "a delivery counts even out of order")
	s.dispose()


func test_a_systems_lesson_waits_for_its_system() -> void:
	var s := _sess({"trade": true})
	for id in ["welcome", "jobs", "load", "takeoff", "deliver", "transponder", "grass"]:
		s.tutorial.done[id] = true
	check_eq(_ids(s), "buyers", "no payroll or logistics yet: their lessons wait")
	s.enable_system("payroll")
	check_eq(_ids(s), "dealer", "the hiring hall opens: its lesson is next")
	var p: Array = s.tutorial.progress()
	check(p[1] >= 8, "the count grows with the game (%d)" % p[1])
	s.dispose()


func test_tips_come_once() -> void:
	var s := _sess()
	s.police.case("runner").wanted = 1
	s.tutorial.tick(s)
	check(s.tutorial.view().tip.begins_with("You're WANTED"), "the wanted tip")
	var n := s.messages.filter(func(m): return "TIP" in str(m[1])).size()
	s.tutorial.tick(s)
	s.tutorial.tick(s)
	check_eq(s.messages.filter(func(m): return "TIP" in str(m[1])).size(), n, "once")
	s.time += 30.0
	s.tutorial.tick(s)
	check_eq(s.tutorial.view().tip, "", "and it fades")
	s.dispose()


func test_skip_and_off() -> void:
	var s := _sess()
	s.tutorial.skip()
	check_eq(_ids(s), "jobs", "F10 skips")
	s.tutorial.set_enabled(false)
	check(s.tutorial.current() == null, "off: nothing on screen")
	s.police.case("runner").wanted = 1
	s.tutorial.tick(s)
	check_eq(s.tutorial.view().tip, "", "and no tips")
	s.dispose()


func test_progress_is_saved() -> void:
	var s := _sess()
	s.tutorial.done["jobs"] = true
	s.tutorial.tips_shown["fog"] = true
	var t := Tutorial.new(s.tutorial.to_dict())
	check(t.done.has("jobs") and t.tips_shown.has("fog") and t.enabled, "round trip")
	s.save_path = "user://test_tutorial_save.json"
	s.save()
	check(Session.read_save(s.save_path).has("tutorial"), "in the save file")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(s.save_path))
	s.dispose()


func test_every_lesson_can_finish() -> void:
	# each lesson id is completed somewhere (an event, a note or the state)
	var src := FileAccess.get_file_as_string("res://scripts/sim/tutorial.gd")
	for l in Tutorial.LESSONS:
		check(src.count('complete("%s")' % l[0]) >= 1, "a way to finish '%s'" % l[0])


func test_the_desks_learn_by_doing() -> void:
	var s := _sess()
	check_eq(s.tutorial.desk_view(Roles.CONTROLLER).id, "c_launch", "the controller starts with launching")
	var r: Array = s.command(Roles.CONTROLLER, "launch", {"kind": "heli"})
	if r[0]:
		check_eq(s.tutorial.desk_view(Roles.CONTROLLER).id, "c_raid", "a launch finishes the lesson")
	else:
		s.tutorial.command_done(Roles.CONTROLLER, "launch")  # no heli free on this map: the hook alone
		check_eq(s.tutorial.desk_view(Roles.CONTROLLER).id, "c_raid")
	check_eq(s.tutorial.desk_view(Roles.PILOT).id, "", "the pilot has no desk lessons")
	check_eq(_ids(s), "welcome", "and the pilot's own lessons are untouched")
	s.dispose()


func test_a_remote_desk_skips_through_the_link() -> void:
	var s := _sess()
	var link := LocalLink.new(s, Roles.BOSS)
	var snap = link.snapshot()
	check(snap is Dictionary and snap.tutorial.id == "b_orders", "the boss's desk shows its lesson")
	link.send_command("tutorial", {"do": "skip"})
	check_eq(s.tutorial.desk_view(Roles.BOSS).id, "", "skipped (the rest need systems not in this game)")
	link.send_command("tutorial", {"do": "off"})
	check(not s.tutorial.enabled, "SHIFT+F10 from a desk turns it off for the game")
	s.dispose()


func test_desk_progress_is_saved() -> void:
	var s := _sess()
	s.tutorial.command_done(Roles.LIEUTENANT, "squad_order")
	var t := Tutorial.new(s.tutorial.to_dict())
	check(t.desk_done.get(Roles.LIEUTENANT, {}).has("l_squads"), "round trip")
	s.dispose()
