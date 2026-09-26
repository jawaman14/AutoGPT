extends TestCase
## Ported from tests/test_police.py

var world := World.new()


static func _rng(seed: int) -> PyRandom:
	var r := PyRandom.new()
	r.seed(seed)
	return r


func _sig(x: float, y: float, agl: float, tid := "runner", transponder := false, vx := 0.0, vy := 50.0) -> SensorNet.Signature:
	var g := world.ground(x, y)
	return SensorNet.Signature.new(tid, x, y, g + agl, agl, vx, vy, "air", transponder, "N123A" if transponder else "")


## [outcomes, t]
func _run(ps: PoliceSystem, targets: Array, secs: float, dt := 0.05, t0 := 0.0) -> Array:
	var out := {}
	var t := t0
	for i in int(secs / dt):
		t += dt
		out.merge(ps.tick(dt, t, targets), true)
	return [out, t]


func test_radar_sees_high_not_low() -> void:
	var net := SensorNet.new(world, _rng(1))
	var har := World.airfield("HAR")
	var x := har.x + 2000
	var y := har.y - 4000  # over open water
	var high: SensorNet.Detection = net.sweep([_sig(x, y, 600)], 1.0)["runner"]
	var low: SensorNet.Detection = net.sweep([_sig(x, y, 40)], 2.0)["runner"]
	check(not high.detected_by.is_empty() and high.detector_level() == "LOCK", "high: locked")
	check(low.detected_by.is_empty() and low.detector_level() == "PAINT", "low: painted only")


func test_transponder_is_seen_below_the_floor() -> void:
	var net := SensorNet.new(world, _rng(1))
	var har := World.airfield("HAR")
	var det: SensorNet.Detection = net.sweep([_sig(har.x + 2000, har.y - 4000, 20, "runner", true)], 1.0)["runner"]
	check(not det.detected_by.is_empty())
	check_eq(net.tracks["runner"].squawk, "N123A")


func test_aerostat_sees_low_targets() -> void:
	var net := SensorNet.new(world, _rng(1))  # aerostat starts winched down
	var sig := _sig(0, -9000, 80)
	check(net.sweep([sig], 1.0)["runner"].detected_by.is_empty(), "down: blind")
	net.site("AER").active = true
	check_eq(net.sweep([sig], 2.0)["runner"].detected_by, ["AER"])


func test_unidentified_primary_track_builds_suspicion_and_dispatch() -> void:
	var ps := PoliceSystem.new(world, _rng(1))
	var har := World.airfield("HAR")
	var sig := _sig(har.x + 5000, har.y + 3000, 800)
	_run(ps, [PoliceSystem.Target.new(sig, true)], 20)
	check_eq(ps.wanted, 0, "a brief primary blip is just VFR traffic...")
	_run(ps, [PoliceSystem.Target.new(sig, true)], 45)
	check(ps.wanted >= 1, "...a sustained one isn't")
	check(Py.any(ps.units, func(u): return u.faction() == "police"), "units up")


func test_squawking_traffic_is_ignored_unless_tipped() -> void:
	var har := World.airfield("HAR")
	var sig := _sig(har.x + 5000, har.y + 3000, 800, "runner", true)
	var ps := PoliceSystem.new(world, _rng(1))
	_run(ps, [PoliceSystem.Target.new(sig, true)], 30)
	check(ps.wanted == 0 and ps.suspicion == 0, "ignored")
	var ps2 := PoliceSystem.new(world, _rng(1), null, "ai", {"informants": true})
	ps2.add_tip(sig.x, sig.y, 3000, "tip", "N123A", "runner")
	_run(ps2, [PoliceSystem.Target.new(sig, true)], 30)
	check(ps2.suspicion > 40 or ps2.wanted, "tipped: watched")


func test_squawk_lost_is_a_red_flag() -> void:
	var ps := PoliceSystem.new(world, _rng(1))
	var har := World.airfield("HAR")
	var on := _sig(har.x + 5000, har.y + 3000, 800, "runner", true)
	var r := _run(ps, [PoliceSystem.Target.new(on)], 5)
	var off := _sig(har.x + 5000, har.y + 3000, 800, "runner", false)
	_run(ps, [PoliceSystem.Target.new(off)], 1.5, 0.05, r[1])
	check(ps.suspicion >= 50, "squawk lost")


