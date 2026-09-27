extends TestCase
## The game's own flight model (scripts/sim/flight/): determinism, control
## signs, ground handling, the C172's handbook envelope, and the things the
## game leans on (crashes, fuel, loadout mass, wind).

const DT := 1.0 / 30


static func _fm(key := "c172p", fuel_frac := 0.6) -> Array:
	var spec := Aircraft.spec(key)
	var md := T.masses(key)
	var lo := Loadout.new(spec, md, md.fuel_capacity_lb() * fuel_frac)
	return [FlightModel.new(spec, MassData.patched_root(), md), lo]


## Straight and level at 900 m, 100 kt, engines running.
static func _airborne(key := "c172p") -> FlightModel:
	var r := _fm(key)
	var fm: FlightModel = r[0]
	fm.spawn(0, 0, 0, 0, r[1], 900.0, 100.0)
	fm.controls.throttle = 0.7
	return fm


static func _fly(fm: FlightModel, secs: float) -> FlightModel.FlightState:
	var st: FlightModel.FlightState
	for i in int(secs / DT):
		st = fm.step(DT, T.flat)
	return st


func test_same_inputs_same_flight() -> void:
	var a := _airborne()
	var b := _airborne()
	a.controls.aileron = 0.3
	b.controls.aileron = 0.3
	var sa := _fly(a, 8)
	var sb := _fly(b, 8)
	check_eq([sa.x, sa.y, sa.alt, sa.heading, sa.roll], [sb.x, sb.y, sb.alt, sb.heading, sb.roll])


func test_controls_move_the_aircraft_the_right_way() -> void:
	var fm := _airborne()
	fm.controls.aileron = 0.4
	check(_fly(fm, 2).roll > 10, "right aileron rolls right")
	fm = _airborne()
	fm.controls.aileron = -0.4
	check(_fly(fm, 2).roll < -10, "left aileron rolls left")
	fm = _airborne()
	var p0 := fm.state().pitch
	fm.controls.elevator = -0.5
	check(_fly(fm, 1.5).pitch > p0 + 5, "back stick pitches up")
	fm = _airborne()
	fm.controls.elevator = 0.5
	check(_fly(fm, 1.5).pitch < p0 - 5, "forward stick pitches down")
	fm = _airborne()
	var h0 := fm.state().heading
	fm.controls.rudder = 0.6
	check(Py.wrap180(_fly(fm, 2).heading - h0) > 2, "right rudder yaws right")


func test_c172_handbook_envelope() -> void:
	var r := _fm()
	var fm: FlightModel = r[0]
	fm.spawn(0, 0, 0, 0, r[1])
	fm.controls.brake = 1.0
	fm.controls.throttle = 1.0
	var st := _fly(fm, 3)
	check_between(st.rpm, 2150, 2450, "static rpm (POH 2,280-2,400)")
	fm.controls.brake = 0.0
	var t := 0.0
	while st.ias_kts < 47 and t < 40:
		st = fm.step(DT, T.flat)
		t += DT
	var roll_m := Vector2(st.x, st.y).length()
	# POH: 890 ft at 2,400 lb; at ~1,900 lb about (1900/2400)^2 of that
	check_between(roll_m * 3.28084, 400, 800, "ground roll to 47 kt, ft")
	check_between(t, 9, 18, "seconds to 47 kt")
	# full-power climb near Vy (74 KIAS): the handbook's 730 fpm at 2,400 lb, more when light
	fm = _airborne()
	fm.controls.throttle = 1.0
	var vs := 0.0
	var n := 0
	var trim := 0.0
	for i in int(60 / DT):
		st = fm.step(DT, T.flat)
		var pitch_t := clampf(6.0 + (st.ias_kts - 74.0) * 0.8, -5, 15)
		trim = clampf(trim + (pitch_t - st.pitch) * 0.002, -0.5, 0.5)
		fm.controls.elevator = clampf(-(pitch_t - st.pitch) * 0.08 + st.q_dps * 0.03 - trim, -1, 1)
		fm.controls.aileron = clampf(-st.roll * 0.04 - st.p_dps * 0.01, -1, 1)
		if i > int(30 / DT):
			vs += st.vs_fpm
			n += 1
	check_between(st.ias_kts, 66, 84, "held near Vy")
	check_between(vs / n, 600, 1300, "climb rate at Vy, fpm")


