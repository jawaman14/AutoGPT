extends TestCase
## The Godot radio (RadioNet.REALISM): VHF line of sight, channels, the length
## of a call and DF, least-squares fixes with an error ellipse, crew radio,
## jamming, and the tactical channel.

var world := World.new()


func _net() -> RadioNet:
	var r := PyRandom.new()
	r.seed(3)
	var net := RadioNet.new(r)
	net.world = world
	net.df_enabled = true
	for a in world.airfields:
		if a.police:
			net.df_stations.append([a.code, a.x, a.y])
	return net


func test_vhf_reaches_further_from_higher_up() -> void:
	var net := _net()
	var har := World.airfield("HAR")
	var far := [har.x + 30000.0, har.y, null]  # 30 km out over the sea, on the water
	check(not net.can_hear([har.x, har.y, null], far), "ground to ground at 30 km: below each other's horizon")
	check(net.can_hear([har.x + 1000.0, har.y, 800.0], far), "an aircraft at 800 m reaches it")


func test_hills_block_a_call() -> void:
	var net := _net()
	var egl := World.airfield("EGL")  # up on the ridge
	var south := [egl.x, egl.y - 9000.0]
	var north := [egl.x, egl.y + 7000.0]
	var low := [south[0], south[1], world.ground(south[0], south[1]) + 20.0]
	var rx := [north[0], north[1], null]
	check(not net.can_hear(low, rx), "20 m up behind the ridge: nobody on the far side hears you")
	var high := [south[0], south[1], 4500.0]
	check(net.can_hear(high, rx), "climb above it and you're through")


func test_a_long_call_gets_a_tight_fix_and_a_burst_a_loose_one() -> void:
	var sizes := {}
	for dur in [1.0, 6.0]:
		var net := _net()
		var m := net.transmit(10.0, "boat", "N1", "call", [4000.0, -6000.0, 900.0], dur)
		var df := net.direction_find(m)
		check(df.fix != null, "%.0f s call: fixed" % dur)
		sizes[dur] = df.ellipse[0]
	check(sizes[1.0] > sizes[6.0] * 2.0, "the 1 s burst's ellipse is far bigger (%.0f vs %.0f m)" % [sizes[1.0], sizes[6.0]])


func test_the_fix_is_near_the_transmitter() -> void:
	var net := _net()
	var m := net.transmit(10.0, "runner", "N1", "long call for the boat please", [4000.0, -6000.0, 900.0], 8.0)
	var df := net.direction_find(m, [["Hawk-1", 9000.0, -2000.0, 600.0]])
	check_eq(df.bearings.size(), 3, "two strips and the helicopter")
	var err := PyMath.hypot(df.fix[0] - 4000.0, df.fix[1] + 6000.0)
	check(err < 2.5 * df.ellipse[0] + 100.0, "error %.0f m, ellipse %.0f m" % [err, df.ellipse[0]])


func test_a_scanner_only_hears_its_channels_and_range() -> void:
	var net := _net()
	var har := World.airfield("HAR")
	net.transmit(1.0, "police", "Hawk-1", "on station", [har.x, har.y - 3000.0, 400.0])
	net.police_channel = "police_tac"
	net.transmit(2.0, "police", "Hawk-1", "moving to the quarry", [har.x, har.y - 3000.0, 400.0])
	var rx := [har.x + 2000.0, har.y - 5000.0, 300.0]
	var basic := net.scanner_at(0.0, rx, ["police"])
	check_eq(basic.size(), 1, "a dispatch-only scanner misses the tactical call")
	var programmed := net.scanner_at(0.0, rx, ["police", "police_tac"])
	check_eq(programmed.size(), 2, "a programmed one gets both")
	check("[tac]" in programmed[1][1], "tagged with its channel")


func test_jamming_blocks_calls_from_inside_the_zone() -> void:
	var net := _net()
	net.jammed_zones = [[0.0, 0.0, 5000.0]]
	var m := net.transmit(1.0, "boat", "N1", "come to me", [1000.0, 1000.0, 300.0])
	check(m.jammed, "inside the zone")
	check(net.direction_find(m).bearings.is_empty(), "nothing for the DF net either")
	check(not net.transmit(2.0, "boat", "N1", "come to me", [9000.0, 1000.0, 300.0]).jammed, "outside it's fine")


func test_the_boat_needs_to_hear_the_call() -> void:
	var s := Session.new({"seed": 5, "location": "HAR", "features": Session.SANDBOX_FEATURES})
	s.update(1.0 / 30)
	var drop := Maritime.random_drop_point(s.world, s.rng, s.maritime.cove)
	var job := Jobs.airdrop_job(World.airfield("HAR"), drop, s.rng, 2)
	s.boards["HAR"].append(job)
	s.accept_job(job)
	s.spawn_airborne(drop[0] - 500, drop[1], 90, 300, 90)
	s.update(1.0 / 30)
	check(s.command(Roles.PILOT, "call_boat")[0], "called")
	check(s.messages.back()[1].begins_with("Called"), "the boat answers: " + s.messages.back()[1])
	s.radio.jammed_zones = [[s.state.x, s.state.y, 3000.0]]
	s.command(Roles.PILOT, "call_boat")
	check("Jammed" in s.messages.back()[1], "jammed: " + s.messages.back()[1])
	s.dispose()


func test_brevity_codes_and_crew_chat_are_df_targets() -> void:
	var s := Session.new({"seed": 5, "location": "HAR", "features": Session.SANDBOX_FEATURES, "mode": Roles.COOP})
	s.update(1.0 / 30)
	s.set_copilot("human")
	s.spawn_airborne(World.airfield("HAR").x + 6000, World.airfield("HAR").y - 4000, 90, 700, 100)
	s.update(1.0 / 30)
	s.command(Roles.COPILOT, "chat", {"text": "two minutes out, have the boat ready at the mark"})
	check(s.law_log.any(func(e): return e[1].begins_with("DF:")), "the task force DF's crew chatter")
	check(s.radio.log.back().channel == "runner", "on the runner channel")
	s.dispose()
