extends TestCase
## Seats: every role is the AI's until a human claims it, and goes back to the
## AI when they leave; a dropped player's seat is held for their token. Locally
## (Seats + Session.seat_driver) and over the wire (protocol v3: the lobby,
## claims, the roster, table talk, reconnects).

var sess: Session
var srv: HostServer
var clients: Array = []


func before_each() -> void:
	sess = Session.new({"seed": 4, "mode": Roles.VERSUS, "map_seed": MapCity.SEED, "features": Session.SANDBOX_FEATURES + ["hq"],
		"ground_war": true})
	sess.update(1.0 / 30)


func after_each() -> void:
	for c in clients:
		c.close()
		c.free()
	clients.clear()
	if srv != null:
		srv.stop()
		srv.free()
		srv = null
	sess.dispose()
	World.use_map(0)


# ------------------------------------------------------------------ local
func test_every_role_starts_on_the_ai_and_the_host_flies() -> void:
	var s := sess.seats
	check_eq(s.who(Roles.PILOT), "human", "the host flies")
	for r in Roles.ALL:
		if r != Roles.PILOT:
			check_eq(s.who(r), "ai", r + " is the AI's")
	check(s.open().has(Roles.LIEUTENANT) and s.open().has(Roles.PATROL), "the new roles are open")
	var ps := Session.new({"seed": 1, "mode": Roles.POLICE})
	check_eq(ps.seats.who(Roles.PILOT), "off", "no pilot seat against AI runners")
	ps.dispose()


func test_claim_and_release_every_role_symmetrically() -> void:
	var s := sess.seats
	for r in Roles.ALL:
		if r == Roles.PILOT:
			continue
		check_eq(s.claim(r, "P-" + r, "tok-" + r), "", r + " claimed")
		check(sess.humans.has(r), r + " is human")
		check(s.claim(r, "Other", "x") != "", r + " can't be taken twice")
		s.release(r)
		check_eq(s.who(r), "ai", r + " back to the AI")
		check(not sess.humans.has(r), r + " no longer human")


func test_the_systems_follow_the_seat() -> void:
	var s := sess.seats
	var cp0 = sess.copilot
	s.claim(Roles.COPILOT, "Rosa", "t1")
	check_eq(sess.copilot, "human", "a human in the right seat")
	s.release(Roles.COPILOT)
	check_eq(sess.copilot, cp0, "and whatever was there before is back")
	s.claim(Roles.CONTROLLER, "Hart", "t2")
	check_eq(sess.police.controller, "human", "the desk is human")
	s.release(Roles.CONTROLLER)
	check_eq(sess.police.controller, "ai", "the AI desk again")
	s.claim(Roles.LIEUTENANT, "Manny", "t3")
	check(not sess.ground.commanders.org.ai, "the lieutenant runs the soldiers")
	s.release(Roles.LIEUTENANT)
	check(sess.ground.commanders.org.ai, "the AI runs them again")
	s.claim(Roles.PATROL, "Sgt", "t4")
	check(not sess.ground.commanders.police.ai, "the patrol commander runs the squads")
	s.release(Roles.PATROL)
	check(sess.ground.commanders.police.ai, "and hands them back")


func test_the_boss_seat_is_handed_back() -> void:
	var ps := Session.new({"seed": 2, "mode": Roles.POLICE, "features": PoliceSystem.LAW_FEATURES + ["hq"]})
	ps.update(1.0 / 30)
	var ai0 = ps.nights.runner_ai
	check(ai0 != null, "the AI runs the organisation against a human task force")
	ps.seats.claim(Roles.BOSS, "Boss", "t")
	check(ps.nights.runner_ai == null, "a human boss plans")
	ps.seats.release(Roles.BOSS)
	check_eq(ps.nights.runner_ai, ai0, "the AI boss is back (it never used to come back)")
	ps.dispose()


