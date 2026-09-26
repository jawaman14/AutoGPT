extends TestCase
## Loopback multiplayer: host session + remote co-pilot and controller over
## real TCP sockets (ported from tests/test_net.py). Sockets are polled by hand
## here because the test runner doesn't spin the SceneTree between calls.

var sess: Session
var srv: HostServer
var clients: Array = []


func before_each() -> void:
	sess = Session.new({"seed": 4, "mode": Roles.VERSUS})
	srv = HostServer.new()
	srv.attach(sess)
	check_eq(srv.start(0, Roles.VERSUS, "127.0.0.1"), null, "server listening")


func after_each() -> void:
	for c in clients:
		c.close()
		c.free()
	clients.clear()
	srv.stop()
	srv.free()
	sess.dispose()


func _client(name: String, role: String) -> NetClient:
	var c := NetClient.new().open("127.0.0.1", srv.port, name, role)
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


func test_copilot_joins_loads_and_gets_runner_snapshot() -> void:
	var cp := _client("Rosa", "copilot")
	check(_pump_until(func(): return cp.latest != null), "snapshot arrives")
	check_eq(sess.copilot, "human")
	check(sess.loadout.copilot_aboard, "co-pilot aboard")
	var snap: Dictionary = cp.latest
	check(snap.side == "runner" and snap.has("loadout") and snap.has("aircraft"), "runner snapshot")
	var job = Py.first(snap.board, func(j): return j.weight < 250 and not j.airdrop)
	var seq := cp.send_command("accept_job", {"job_id": job.id})
	check(_pump_until(func(): return cp.acks.has(seq)), "ack")
	check(cp.acks[seq][0], str(cp.acks[seq]))
	check(Py.any(sess.active_jobs, func(j): return j.id == int(job.id)), "job taken on the host")
	seq = cp.send_command("launch", {"kind": "heli"})  # not a runner command
	check(_pump_until(func(): return cp.acks.has(seq)), "ack")
	check_eq(cp.acks[seq][0], false, "refused")
	cp.close()
	check(_pump_until(func(): return sess.copilot == null), "co-pilot leaves")


func test_copilot_works_the_flight_over_the_wire() -> void:
	# a crewed airdrop run: the remote co-pilot pumps, kicks and radios the pilot
	sess.features.erase("cutters")
	sess.money = 20000
	sess.buy_gear("ferry_tank")
	for i in 60 * 20:
		sess.update(1.0 / 60)
	sess.fill_ferry(150)
	var drop := Maritime.random_drop_point(sess.world, sess.rng, sess.maritime.cove)
	var job := Jobs.airdrop_job(World.airfield("HAR"), drop, sess.rng, 2)
	sess.boards["HAR"].append(job)
	sess.accept_job(job)
	for i in 60 * 30:
		sess.update(1.0 / 60)
	var cp := _client("Rosa", "copilot")
	check(_pump_until(func(): return cp.latest != null and sess.copilot == "human"), "co-pilot aboard")
	sess.spawn_airborne(drop[0] - 400, drop[1], 90, 150, 88)
	sess.command(Roles.PILOT, "autopilot", {"on": true})
	sess.fm.fdm.set_property("propulsion/tank[0]/contents-lbs", 50)
	sess.fm.fdm.set_property("propulsion/tank[1]/contents-lbs", 50)
	var seq := cp.send_command("pump", {"on": true})
	check(_pump_until(func(): return cp.acks.has(seq)) and cp.acks[seq][0], "pump acked")
	check(_pump_until(func(): return cp.latest.aircraft.pumping), "the snapshot shows the pump on")
	seq = cp.send_command("kick", {"count": 2})
	check(_pump_until(func(): return cp.acks.has(seq)) and cp.acks[seq][0], "kick acked: %s" % [cp.acks.get(seq)])
	check(_pump_until(func(): return sess._droppables().is_empty(), 8.0), "both bales out, 2 s apiece")
	seq = cp.send_command("chat", {"text": "bales away"})
	check(_pump_until(func(): return cp.latest.messages.any(func(m): return m == "[copilot] bales away")), "the chat comes back in the runner snapshot")
	check(sess.messages.any(func(m): return m[1] == "[copilot] bales away"), "and reaches the pilot's HUD feed")


