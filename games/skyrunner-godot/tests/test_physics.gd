extends TestCase
## The game's core promise: weight and balance change how the aircraft flies.
## Ported from tests/test_physics.py


func _load(stations_weights: Array, fuel := 200.0) -> Loadout:
	var lo := Loadout.new(Aircraft.spec("c172p"), T.masses("c172p"), fuel)
	for n in stations_weights.size():
		lo.add(Loadout.Item.new(n, "x", "cargo", stations_weights[n][1], 0))
		lo.assignment[n] = stations_weights[n][0]
	return lo


func _takeoff_distance(lo: Loadout) -> float:
	var md := T.masses("c172p")
	var fm := FlightModel.new(lo.spec, MassData.patched_root(), md)
	fm.spawn(0, 0, 0, 0, lo)
	fm.controls.throttle = 1.0
	for i in 60 * 60:
		var s := fm.state()
		var err := Py.wrap180(s.heading)
		fm.controls.rudder = maxf(-1.0, minf(1.0, -err * 0.1))
		fm.controls.elevator = -0.3 if s.ias_kts > 55 and s.pitch < 8 else 0.0
		s = fm.step(1.0 / 60, T.flat)
		if not s.on_ground and s.agl > md.gear_height_ft * 0.3048 + 0.5:
			return s.y
	check(false, "never lifted off")
	return 0.0


func test_heavy_needs_more_runway() -> void:
	var light := _takeoff_distance(_load([]))
	var heavy := _takeoff_distance(_load([[1, 200], [2, 170], [3, 170], [4, 100]]))
	check(heavy > light * 1.4, "light %s heavy %s" % [light, heavy])


func _pitch_after(lo: Loadout) -> float:
	var fm := FlightModel.new(lo.spec, MassData.patched_root(), T.masses("c172p"))
	fm.spawn(0, 0, 0, 0, lo, 1000, 90)
	fm.controls.throttle = 0.7
	var s: FlightModel.FlightState
	for i in 180:
		s = fm.step(1.0 / 60, T.flat)
	return s.pitch


func test_aft_cg_pitches_up() -> void:
	var fwd := _load([[1, 250]])
	var aft := _load([[4, 120], [5, 50], [2, 150]])
	check(fwd.compute().in_envelope and not aft.compute().in_envelope, "loads as intended")
	check(_pitch_after(aft) > _pitch_after(fwd) + 6, "aft CG pitches up")


func test_pedals_steer_the_right_way() -> void:
	for key in Aircraft.ROSTER:
		var spec := Aircraft.spec(key)
		var md := T.masses(key)
		var fm := FlightModel.new(spec, MassData.patched_root(), md)
		fm.spawn(0, 0, 0, 0, Loadout.new(spec, md, 200))
		fm.controls.throttle = 0.45
		var s: FlightModel.FlightState
		for i in 60 * 8:
			fm.controls.rudder = 1.0 if i > 60 else 0.0
			s = fm.step(1.0 / 60, T.flat)
		check(s.heading > 20 and s.heading < 300, "%s turned right, not left (%s)" % [key, s.heading])


func test_terrain_strike_is_a_crash() -> void:
	var spec := Aircraft.spec("c172p")
	var md := T.masses("c172p")
	var fm := FlightModel.new(spec, MassData.patched_root(), md)
	fm.spawn(0, 0, 0, 0, Loadout.new(spec, md, 200), 100, 90)
	var wall := func(x: float, y: float) -> float: return 150.0 if y > 200 else 0.0
	for i in 60 * 10:
		fm.step(1.0 / 60, wall)
		if fm.crash_reason:
			break
	check_eq(fm.crash_reason, "Flew into terrain")