func test_brakes_stop_it_and_differential_brakes_pivot() -> void:
	var r := _fm()
	var fm: FlightModel = r[0]
	fm.spawn(0, 0, 90, 0, r[1])
	fm.controls.throttle = 0.6
	var st := _fly(fm, 8)
	check(st.gs_kts > 10, "rolling (%.1f kt)" % st.gs_kts)
	fm.controls.throttle = 0.0
	fm.controls.brake = 1.0
	st = _fly(fm, 8)
	check(st.gs_kts < 1.0, "stopped (%.2f kt)" % st.gs_kts)
	check(st.on_ground and st.wow_count == 3, "three wheels down")
	var h0 := st.heading
	fm.controls.brake = 0.0
	fm.controls.diff_brake = 1.0  # right brake
	fm.controls.throttle = 0.5
	st = _fly(fm, 6)
	check(Py.wrap180(st.heading - h0) > 10, "right brake turns right (%.1f)" % Py.wrap180(st.heading - h0))


## Rising ground that would bury the gear is flight into terrain, not something
## for the gear springs (a hard landing is the Session's call, from the sink rate).
func test_flying_into_the_ground_crashes() -> void:
	var fm := _airborne()
	_fly(fm, 1)
	check(fm.crash_reason == null, "flying")
	fm.step(DT, func(x, _y): return 1000.0 if x > 30.0 else 0.0)
	fm.step(DT, func(_x, _y): return 1000.0)
	check_eq(fm.crash_reason, "Flew into terrain")


func test_dry_tanks_stop_the_engine() -> void:
	var fm := _airborne()
	for tk in fm.fdm.tanks:
		tk.lb = 0.01
	var st := _fly(fm, 10)
	check(not st.engine_running, "engine quits")
	check_near(st.fuel_lb, 0.0, 1e-9, "tanks empty")
	check(st.rpm < 2000, "windmilling (%d rpm)" % st.rpm)


func test_weight_and_cg_follow_the_load() -> void:
	var r := _fm()
	var spec := Aircraft.spec("c172p")
	var lo: Loadout = r[1]
	var fm: FlightModel = r[0]
	fm.spawn(0, 0, 0, 0, lo)
	var w0 := fm.state().weight_lb
	var cg0 := fm.state().cg_in
	var aft := -1
	for i in spec.stations.size():
		if spec.stations[i].kind != "pilot" and (aft < 0 or spec.stations[i].x_in > spec.stations[aft].x_in):
			aft = i
	var item := Loadout.Item.new(1, "crate", "cargo", 120, 1)
	lo.add(item)
	lo.assignment[item.id] = aft
	fm.apply_loadout(lo)
	var st := fm.state()
	check_near(st.weight_lb, w0 + 120, 0.01, "weight")
	check(st.cg_in > cg0 + 0.5, "aft load moves the CG aft (%.2f -> %.2f)" % [cg0, st.cg_in])


## Once the aircraft has settled into the moving air mass, its ground velocity
## is its airspeed along the heading plus the wind (it crabs; it doesn't fight it).
func test_wind_drifts_the_aircraft() -> void:
	var fm := _airborne()
	fm.fdm.set_property("atmosphere/wind-east-fps", 30.0)
	var st: FlightModel.FlightState
	for i in int(30 / DT):  # wings held level
		st = fm.step(DT, T.flat)
		fm.controls.aileron = clampf(-st.roll * 0.04 - st.p_dps * 0.01, -1, 1)
	var air := fm.fdm.vt * 0.3048 * cos(deg_to_rad(st.pitch - st.alpha_deg))
	var hdg := deg_to_rad(st.heading)
	check_near(st.vx, air * sin(hdg) + 30 * 0.3048, 1.5, "east ground speed, m/s")
	check_near(st.vy, air * cos(hdg), 1.5, "north ground speed, m/s")


func test_every_aircraft_holds_together_hands_off() -> void:
	for key in Aircraft.ROSTER:
		var fm := _airborne(key)
		var st := _fly(fm, 10)  # hands off, so the propeller's torque slowly rolls some of them
		check(st.valid and fm.crash_reason == null, key + " valid")
		check_between(st.ias_kts, 40, 200, key + " airspeed")
		check(absf(st.roll) < 60, "%s roll %.0f" % [key, st.roll])