func test_controller_sees_tracks_not_truth() -> void:
	var ctl := _client("Hart", "controller")
	check(_pump_until(func(): return ctl.latest != null), "snapshot arrives")
	check_eq(sess.police.controller, "human")
	var snap: Dictionary = ctl.latest
	check_eq(snap.side, "law")
	check(not snap.has("aircraft") and not snap.has("loadout"), "no runner truth")
	# the runner flies low over water, transponder off: no track, so the controller sees nothing
	sess.transponder = false
	sess.spawn_airborne(8000, -14000, 90, 30, 100)
	sess.mapper.controls.throttle = 0.8
	_pump_until(func(): return false, 1.5)
	var text := JSON.stringify(ctl.latest)
	check(not ("runner" in ctl.latest.tracks.map(func(t): return t.id)), "no runner track")
	check(not ("%.1f" % sess.state.x in text), "true position never sent")
	var seq := ctl.send_command("launch", {"kind": "heli", "base": "HAR"})
	check(_pump_until(func(): return ctl.acks.has(seq)), "ack")
	check(ctl.acks[seq][0], str(ctl.acks[seq]))


func test_seat_rules() -> void:
	var p := _client("X", "pilot")  # the host flies
	_pump_until(func(): return p.error != null, 3.0)
	check(p.error != null and "taken" in p.error, str(p.error))
	var a := _client("A", "spotter")
	check(_pump_until(func(): return a.welcome != null), "spotter joins")
	var b := _client("B", "spotter")
	_pump_until(func(): return b.error != null, 3.0)
	check(b.error != null and "taken" in b.error, str(b.error))


func test_local_link_police_mode() -> void:
	var ps := Session.new({"seed": 9, "mode": Roles.POLICE, "humans": {Roles.CONTROLLER: "me"}})
	var link := LocalLink.new(ps, Roles.CONTROLLER)
	for i in 30 * 25:
		link.tick(1.0 / 30)
	var snap: Dictionary = link.snapshot()
	check(snap.side == "law" and snap.stock.heli == 1, "law snapshot")
	link.send_command("launch", {"kind": "heli", "base": "VAL"})
	check(link.last_result[0], str(link.last_result))
	check(JSON.stringify(Snapshot.build(ps, Roles.CONTROLLER)) != "", "serialisable")
	ps.dispose()


func test_desk_sees_anonymous_track_numbers() -> void:
	sess.transponder = false
	sess.spawn_airborne(-4000, -8000, 45, 400, 100)
	sess.mapper.controls.throttle = 0.75
	sess.command(Roles.PILOT, "autopilot", {"on": true})
	for i in 60 * 5:
		sess.update(1.0 / 60)
	var snap := Snapshot.build(sess, Roles.CONTROLLER)
	var ids: Array = snap.tracks.map(func(t): return t.id)
	check(not ids.is_empty() and Py.all(ids, func(i): return str(i).begins_with("T")), str(ids))
	check(not ("\"runner\"" in JSON.stringify(snap)), "internal id never appears as a value")
	sess.police.launch("heli", "HAR")
	for i in 60 * 8:
		sess.update(1.0 / 60)
	var hawk = sess.police.units[0]
	var r: Array = sess.command(Roles.CONTROLLER, "dispatch", {"unit": hawk.id, "target": ids[0]})
	check(r[0] and hawk.target_id == "runner", str(r))


## A Godot host serves the same wire protocol as the Python one: exercise it
## with a raw socket speaking the documented JSON lines.
func test_wire_protocol_is_python_compatible() -> void:
	var peer := StreamPeerTCP.new()
	peer.connect_to_host("127.0.0.1", srv.port)
	var buf := PackedByteArray()
	var got := []
	var sent := false
	var end := Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < end and not got.any(func(g): return g is Dictionary and g.get("t") == "snap"):
		peer.poll()
		srv._process(0.0)
		srv.pump(sess)
		srv.publish(sess, true)
		if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			if not sent:
				peer.put_data('{"t":"hello","v":2,"name":"py","role":"spotter"}\n'.to_utf8_buffer())
				sent = true
			for l in HostServer.read_lines(peer, buf):
				got.append(JSON.parse_string(l))
		OS.delay_msec(5)
	check(got.size() >= 2, "welcome + snapshot")
	if got.size() >= 2:
		check_eq(got[0].t, "welcome")
		check_eq(got[0].role, "spotter")
		var snap = Py.first(got, func(g): return g.get("t") == "snap")
		check(snap != null, "a snapshot for the v2 client")
		check_eq(int(snap.v), Snapshot.PROTOCOL_VERSION)
	peer.disconnect_from_host()
