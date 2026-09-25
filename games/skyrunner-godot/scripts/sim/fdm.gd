class_name FlightModel
extends RefCounted
## Game-facing wrapper around one JSBSim FGFDMExec (JSBSimFDM, native).
##
## World frame: x = east (m), y = north (m), z = up (m ASL). JSBSim works in
## geodetic lat/lon on WGS84; the play area maps onto a small patch around
## (LAT0, LON0) where a local tangent plane is accurate to well under a metre.

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
	var elevator := 0.0  ## -1 nose up .. +1 nose down (JSBSim convention)
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
	var agl: float  ## CG height above the terrain JSBSim sees, m
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
var fdm: JSBSimFDM
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
var _flow_props: Array = []
# bound property handles for the hot path
var _h := {}


func _init(spec_: Aircraft.Spec, root: String, mass_: MassData) -> void:
	spec = spec_
	mass = mass_
	fdm = JSBSimFDM.new()
	fdm.setup(root)
	fdm.set_debug_level(0)
	if not fdm.load_model(spec.jsbsim_model):
		push_error("JSBSim failed to load " + spec.jsbsim_model)
	dt = fdm.get_delta_t()
	n_engines = maxi(1, _count("propulsion/engine[%d]/set-running"))
	n_gear = _count("gear/unit[%d]/WOW")
	_has_rpm = has("propulsion/engine/engine-rpm")
	_has_steer = has("fcs/steer-cmd-norm")
	for i in n_engines:
		var p := "propulsion/engine[%d]/fuel-flow-rate-pps" % i
		if has(p):
			_flow_props.append(p)
	for p in ["position/lat-geod-deg", "position/long-gc-deg", "position/h-sl-ft", "velocities/v-down-fps",
			"position/terrain-elevation-asl-ft", "propulsion/total-fuel-lbs"]:
		_h[p] = fdm.bind(p)
	for i in n_gear:
		_h["wow%d" % i] = fdm.bind("gear/unit[%d]/WOW" % i)


# ------------------------------------------------------------------ setup
func _count(pattern: String) -> int:
	var n := 0
	while fdm.has_property(pattern % n):
		n += 1
	return n


func has(prop: String) -> bool:
	return fdm.has_property(prop)


func apply_loadout(lo: Loadout) -> void:
	var sw := lo.station_weights()
	for i in sw.size():
		fdm.set_property("inertia/pointmass-weight-lbs[%d]" % i, sw[i])
	var tf := lo.tank_fuel()
	for i in tf.size():
		fdm.set_property("propulsion/tank[%d]/contents-lbs" % i, tf[i])


func spawn(x: float, y: float, heading_deg: float, terrain_m: float, loadout: Loadout,
		airborne_alt_m = null, speed_kts := 0.0) -> void:
	var ll := xy_to_latlon(x, y)
	fdm.set_property("ic/lat-geod-deg", ll[0])
	fdm.set_property("ic/long-gc-deg", ll[1])
	fdm.set_property("ic/terrain-elevation-ft", terrain_m / FT)
	if airborne_alt_m == null:
		fdm.set_property("ic/h-agl-ft", mass.gear_height_ft + 0.2)
	else:
		fdm.set_property("ic/h-sl-ft", airborne_alt_m / FT)
	fdm.set_property("ic/psi-true-deg", heading_deg)
	fdm.set_property("ic/theta-deg", 0.0)
	fdm.set_property("ic/phi-deg", 0.0)
	fdm.set_property("ic/u-fps", speed_kts * KT / FT)
	fdm.set_property("ic/v-fps", 0.0)
	fdm.set_property("ic/w-fps", 0.0)
	fdm.set_property("ic/p-rad_sec", 0.0)
	fdm.set_property("ic/q-rad_sec", 0.0)
	fdm.set_property("ic/r-rad_sec", 0.0)
	apply_loadout(loadout)
	fdm.run_ic()
	apply_loadout(loadout)  # run_ic may reset tank contents from the XML
	start_engines()
	_prev_ground = airborne_alt_m == null
	last_touchdown_fpm = 0.0
	crash_reason = null
	_accum = 0.0


func start_engines() -> void:
	fdm.set_property("propulsion/magneto_cmd", 3)
	fdm.set_property("propulsion/starter_cmd", 1)
	for i in n_engines:
		fdm.set_property("fcs/mixture-cmd-norm[%d]" % i, 1.0)
		fdm.set_property("fcs/advance-cmd-norm[%d]" % i, 1.0)
	fdm.set_property("propulsion/set-running", -1)