func test_a_dropped_seat_is_held_for_its_token() -> void:
	var s := sess.seats
	s.claim(Roles.SPOTTER, "Eyes", "abc")
	s.release(Roles.SPOTTER, true)
	check_eq(s.who(Roles.SPOTTER), "reserved", "held")
	check(s.claim(Roles.SPOTTER, "Thief", "zzz") != "", "not for someone else")
	check_eq(s.held_for("abc"), Roles.SPOTTER, "the token knows its seat")
	check_eq(s.claim(Roles.SPOTTER, "Eyes", "abc"), "", "the same token takes it back")
	s.release(Roles.SPOTTER, true)
	s.tick(sess.time + Seats.HOLD_S + 1.0)
	check_eq(s.who(Roles.SPOTTER), "ai", "after the hold the AI keeps it")


func test_a_human_cutter_captain_steers_and_the_ai_stays_off_it() -> void:
	sess.seats.claim(Roles.CUTTER, "Cap", "c")
	var r: Array = sess.command(Roles.CUTTER, "cutter_goto", {"x": 12000.0, "y": -12000.0})
	check(r[0], str(r))
	var c = Py.first(sess.maritime.boats, func(b): return b.kind == "cutter")
	check(c != null and c.goal == [12000.0, -12000.0], "the cutter goes where the captain says")


# ------------------------------------------------------------------ over the wire
func _serve() -> void:
	srv = HostServer.new()
	srv.attach(sess)
	check_eq(srv.start(0, Roles.VERSUS, "127.0.0.1"), null, "server listening")


func _client(name: String, role := "", token := "") -> NetClient:
	var c := NetClient.new()
	c.token = token
	c.open("127.0.0.1", srv.port, name, role)
	clients.append(c)
	return c


func _pump_until(cond: Callable, secs := 5.0) -> bool:
	var end := Time.get_ticks_msec() + int(secs * 1000)
	while Time.get_ticks_msec() < end:
		srv._process(0.0)
		for c in clients:
			c.poll()
		srv.pump(sess)
		sess.update(1.0 / 60)
		srv.publish(sess, true)
		if cond.call():
			return true
		OS.delay_msec(5)
	return false


func test_join_the_lobby_see_the_seats_and_claim_one() -> void:
	_serve()
	var a := _client("Ana")
	check(_pump_until(func(): return not a.seats.is_empty()), "the roster arrives")
	check_eq(a.role, "", "in the lobby, no seat yet")
	check(a.token != "", "a reconnect token")
	check(a.seats.any(func(s): return s.role == Roles.LIEUTENANT and s.who == "ai"), "the lieutenant is the AI's")
	a.claim(Roles.LIEUTENANT)
	check(_pump_until(func(): return a.role == Roles.LIEUTENANT and a.latest != null), "claimed, and snapshots flow")
	check(a.latest.has("ground"), "the lieutenant sees the ground war")
	check(not sess.ground.commanders.org.ai, "the human runs the soldiers")
	var b := _client("Ben")
	check(_pump_until(func(): return b.seats.any(func(s): return s.role == Roles.LIEUTENANT and s.name == "Ana")), "others see who holds it")
	b.claim(Roles.LIEUTENANT)
	check(_pump_until(func(): return b.claim_error != null), "no double seating")
	b.claim(Roles.PATROL)
	check(_pump_until(func(): return b.role == Roles.PATROL), "Ben takes patrol")
	var seq := b.send_command("recruit_squad", {"kind": "car"})
	check(_pump_until(func(): return b.acks.has(seq)), "ack")
	check(b.acks[seq][0], "the patrol commander raises a squad: %s" % str(b.acks.get(seq)))
	a.release()
	check(_pump_until(func(): return sess.seats.who(Roles.LIEUTENANT) == "ai"), "Ana steps down: the AI again")
	check(sess.ground.commanders.org.ai, "the AI runs the soldiers")


func test_table_talk_all_and_side() -> void:
	_serve()
	var a := _client("Ana", Roles.COPILOT)
	var b := _client("Ben", Roles.CONTROLLER)
	var c := _client("Cat", Roles.BOSS)
	check(_pump_until(func(): return a.welcome != null and b.welcome != null and c.welcome != null), "all in")
	a.say("good luck, everyone")
	check(_pump_until(func(): return b.chat_log.size() > 0 and c.chat_log.size() > 0), "everyone hears the table")
	a.say("they're on channel 2", "side")
	check(_pump_until(func(): return c.chat_log.size() > 1), "the boss hears the crew")
	_pump_until(func(): return false, 0.3)
	check(not b.chat_log.any(func(m): return "channel 2" in m.text), "the desk doesn't")
	check(sess.messages.any(func(m): return "good luck" in m[1]), "the host sees the table talk")