func test_units_chase_last_known_not_truth() -> void:
	var ps := PoliceSystem.new(world, _rng(1))
	ps.case("runner").wanted = 3
	ps.case("runner").last_known = [0.0, -6000.0, 0.0]
	var u := PoliceSystem.Pursuer.new("heli", 0, -8000, 400, 0.0, [0, -9000], {"speed": 50, "id": "Hawk-1", "target_id": "runner"})
	ps.units.append(u)
	var hidden := _sig(8000, 8000, 30)  # far away, low, behind the ridge
	_run(ps, [PoliceSystem.Target.new(hidden, true)], 45)
	check_eq(u.target_id, "runner")
	check(sqrt(u.x ** 2 + (u.y + 6000) ** 2) < 900, "orbiting where it was last seen")


func test_pursuer_closes_and_busts() -> void:
	var ps := PoliceSystem.new(world, _rng(1))
	ps.case("runner").wanted = 1
	ps.units.append(PoliceSystem.Pursuer.new("interceptor", 0, -9000, 900, 0.0, [0, -9000],
		{"speed": 80, "id": "Falcon-1", "target_id": "runner"}))
	var x := 0.0
	var y := -6000.0
	var out := {}
	var t := 0.0
	for i in 4000:
		y += 40 * 0.05
		t += 0.05
		var sig := SensorNet.Signature.new("runner", x, y, 900, 900 - world.ground(x, y), 0.0, 40.0)
		out = ps.tick(0.05, t, [PoliceSystem.Target.new(sig, true)])
		if not out.is_empty():
			break
	check_eq(out, {"runner": "busted"})


func test_clean_aircraft_is_released() -> void:
	var ps := PoliceSystem.new(world, _rng(1))
	ps.case("runner").wanted = 1
	ps.units.append(PoliceSystem.Pursuer.new("interceptor", 0, -6600, 900, 0.0, [0, -9000],
		{"speed": 60, "id": "Falcon-1", "target_id": "runner"}))
	var t := 0.0
	var out := {}
	for i in 2000:
		t += 0.05
		var sig := SensorNet.Signature.new("runner", 0, -6000 + t * 40, 900, 500, 0.0, 40.0)
		out = ps.tick(0.05, t, [PoliceSystem.Target.new(sig, false)])
		if not out.is_empty():
			break
	check_eq(out, {"runner": "clean"})


## Terrain avoidance only looks straight ahead - a steep enough wall wins.
func test_pursuer_can_fly_into_terrain() -> void:
	var u := PoliceSystem.Pursuer.new("interceptor", 0, 1500, 350, 0.0, [0, 0], {"speed": 110})
	var target := SensorNet.Signature.new("x", 0, 12000, 350, 0)
	for i in 2000:
		u.update(0.05, target, world)
		if u.state == "crashed":
			break
	var ridge_top := -INF
	for y in range(1500, 12000, 100):
		ridge_top = maxf(ridge_top, world.ground(0, y))
	check(u.state == "crashed" or u.z > ridge_top)


func test_encryption_hides_dispatch_from_scanner() -> void:
	var radio := RadioNet.new(_rng(1))
	radio.transmit(1.0, "police", "Hawk-1", "airborne from Harbor", [0, 0])
	radio.encrypted = true
	radio.transmit(2.0, "police", "Hawk-1", "tally on target", [0, 0])
	var heard := radio.scanner(0.0).map(func(e): return e[1])
	check(heard.has("Hawk-1: airborne from Harbor"))
	check(Py.any(heard, func(h): return "scrambled" in h))


func test_direction_finding_fix() -> void:
	var radio := RadioNet.new(_rng(2))
	radio.df_enabled = true
	radio.df_stations = [["A", -9000, -9500], ["B", 2500, -3000]]
	var msg := radio.transmit(1.0, "runner", "N1", "boat, come to me", [8000, -12000])
	var res := radio.direction_find(msg)
	check(res.bearings.size() == 2 and res.fix != null, "two bearings, a fix")
	# ~2.5 deg bearing error at 15+ km: the fix is a search area, not a point
	check(absf(res.fix[0] - 8000) < 3000 and absf(res.fix[1] + 12000) < 3000, "fix near truth")


func test_intersect_parallel_is_none() -> void:
	check(RadioNet.intersect(RadioNet.Bearing.new("a", 0, 0, 90), RadioNet.Bearing.new("b", 0, 100, 90)) == null)


## Python's radar (one look a second, a binary clutter floor): these are ports
## of, or replays against, the Python game. The Godot radar is tests/test_radar.gd.
func before_each() -> void:
	SensorNet.REALISM = false
	Economy.REALISM = false  # Python has fixed prices (the markets: tests/test_economy.gd)


func after_each() -> void:
	SensorNet.REALISM = true
	Economy.REALISM = true