# ------------------------------------------------------------------ loop
func _push_controls() -> void:
	var c := controls
	fdm.set_property("fcs/aileron-cmd-norm", c.aileron)
	fdm.set_property("fcs/elevator-cmd-norm", c.elevator)
	# JSBSim: +rudder-cmd yaws nose left (FlightGear negates it too),
	# +steer-cmd turns the nosewheel right.
	fdm.set_property("fcs/rudder-cmd-norm", -c.rudder)
	fdm.set_property("fcs/flap-cmd-norm", c.flaps)
	fdm.set_property("fcs/pitch-trim-cmd-norm", c.pitch_trim)
	for i in n_engines:
		fdm.set_property("fcs/throttle-cmd-norm[%d]" % i, c.throttle)
	var left := minf(1.0, c.brake + maxf(0.0, -c.diff_brake))
	var right := minf(1.0, c.brake + maxf(0.0, c.diff_brake))
	if spec.toe_brake_steering and _prev_ground:
		# no steerable nosewheel in the model: pedals feed differential braking
		left = maxf(left, -c.rudder * 0.35)
		right = maxf(right, c.rudder * 0.35)
	fdm.set_property("fcs/left-brake-cmd-norm", left)
	fdm.set_property("fcs/right-brake-cmd-norm", right)
	fdm.set_property("fcs/center-brake-cmd-norm", c.brake)
	if _has_steer:
		fdm.set_property("fcs/steer-cmd-norm", c.rudder)


## Advance the FDM by frame_dt seconds of real time using fixed JSBSim sub-steps.
## terrain_at: Callable(x, y) -> ground height m.
func step(frame_dt: float, terrain_at: Callable) -> FlightState:
	_push_controls()
	_accum += minf(frame_dt, 0.1)
	var h_sl: int = _h["position/h-sl-ft"]
	var h_vd: int = _h["velocities/v-down-fps"]
	var h_te: int = _h["position/terrain-elevation-asl-ft"]
	while _accum >= dt and crash_reason == null:
		var p := position_xy()
		var ground_ft: float = terrain_at.call(p[0], p[1]) / FT
		# Rising terrain arrives as a step in JSBSim's flat-earth ground plane;
		# if it would bury the gear, that is controlled flight into terrain,
		# not something the gear springs should resolve.
		if fdm.get_bound(h_sl) - ground_ft < mass.gear_height_ft * 0.5:
			crash_reason = "Flew into terrain"
			break
		fdm.set_bound(h_te, ground_ft)
		var vs := -fdm.get_bound(h_vd) * 60.0
		fdm.run()
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
	return latlon_to_xy(fdm.get_bound(_h["position/lat-geod-deg"]), fdm.get_bound(_h["position/long-gc-deg"]))


func wow_count() -> int:
	var n := 0
	for i in n_gear:
		if fdm.get_bound(_h["wow%d" % i]) > 0.5:
			n += 1
	return n


func fuel_lb() -> float:
	return fdm.get_bound(_h["propulsion/total-fuel-lbs"])


func fuel_flow_pph() -> float:
	var total := 0.0
	for p in _flow_props:
		var v := fdm.get_property(p)
		total += v if is_finite(v) else 0.0
	return total * 3600.0


## Pour fuel into the wing tanks (ferry transfer). Returns what fit.
func add_fuel(lb: float) -> float:
	var added := 0.0
	var caps: Array = mass.tanks
	for i in caps.size():
		if lb - added <= 0:
			break
		var prop := "propulsion/tank[%d]/contents-lbs" % i
		var cur := fdm.get_property(prop)
		var room := maxf(0.0, caps[i][1] - cur)
		var share := minf(room, (lb - added) if i == caps.size() - 1 else lb / caps.size())
		fdm.set_property(prop, cur + share)
		added += share
	return added


func wing_fuel_room() -> float:
	var s := 0.0
	for i in mass.tanks.size():
		s += maxf(0.0, mass.tanks[i][1] - fdm.get_property("propulsion/tank[%d]/contents-lbs" % i))
	return s


func state() -> FlightState:
	var s := FlightState.new()
	var p := position_xy()
	s.x = p[0]
	s.y = p[1]
	s.alt = fdm.get_bound(_h["position/h-sl-ft"]) * FT
	var theta := fdm.get_property("attitude/theta-deg")
	var vc := fdm.get_property("velocities/vc-kts")
	s.valid = is_finite(s.alt) and is_finite(theta) and is_finite(vc)
	var rpm := fdm.get_property("propulsion/engine/engine-rpm") if _has_rpm else 0.0
	var wow := wow_count()
	s.agl = fdm.get_property("position/h-agl-ft") * FT
	s.heading = fdm.get_property("attitude/psi-deg")
	s.pitch = theta
	s.roll = fdm.get_property("attitude/phi-deg")
	s.ias_kts = vc
	s.gs_kts = fdm.get_property("velocities/vg-fps") * FT / KT
	s.vs_fpm = -fdm.get_bound(_h["velocities/v-down-fps"]) * 60.0
	s.alpha_deg = fdm.get_property("aero/alpha-deg")
	s.stall_warning = s.alpha_deg > 15.0 and wow == 0
	s.on_ground = wow > 0
	s.wow_count = wow
	s.fuel_lb = fuel_lb()
	s.weight_lb = fdm.get_property("inertia/weight-lbs")
	s.cg_in = fdm.get_property("inertia/cg-x-in")
	s.rpm = rpm if is_finite(rpm) else 0.0
	s.engine_running = bool(fdm.get_property("propulsion/engine/set-running"))
	s.vx = fdm.get_property("velocities/v-east-fps") * FT
	s.vy = fdm.get_property("velocities/v-north-fps") * FT
	s.p_dps = Py.degrees(fdm.get_property("velocities/p-rad_sec"))
	s.q_dps = Py.degrees(fdm.get_property("velocities/q-rad_sec"))
	s.fuel_flow_pph = fuel_flow_pph()
	return s
