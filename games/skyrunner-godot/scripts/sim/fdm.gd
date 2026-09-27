class_name FlightModel
extends RefCounted
## Game-facing wrapper around one FlightDynamics (the Godot-native flight model,
## scripts/sim/flight/): controls in, a FlightState out, fixed 120 Hz sub-steps.
##
## World frame: x = east (m), y = north (m), z = up (m ASL). The flight model
## works on a flat local tangent plane in feet; lat/lon helpers remain for the
## callers that speak geodetic.

const FT := 0.3048
const KT := 0.514444
const LAT0 := 0.0
const LON0 := 0.0
# WGS84 metres per degree at LAT0 (cos(0) etc. evaluate to exactly 1)
const M_PER_DEG_LAT := 111132.92 - 559.82 * 1.0 + 1.175 * 1.0
const M_PER_DEG_LON := 111412.84 * 1.0 - 93.5 * 1.0


static func xy_to_latlon(x: float, y: float) -> Array:
	return [LAT0 + y / M_PER_DEG_LAT, LON0 + x / M_PER_DEG_LON]


static func latlon_to_xy(lat: float, lon: float) -> Array:
	return [(lon - LON0) * M_PER_DEG_LON, (lat - LAT0) * M_PER_DEG_LAT]


class Controls:
	var aileron := 0.0  ## -1 left .. +1 right
	var elevator := 0.0  ## -1 nose up .. +1 nose down (the aircraft data's convention)
	var rudder := 0.0
	var throttle := 0.0
	var flaps := 0.0  ## 0..1
	var brake := 0.0
	var pitch_trim := 0.0
	var diff_brake := 0.0  ## -1 left wheel only .. +1 right wheel only (pivot turns)

	static func make(d := {}) -> Controls:
		var c := Controls.new()
		for k in d:
			c.set(k, d[k])
		return c

	func copy() -> Controls:
		var c := Controls.new()
		for p in ["aileron", "elevator", "rudder", "throttle", "flaps", "brake", "pitch_trim", "diff_brake"]:
			c.set(p, get(p))
		return c


class FlightState:
	var x: float
	var y: float
	var alt: float  ## CG altitude ASL, m
	var agl: float  ## CG height above the terrain the flight model sees, m
	var heading: float  ## deg true, 0 = north, clockwise
	var pitch: float
	var roll: float  ## deg, right wing down positive
	var ias_kts: float
	var gs_kts: float
	var vs_fpm: float
	var alpha_deg: float
	var on_ground: bool
	var wow_count: int
	var fuel_lb: float
	var weight_lb: float
	var cg_in: float
	var rpm: float
	var engine_running: bool
	var stall_warning: bool
	var valid: bool
	var vx := 0.0  ## world velocity m/s
	var vy := 0.0
	var p_dps := 0.0  ## roll rate
	var q_dps := 0.0  ## pitch rate
	var fuel_flow_pph := 0.0


var spec: Aircraft.Spec
var mass: MassData
var fdm: FlightDynamics
var dt: float
var n_engines: int
var n_gear: int
var controls := Controls.new()
var _accum := 0.0
var sim_time := 0.0
var last_touchdown_fpm := 0.0
var touchdowns := 0
var crash_reason = null  ## String or null
var _prev_ground := true
var _has_rpm: bool
var _has_steer: bool
# bound property handles for the hot path


func _init(spec_: Aircraft.Spec, root: String, mass_: MassData) -> void:
	spec = spec_
	mass = mass_
	fdm = FlightDynamics.new()
	if not fdm.load_model(root, spec.jsbsim_model):
		push_error("FlightDynamics failed to load " + spec.jsbsim_model)
	for st in spec.stations:
		fdm.stations.append({"loc": Vector3(st.x_in, st.y_in, st.z_in), "lb": 0.0})
	dt = fdm.dt
	n_engines = maxi(1, fdm.engines.size())
	n_gear = fdm.contacts.filter(func(c): return c.bogey).size()
	_has_rpm = not fdm.engines.is_empty()
	_has_steer = fdm.contacts.any(func(c): return c.steer != 0.0)


# ------------------------------------------------------------------ setup
func has(prop: String) -> bool:
	return fdm.has_property(prop)


func apply_loadout(lo: Loadout) -> void:
	var sw := lo.station_weights()
	for i in mini(sw.size(), fdm.stations.size()):
		fdm.stations[i].lb = sw[i]
	var tf := lo.tank_fuel()
	for i in mini(tf.size(), fdm.tanks.size()):
		fdm.tanks[i].lb = tf[i]
	fdm._update_mass()


func spawn(x: float, y: float, heading_deg: float, terrain_m: float, loadout: Loadout,
		airborne_alt_m = null, speed_kts := 0.0) -> void:
	apply_loadout(loadout)
	fdm.terrain_ft = terrain_m / FT
	var h_ft: float = (terrain_m / FT + mass.gear_height_ft + 0.2) if airborne_alt_m == null else float(airborne_alt_m) / FT
	fdm.set_state(y / FT, x / FT, h_ft, deg_to_rad(heading_deg), 0.0, 0.0, speed_kts * KT / FT)
	start_engines()
	_prev_ground = airborne_alt_m == null
	last_touchdown_fpm = 0.0
	crash_reason = null
	_accum = 0.0


func start_engines() -> void:
	for e in fdm.engines:
		e.running = true
		e.rpm = maxf(e.rpm, e.idlerpm / e.gear if e.type == "piston_engine" else e.minrpm * 0.9)


