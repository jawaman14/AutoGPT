extends TestCase
## The Godot radar (SensorNet.REALISM): horizon, clutter and weather, the MTI
## notch, scan periods, probability of detection, trails and Mode C, squawk
## codes, coverage and the detector's bearing.

var world := World.new()


func _sig(x: float, y: float, agl: float, vx := 0.0, vy := 60.0, transponder := false) -> SensorNet.Signature:
	var sig := SensorNet.Signature.new("runner", x, y, world.ground(x, y) + agl, agl, vx, vy, "air", transponder,
		"N123A" if transponder else "")
	sig.rcs = 1.0
	return sig


## Sweep every site at once, `looks` times, 5 s apart: [detection, net].
func _look(sig: SensorNet.Signature, looks := 1, wx := {}) -> Array:
	var net := SensorNet.new(world)
	if not wx.is_empty():
		net.weather = wx
	var det: SensorNet.Detection = null
	for i in looks:
		for st in net.sites:
			st.next_scan = 0.0
		det = net.sweep([sig], 5.0 * (i + 1))["runner"]
	return [det, net]


## A point `d` m south of HAR's radar, over the sea, heading straight at it.
func _toward_har(d: float, agl: float) -> SensorNet.Signature:
	var har := World.airfield("HAR")
	return _sig(har.x, har.y - d, agl, 0.0, 60.0)


func test_the_earth_curves_away_from_the_radar() -> void:
	check_near(SensorNet.RadarSite.horizon_drop(20000.0), 23.5, 0.2, "20 km out the target sits ~24 m below the straight line")
	check_near(SensorNet.RadarSite.horizon_drop(40000.0), 94.2, 0.3, "and four times that at 40 km")


func test_inbound_traffic_is_seen() -> void:
	var r := _look(_toward_har(6000.0, 600.0), 3)
	check(not r[0].detected_by.is_empty(), "600 m, 6 km, flying at the radar: locked")


func test_crossing_the_beam_hides_you_in_the_mti_notch() -> void:
	var har := World.airfield("HAR")
	var across := _sig(har.x, har.y - 6000.0, 600.0, 60.0, 0.0)  # flying east, radar due north
	var r := _look(across, 3)
	check(r[0].detected_by.is_empty(), "no radial speed: cancelled as clutter")
	check(not r[0].painted_by.is_empty(), "but it still paints you (your detector knows)")


func test_a_rough_sea_and_rain_raise_the_floor() -> void:
	var sig := _toward_har(9000.0, 150.0)
	check(not _look(sig, 3, {"sky": "clear", "wind_kt": 5.0})[0].detected_by.is_empty(), "calm, clear: seen at 150 m")
	check(_look(sig, 3, {"sky": "storm", "wind_kt": 28.0})[0].detected_by.is_empty(), "storm and a big sea: lost in clutter")


func test_the_transponder_answers_through_clutter() -> void:
	var har := World.airfield("HAR")
	var sig := _sig(har.x, har.y - 6000.0, 30.0, 60.0, 0.0, true)
	sig.code = "1200"
	var r := _look(sig, 1)
	check(not r[0].detected_by.is_empty(), "secondary radar")
	var tr: SensorNet.Track = r[1].tracks["runner"]
	check_eq(tr.code, "1200", "Mode A")
	check_near(float(tr.alt), sig.z, 1e-6, "Mode C altitude")


func test_primary_tracks_have_no_altitude_and_keep_a_trail() -> void:
	var net := SensorNet.new(world)
	var har := World.airfield("HAR")
	for i in 6:
		for st in net.sites:
			st.next_scan = 0.0
		net.sweep([_sig(har.x, har.y - 7000.0 + i * 300.0, 700.0)], 5.0 * (i + 1))
	var tr: SensorNet.Track = net.tracks["runner"]
	check(tr.alt == null, "no transponder, no altitude readout")
	check_eq(tr.trail.size(), 6, "one trail dot per hit")


func test_a_site_only_looks_once_a_turn() -> void:
	var net := SensorNet.new(world)
	var har: SensorNet.RadarSite = net.site("HAR")
	check_near(har.period_s, 4.8, 1e-9, "an ASR turns in 4.8 s")
	check_near(net.site("AER").period_s, 12.0, 1e-9, "the aerostat's long-range set in 12")
	har.next_scan = 10.0
	net.sweep([_toward_har(6000.0, 600.0)], 5.0)
	check(not net.tracks.has("runner"), "the beam hasn't come round yet")
	net.sweep([_toward_har(6000.0, 600.0)], 10.0)
	check(net.tracks.has("runner"), "now it has")
	check_near(har.next_scan, 14.8, 1e-9, "next look one turn later")


func test_small_aircraft_fade_first_at_range() -> void:
	var hits := {}
	for rcs in [0.5, 2.2]:
		var n := 0
		for i in 60:
			var sig := _toward_har(20000.0, 1500.0)
			sig.rcs = rcs
			var net := SensorNet.new(world)
			net.xrng.seed(i)
			for st in net.sites:
				st.next_scan = 0.0
			if not net.sweep([sig], 5.0)["runner"].detected_by.is_empty():
				n += 1
		hits[rcs] = n
	check(hits[2.2] > hits[0.5], "a Twin Otter is a bigger blip than a small single: %s" % [hits])


func test_the_detector_knows_who_is_painting_and_from_where() -> void:
	var r := _look(_toward_har(6000.0, 600.0), 1)
	var p: Array = r[0].painters.filter(func(q): return q.code == "HAR")
	check_eq(p.size(), 1, "HAR is painting")
	check_near(p[0].bearing, 0.0, 1.0, "due north of us")
	check(p[0].locked, "and locked")


func test_coverage_shows_the_blind_valleys() -> void:
	var net := SensorNet.new(world)
	var low := net.coverage("HAR", 150.0, 32)
	var high := net.coverage("HAR", 1500.0, 32)
	var n_low := 0
	var n_high := 0
	for i in low.size():
		n_low += low[i]
		n_high += high[i]
	check(n_low > 0, "it sees something at 150 m")
	check(n_high > n_low, "and more of the island from higher up (%d vs %d cells)" % [n_high, n_low])


func test_center_reacts_to_emergency_codes() -> void:
	var s := Session.new({"seed": 3, "location": "HAR"})
	s.update(1.0 / 30)
	s.transponder = true
	s.police.stock = {"heli": 1, "interceptor": 0, "cutter": 0}
	s.spawn_airborne(World.airfield("HAR").x, World.airfield("HAR").y - 6000, 0, 600, 100)
	for i in 30 * 12:
		s.update(1.0 / 30)
	check(s.command(Roles.PILOT, "squawk", {"code": "7700"})[0], "dial 7700")
	for i in 30 * 12:
		s.update(1.0 / 30)
	check(s.law_log.any(func(e): return "7700" in e[1]), "Center hears the emergency")
	check(s.police._launches.size() + s.police.units.size() > 0, "and sends the helicopter")
	check(not s.command(Roles.PILOT, "squawk", {"code": "7800"})[0], "8 isn't an octal digit")
	s.dispose()