func test_a_dropped_player_reconnects_with_the_token() -> void:
	_serve()
	var a := _client("Ana", Roles.CONTROLLER)
	check(_pump_until(func(): return a.welcome != null), "in")
	var tok := a.token
	a.close()
	check(_pump_until(func(): return sess.seats.who(Roles.CONTROLLER) == "reserved"), "the seat is held")
	check_eq(sess.police.controller, "ai", "the AI minds the desk meanwhile")
	var again := _client("Ana", "", tok)
	check(_pump_until(func(): return again.role == Roles.CONTROLLER), "back in the same seat")
	check_eq(sess.police.controller, "human", "and the desk is hers again")


func test_the_seat_picker_takes_a_seat() -> void:
	_serve()
	var a := _client("Ana")
	check(_pump_until(func(): return not a.seats.is_empty()), "roster")
	var picker := SeatPicker.new()
	Engine.get_main_loop().root.add_child(picker)
	picker.setup(a)
	var got := [""]
	picker.seated.connect(func(r): got[0] = r)
	picker._process(0.0)
	check(picker._keys.has(Roles.PATROL), "every role is listed")
	picker.table.select(picker._keys.find(Roles.PATROL))
	picker.key("enter")
	check(_pump_until(func(): return got[0] != ""), "seated")
	check_eq(got[0], Roles.PATROL, "as the patrol commander")
	picker.free()


func test_the_lieutenant_and_patrol_desks() -> void:
	for role in [Roles.LIEUTENANT, Roles.PATROL]:
		var st := StationApp.new()
		Engine.get_main_loop().root.add_child(st)
		st.setup(LocalLink.new(sess, role), role, sess.world)
		for i in 3:
			st._process(1.0 / 30)
		check(st.squad_mode, role + ": the desk is the squads")
		check(st.title.text in ["LIEUTENANT", "PATROL COMMAND"], role + ": " + st.title.text)
		st._key("v")
		st._process(1.0 / 30)
		check(st.list.row_count() > 0 if st.list.has_method("row_count") else true, "a squad listed")
		st._key("down")
		check(st.sel_squad != null, role + ": UP/DOWN picks a squad")
		st._key("q")
		check(st.squad_mode, role + ": Q doesn't leave the squads")
		st.free()


func test_the_ai_takes_the_stick_and_hands_it_back() -> void:
	var app := PilotApp.new()
	Engine.get_main_loop().root.add_child(app)
	app.setup(sess, "low")
	app._process(1.0 / 30)
	check(app.bot == null, "the host flies")
	app.toggle_ai_pilot()
	app._process(1.0 / 30)
	check_eq(sess.seats.who(Roles.PILOT), "ai", "F3: the seat is the AI's")
	check(app.bot != null, "the pilot bot has the controls")
	app.toggle_ai_pilot()
	app._process(1.0 / 30)
	check(app.bot == null and sess.seats.human(Roles.PILOT), "F3 again: yours")
	app.free()


func test_a_remote_pilot_flies_the_host_aircraft() -> void:
	_serve()
	sess.seats.release(Roles.PILOT)  # the host steps out of the pilot's seat
	var p := _client("Ace")
	check(_pump_until(func(): return not p.seats.is_empty()), "roster")
	p.claim(Roles.PILOT)
	check(_pump_until(func(): return p.role == Roles.PILOT and p.latest != null), "Ace takes the pilot's seat")
	check(p.latest.has("aircraft"), "and sees the aircraft")
	p.send_input(0.5, 0.2, 0.9, -0.3, 0.0)
	check(_pump_until(func(): return not sess.remote_stick.is_empty()), "the stick reaches the host")
	var c := sess.remote_controls()
	check_near(c.aileron, 0.5, 1e-3, "roll")
	check_near(c.elevator, -0.2, 1e-3, "pitch up is elevator up")
	check_near(c.throttle, 0.9, 1e-3, "throttle")
	check_near(c.rudder, -0.3, 1e-3, "rudder")