# ------------------------------------------------------------------ loop
func _controls() -> Dictionary:
	var c := controls
	var d := {"fcs/aileron-cmd-norm": c.aileron, "fcs/elevator-cmd-norm": c.elevator,
		# +rudder-cmd yaws the nose left in the aircraft data (FlightGear negates
		# it too); +steer-cmd turns the nosewheel right
		"fcs/rudder-cmd-norm": -c.rudder, "fcs/flap-cmd-norm": c.flaps, "fcs/pitch-trim-cmd-norm": c.pitch_trim,
		"fcs/throttle-cmd-norm": c.throttle, "fcs/steer-cmd-norm": c.rudder if _has_steer else 0.0}
	for i in n_engines:
		d["fcs/throttle-cmd-norm[%d]" % i] = c.throttle
		d["fcs/mixture-cmd-norm[%d]" % i] = 1.0
	var left := minf(1.0, c.brake + maxf(0.0, -c.diff_brake))
	var right := minf(1.0, c.brake + maxf(0.0, c.diff_brake))
	if spec.toe_brake_steering and _prev_ground:
		# no steerable nosewheel in the model: pedals feed differential braking
		left = maxf(left, -c.rudder * 0.35)
		right = maxf(right, c.rudder * 0.35)
	d["fcs/left-brake-cmd-norm"] = left
	d["fcs/right-brake-cmd-norm"] = right
	d["fcs/center-brake-cmd-norm"] = c.brake
	return d


## Advance the flight model by frame_dt seconds of real time in fixed sub-steps.
## terrain_at: Callable(x, y) -> ground height m.
func step(frame_dt: float, terrain_at: Callable) -> FlightState:
	var ctl := _controls()
	_accum += minf(frame_dt, 0.1)
	while _accum >= dt and crash_reason == null:
		var p := position_xy()
		var ground_ft: float = terrain_at.call(p[0], p[1]) / FT
		# Rising terrain arrives as a step in the flat ground plane under the
		# aircraft; if it would bury the gear, that is controlled flight into
		# terrain, not something the gear springs should resolve.
		if fdm.h - ground_ft < mass.gear_height_ft * 0.5:
			crash_reason = "Flew into terrain"
			break
		fdm.terrain_ft = ground_ft
		var vs := -fdm.v_ned().z * 60.0
		fdm.run(ctl)
		sim_time += dt
		_accum -= dt
		var ground := wow_count() > 0
		if ground and not _prev_ground:
			last_touchdown_fpm = vs
			touchdowns += 1
		_prev_ground = ground
	return state()


# ------------------------------------------------------------------ read
func position_xy() -> Array:
	return [fdm.east * FT, fdm.north * FT]


func wow_count() -> int:
	return fdm.wow_count()


func fuel_lb() -> float:
	return fdm.fuel_total()


func fuel_flow_pph() -> float:
	var total := 0.0
	for e in fdm.engines:
		total += e.flow_pps
	return total * 3600.0


## Pour fuel into the wing tanks (ferry transfer). Returns what fit.
func add_fuel(lb: float) -> float:
	var added := 0.0
	var caps: Array = mass.tanks
	for i in mini(caps.size(), fdm.tanks.size()):
		if lb - added <= 0:
			break
		var cur: float = fdm.tanks[i].lb
		var room := maxf(0.0, caps[i][1] - cur)
		var share := minf(room, (lb - added) if i == caps.size() - 1 else lb / caps.size())
		fdm.tanks[i].lb = cur + share
		added += share
	fdm._update_mass()
	return added


func wing_fuel_room() -> float:
	var s := 0.0
	for i in mini(mass.tanks.size(), fdm.tanks.size()):
		s += maxf(0.0, mass.tanks[i][1] - fdm.tanks[i].lb)
	return s


func state() -> FlightState:
	var s := FlightState.new()
	var p := position_xy()
	s.x = p[0]
	s.y = p[1]
	s.alt = fdm.h * FT
	var e := fdm.euler()
	var vn := fdm.v_ned()
	var vc: float = fdm.vt * sqrt(fdm.rho / FlightDynamics.RHO0) / FlightDynamics.KT_FPS
	s.valid = is_finite(s.alt) and is_finite(e.y) and is_finite(vc)
	var wow := wow_count()
	s.agl = (fdm.h - fdm.terrain_ft) * FT
	s.heading = fposmod(rad_to_deg(e.z), 360.0)
	s.pitch = rad_to_deg(e.y)
	s.roll = rad_to_deg(e.x)
	s.ias_kts = vc
	s.gs_kts = Vector2(vn.x, vn.y).length() * FT / KT
	s.vs_fpm = -vn.z * 60.0
	s.alpha_deg = rad_to_deg(fdm.alpha)
	s.stall_warning = s.alpha_deg > 15.0 and wow == 0
	s.on_ground = wow > 0
	s.wow_count = wow
	s.fuel_lb = fuel_lb()
	s.weight_lb = fdm.weight
	s.cg_in = fdm.cg.x
	if _has_rpm:
		var e0: Dictionary = fdm.engines[0]
		s.rpm = e0.rpm * (e0.gear if e0.type == "piston_engine" else 1.0)
		s.engine_running = e0.running
	s.vx = vn.y * FT
	s.vy = vn.x * FT
	s.p_dps = rad_to_deg(fdm.pqr.x)
	s.q_dps = rad_to_deg(fdm.pqr.y)
	s.fuel_flow_pph = fuel_flow_pph()
	return s
