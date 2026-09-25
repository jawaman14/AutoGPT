class_name PilotBot
extends RefCounted
## A pilot bot that flies the real JSBSim aircraft through the Session.
##
## It is not a cheat: it only reads what the pilot's instruments and eyes give
## (own state, the map, detector/scanner/spotter intel the crew has) and moves
## the same control surfaces a human does. That makes its results a fair probe
## of the rules: if it can't get a loaded Cessna out of the quarry, a human will
## struggle too; if it always escapes the police, the police are too weak.
##
## A small flight director (heading->bank->aileron, vertical speed->pitch->
## elevator, speed->throttle) under a phase machine:
##   wait_load -> takeoff -> climb -> enroute(leg) -> [drop] -> approach -> flare -> rollout -> done
## Approaches are planned against the terrain: both runway directions and a few
## glide angles are tried, and the first final approach that clears the ground wins.

const FT := 0.3048
const KT := 0.514444
const FPM := 0.00508  ## m/s per ft/min
const FINAL_HEIGHT_M := 320.0  ## height above the field where the final approach starts
const CLIMB_MPS := 3.5  ## climb rate the terrain planner assumes (loaded single, hot day)
const TREE_ALLOWANCE_M := 22.0
const CRUISE_FUEL_PPH := {"c172p": 55, "pa28": 55, "c182": 80, "c310": 170, "dhc6": 420}
const CRUISE_KTS := {"c172p": 110, "pa28": 115, "c182": 135, "c310": 180, "dhc6": 150}


static func _clamp(v: float, lo: float, hi: float) -> float:
	return lo if v < lo else (hi if v > hi else v)


static func bearing(x0: float, y0: float, x1: float, y1: float) -> float:
	return fposmod(Py.degrees(atan2(x1 - x0, y1 - y0)), 360.0)


class Leg:
	var kind: String  ## goto | drop | land
	var x: float
	var y: float
	var code = null  ## airfield for "land"
	var routed := false

	func _init(kind_: String, x_: float, y_: float, code_ = null) -> void:
		kind = kind_
		x = x_
		y = y_
		code = code_


class Approach:
	var af: Airfield
	var hdg: float  ## landing direction
	var aim: Array  ## touchdown aim point
	var elev: float
	var gamma: float  ## glide angle, deg
	var clear_m: float  ## worst terrain clearance under the path

	func _init(af_: Airfield, hdg_: float, aim_: Array, elev_: float, gamma_: float, clear_: float) -> void:
		af = af_
		hdg = hdg_
		aim = aim_
		elev = elev_
		gamma = gamma_
		clear_m = clear_

	## [distance to the aim point along the approach (+ = still to go), cross-track (+ = right)]
	func along_across(x: float, y: float) -> Array:
		var h := Py.radians(hdg)
		var ux := sin(h)
		var uy := cos(h)
		var dx: float = x - aim[0]
		var dy: float = y - aim[1]
		return [-(dx * ux + dy * uy), dx * uy - dy * ux]

	func point(dist: float) -> Array:
		var h := Py.radians(hdg)
		return [aim[0] - sin(h) * dist, aim[1] - cos(h) * dist]

	func path_alt(dist: float) -> float:
		return elev + tan(Py.radians(gamma)) * maxf(0.0, dist)


## Pick landing direction, aim point and glide angle so the final clears the
## terrain and tree lines, preferring shallow paths and aim points near the
## threshold. Over a tree line the aim point moves down the runway, as long as
## what's left of it still stops the aircraft (roll_m, with margin).
static func plan_approach(world: World, af: Airfield, gear_h: float, roll_m := 180.0) -> Approach:
	var elev := world.airfield_elev(af)
	var best: Approach = null
	var aims := [0.1, 0.18, 0.26, 0.34, 0.42].filter(func(f): return af.length * (1 - f) > roll_m * 1.25)
	if aims.is_empty():
		aims = [0.08]
	for gamma in [3.5, 4.5, 5.5, 6.5, 7.5, 8.5, 9.5]:
		var final_len := minf(5000.0, FINAL_HEIGHT_M / tan(Py.radians(gamma)))
		for frac in aims:
			for end in [0, 1]:
				var hdg: float = af.heading if end == 0 else fposmod(af.heading + 180, 360)
				var t: Array = af.threshold(end)
				var h := Py.radians(hdg)
				var aim_d := minf(maxf(25.0, af.length * frac), 150.0 + af.length * (frac - 0.1))
				var aim := [t[0] + sin(h) * aim_d, t[1] + cos(h) * aim_d]
				var ap := Approach.new(af, hdg, aim, elev + gear_h, gamma, 1e9)
				var worst := 1e9
				var d := aim_d + 10
				while d < final_len:
					var p := ap.point(d)
					var need := minf(25.0, 3.0 + (d - aim_d) * 0.035)  # wheels just clear the fence
					worst = minf(worst, ap.path_alt(d) - gear_h - world.obstacle_top(p[0], p[1], 30.0) - need)
					d += 20 if d < 800 else 60
				ap.clear_m = worst
				if worst >= 0:
					return ap
				if best == null or worst > best.clear_m:
					best = ap
	return best


## [takeoff heading, worst climb gradient needed] - the direction whose departure
## path is least blocked. Pits and tree lines make this matter.
static func plan_departure(world: World, af: Airfield, roll_m: float, prefer = null) -> Array:
	var elev := world.airfield_elev(af)
	var best = null
	for end in [0, 1]:
		var hdg: float = af.heading if end == 0 else fposmod(af.heading + 180, 360)
		var h := Py.radians(hdg)
		var s: Array = af.threshold(end)
		var worst := 0.0
		var x := roll_m + 20
		while x < 3000:
			var px: float = s[0] + sin(h) * x
			var py: float = s[1] + cos(h) * x
			if not af.contains(px, py, 4.0):
				var rise := maxf(0.0, world.obstacle_top(px, py, 25.0) - elev)
				worst = maxf(worst, (rise + 10.0) / maxf(150.0, x - roll_m))
			x += 20 if x < 800 else 80
		var facing: bool = prefer != null and absf(Py.wrap180(hdg - prefer)) < 90
		var score := worst - (0.02 if facing else 0.0)  # don't backtrack for nothing
		if best == null or score < best[2]:
			best = [hdg, worst, score]
	return [best[0], best[1]]


## Knobs that make bots differ (and let the sim probe tactics).
class BotStyle:
	var agl_m := 110.0  ## cruise height above the terrain
	var evade_agl_m := 60.0
	var cruise_throttle := 0.85
	var transponder_off := true  ## when carrying something hot
	var evade := true  ## duck and turn away from police it knows about
	var bank_limit := 30.0
	var skill := 1.0  ## <1 adds control noise / sloppier flares
	var route := true  ## plan valley routes (terrain masking) between legs
	var lookahead_s := 75.0  ## how far ahead the terrain planner starts climbing

	static func make(d := {}) -> BotStyle:
		var b := BotStyle.new()
		for k in d:
			b.set(k, d[k])
		return b


var python_drops := false  ## the Python bot's airdrop (500 m orbit, never aborts): parity replays only
var sess: Session
var legs: Array
var style: BotStyle
var role := Roles.PILOT
var phase := "wait_load"
var leg_i := 0
var pitch_base := 3.0
var elev_i := 0.0
var thr_i := 0.55
var t_phase := 0.0
var approach: Approach = null
var log: Array = []
var outcome = null
var evading := 0.0
var vy_kts: float
var vapp_kts: float
var gear_h: float
# state the Python version created lazily with getattr(self, ..., default)
var _pitch_cmd = null
var trim := 0.0
var slip := 0.0
var go_arounds := 0
var established := false
var taxi_turning := false
var taxi_goal := 0.0
var runway_hdg := 0.0
var departure_gradient := 0.0
var dep_af: Airfield = null
var _ta_key = null
var _ta_val := 0.0
var _sh_key = null
var _sh_val := 0.0


func _init(sess_: Session, legs_: Array, style_: BotStyle = null, role_ := Roles.PILOT) -> void:
	sess = sess_
	legs = legs_
	style = style_ if style_ != null else BotStyle.new()
	role = role_
	var spec := sess.spec
	vy_kts = spec.approach_kts * 1.15
	vapp_kts = spec.approach_kts
	gear_h = sess.fm.mass.gear_height_ft * FT


# ------------------------------------------------------------ helpers
func leg() -> Leg:
	return legs[leg_i] if leg_i < legs.size() else null


func _set_phase(p: String) -> void:
	phase = p
	t_phase = 0.0
	log.append([sess.time, p])


func _attitude(c: FlightModel.Controls, s: FlightModel.FlightState, dt: float, bank_t: float, pitch_t: float) -> void:
	c.aileron = _clamp(0.04 * (bank_t - s.roll) - 0.012 * s.p_dps, -0.7, 0.7)
	# rate-limit the pitch command: a smooth target doesn't pump the phugoid
	var prev: float = _pitch_cmd if _pitch_cmd != null else s.pitch
	if not (phase in ["flare", "takeoff"]):
		pitch_t = prev + _clamp(pitch_t - prev, -4.0 * dt, 4.0 * dt)
	_pitch_cmd = pitch_t
	var err := pitch_t - s.pitch
	elev_i = _clamp(elev_i - err * 0.02 * dt, -0.6, 0.6)
	# like a pilot: wind the steady push/pull into the trim wheel
	trim = _clamp(trim + elev_i * 0.4 * dt, -1.0, 1.0)
	elev_i -= elev_i * 0.4 * dt
	c.pitch_trim = trim
	c.elevator = _clamp(-0.07 * err + 0.03 * s.q_dps + elev_i, -0.9, 0.9)


func _bank_for(s: FlightModel.FlightState, hdg_t: float, limit = null) -> float:
	var lim: float = limit if limit else style.bank_limit
	return _clamp(Py.wrap180(hdg_t - s.heading) * 1.3, -lim, lim)


func _pitch_for_vs(s: FlightModel.FlightState, dt: float, vs_t: float, min_ias: float) -> float:
	var tas := maxf(20.0, s.ias_kts * KT)
	var gamma_t := Py.degrees(atan2(vs_t * FPM, tas))
	pitch_base = _clamp(pitch_base + (vs_t - s.vs_fpm) * 0.0009 * dt, -6.0, 12.0)
	var pitch_t := _clamp(pitch_base + gamma_t, -10.0, 14.0)
	if s.ias_kts < min_ias:  # trade height for speed rather than stall
		pitch_t = minf(pitch_t, s.pitch - (min_ias - s.ias_kts) * 0.6)
		pitch_base = minf(pitch_base, pitch_t)
	return pitch_t


## Speed on throttle; with vs_t it also feeds the climb/sink error (a crude
## total-energy controller: below the path and slow means more power).
func _throttle_for(s: FlightModel.FlightState, dt: float, ias_t: float, vs_t = null) -> float:
	var err := ias_t - s.ias_kts
	var vs_err := 0.0 if vs_t == null else _clamp(vs_t - s.vs_fpm, -800.0, 800.0)
	thr_i = _clamp(thr_i + (err * 0.006 + vs_err * 0.00012) * dt, 0.0, 1.0)
	return _clamp(thr_i + err * 0.035 + vs_err * 0.0006, 0.0, 1.0)


## max(heights_many(xs + ox, ys + oy), 0) along t, like the numpy original
func _ground_along(x0: float, y0: float, vx: float, vy: float, ts: PackedFloat64Array) -> PackedFloat64Array:
	var xs := PackedFloat64Array()
	var ys := PackedFloat64Array()
	xs.resize(ts.size())
	ys.resize(ts.size())
	for k in ts.size():
		xs[k] = x0 + vx * ts[k]
		ys[k] = y0 + vy * ts[k]
	var g := sess.world.heights_many(xs, ys)
	for k in g.size():
		g[k] = maxf(g[k], 0.0)
	return g


static func _arange(stop: float, step: float) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	var n := int(ceil(stop / step))
	for k in n:
		out.append(k * step)
	return out


## Altitude floor from the terrain ahead, allowing for how fast this aircraft
## can actually climb: a ridge 60 s out that needs more than CLIMB_MPS to top
## means start climbing now. Cached for 0.5 s.
func _terrain_ahead(s: FlightModel.FlightState, secs := 25.0) -> float:
	var key := [Py.round_int(sess.time * 2), secs]
	if _ta_key == key:
		return _ta_val
	var vx := s.vx
	var vy := s.vy
	if PyMath.hypot(vx, vy) < 10:
		var h := Py.radians(s.heading)
		vx = sin(h) * 50
		vy = cos(h) * 50
	var horizon := maxf(secs, style.lookahead_s) if secs >= 20 else secs
	var t := _arange(horizon + 0.1, 2.0)
	var g := _ground_along(s.x, s.y, vx, vy, t)
	# also a little either side: we'll be turning
	var px := -vy
	var py := vx
	var n := maxf(1e-6, PyMath.hypot(px, py))
	for side in [-1, 1]:
		var ox: float = px / n * 150 * side
		var oy: float = py / n * 150 * side
		var g2 := _ground_along(s.x + ox, s.y + oy, vx, vy, t)
		for k in g.size():
			g[k] = maxf(g[k], g2[k])
	var need_max := -INF
	var first3 := -INF
	for k in g.size():
		var gk := g[k] + (TREE_ALLOWANCE_M if g[k] > 6.0 else 0.0)  # forests don't show in the height map
		need_max = maxf(need_max, gk - CLIMB_MPS * t[k])
		if k < 3:
			first3 = maxf(first3, gk)
	_ta_key = key
	_ta_val = maxf(need_max, first3)
	return _ta_val


## Altitude needed now to clear the terrain on heading `hdg`, given CLIMB_MPS.
func _need_along(s: FlightModel.FlightState, hdg: float, horizon := 75.0) -> float:
	var sp := maxf(40.0, PyMath.hypot(s.vx, s.vy))
	var h := Py.radians(hdg)
	var vx := sin(h) * sp
	var vy := cos(h) * sp
	var t := _arange(horizon + 0.1, 2.5)
	var g := _ground_along(s.x, s.y, vx, vy, t)
	# the turn onto this heading swings us up to a turn radius sideways
	var r := sp * sp / (9.81 * tan(Py.radians(style.bank_limit)))
	for side in [-1.0, 1.0]:
		var ox: float = cos(h) * r * side
		var oy: float = -sin(h) * r * side
		var g2 := _ground_along(s.x + ox, s.y + oy, vx, vy, t)
		for k in g.size():
			g[k] = maxf(g[k], g2[k])
	var m := -INF
	for k in g.size():
		var gk := g[k] + (TREE_ALLOWANCE_M if g[k] > 6.0 else 0.0)
		m = maxf(m, gk - CLIMB_MPS * 0.8 * t[k])
	return m


## The heading nearest `desired` whose terrain we can out-climb; if none, the
## one with the lowest terrain (turn away from the ridge and climb).
func _safe_heading(s: FlightModel.FlightState, desired: float) -> float:
	var key := [Py.round_int(sess.time), Py.round_int(desired)]
	if _sh_key == key:
		return _sh_val
	var margin := s.alt - minf(style.agl_m, 80.0)
	var best := desired
	var best_need = null
	for off in [0, 20, -20, 40, -40, 60, -60, 90, -90, 120, -120, 150, -150, 180]:
		var hdg := fposmod(desired + off, 360)
		var need := _need_along(s, hdg)
		if need <= margin:
			best = hdg
			best_need = need
			break
		if best_need == null or need < best_need:
			best = hdg
			best_need = need
	_sh_key = key
	_sh_val = best
	return best


## [closest police unit the crew knows about [x, y, d] or null, detector level]
func _threat(s: FlightModel.FlightState) -> Array:
	var best = null
	for unit in sess.intel:
		var e: Array = sess.intel[unit]
		if e[0] <= sess.time:
			var d := PyMath.hypot(e[1] - s.x, e[2] - s.y)
			if best == null or d < best[2]:
				best = [e[1], e[2], d]
	for u in sess.police.units:  # what you can see out of the window
		if u.faction() == "police" and u.state != "crashed":
			var d := PyMath.hypot3(u.x - s.x, u.y - s.y, u.z - s.alt)
			if d < 4500 and (best == null or d < best[2]):
				best = [u.x, u.y, d]
	var det := sess.police.detector() if sess.gear.has("detector") else ""
	return [best, det]


# ------------------------------------------------------------ main
func step(dt: float) -> FlightModel.Controls:
	var s := sess.state
	t_phase += dt
	if sess.phase in ["crashed", "busted"]:
		outcome = sess.phase
		phase = "done"
		return null
	if phase == "done":
		return null
	var c := FlightModel.Controls.make({"flaps": 0.0, "throttle": 0.0})
	call("_p_" + phase, c, s, dt)
	return c


func _p_wait_load(c: FlightModel.Controls, s: FlightModel.FlightState, dt: float) -> void:
	c.brake = 1.0
	# a squawk that vanishes on radar is the classic tell: go dark on the ramp
	if sess_hot(sess) and style.transponder_off and sess.transponder:
		sess.command(role, "transponder", {"on": false})
	if not sess.loadout.busy():
		_begin_departure(s)


func _begin_departure(s: FlightModel.FlightState) -> void:
	var af: Airfield = sess.airfield if sess.airfield else sess.world.nearest_airfield(s.x, s.y)[0]
	var roll := sess.spec.est_landing_roll(s.weight_lb, sess.world.airfield_elev(af)) * 1.35
	var dep := plan_departure(sess.world, af, roll, s.heading)
	runway_hdg = dep[0]
	departure_gradient = dep[1]
	dep_af = af
	var along: float = af.to_local(s.x, s.y)[0]
	var facing := 1 if absf(Py.wrap180(s.heading - af.heading)) < 90 else -1
	var want := 1 if absf(Py.wrap180(runway_hdg - af.heading)) < 90 else -1
	# start of the takeoff run: the threshold behind us in the chosen direction
	var start_along := -want * (af.length / 2 - 12)
	if want == facing and absf(along - start_along) < 40:
		_set_phase("takeoff")
	else:
		taxi_goal = start_along
		_set_phase("taxi")


## Backtrack along the runway to the start of the takeoff run, then turn round
## onto the takeoff heading.
func _p_taxi(c: FlightModel.Controls, s: FlightModel.FlightState, dt: float) -> void:
	var af := dep_af
	var la := af.to_local(s.x, s.y)
	var along: float = la[0]
	var across: float = la[1]
	var to_go := taxi_goal - along
	if not taxi_turning:
		var dir_sign := 1 if to_go > 0 else -1
		var taxi_hdg: float = af.heading if dir_sign > 0 else fposmod(af.heading + 180, 360)
		var err := Py.wrap180(taxi_hdg - s.heading)
		if absf(err) > 90 and s.gs_kts < 1.0 and absf(to_go) >= 8:
			c.brake = 1.0
			if sess.turnaround_t <= 0:
				sess.command(role, "turn_around")
			return
		if absf(to_go) < 8:
			taxi_turning = true
			thr_i = 0.4
		else:
			var target_speed := 12.0 if absf(err) < 20 and absf(to_go) > 60 else 5.0
			# hug the left edge: the right-hand pivot at the end swings us back across
			var across_t := 0.0
			c.rudder = _clamp(0.06 * err - 0.05 * (across - across_t) * dir_sign, -1, 1)
			c.throttle = _clamp(0.25 + (target_speed - s.gs_kts) * 0.05, 0.0, 0.6)
			c.brake = 1.0 if s.gs_kts > target_speed + 3 else 0.0
			return
	# at the start of the run: stop, and push her round by hand if needed
	c.throttle = 0.0
	c.brake = 1.0
	if sess.turnaround_t > 0 or s.gs_kts > 1.0:
		return
	if absf(Py.wrap180(runway_hdg - s.heading)) > 90:
		sess.command(role, "turn_around")
		return
	taxi_turning = false
	_set_phase("takeoff")
	if t_phase > 300:
		_fail("stuck taxiing")


func _p_takeoff(c: FlightModel.Controls, s: FlightModel.FlightState, dt: float) -> void:
	var af: Airfield = dep_af
	if af == null:
		af = sess.airfield if sess.airfield else sess.world.nearest_airfield(s.x, s.y)[0]
	c.throttle = 1.0
	c.flaps = 0.33 if af.length < 600 else 0.0
	var across: float = af.to_local(s.x, s.y)[1]
	var hdg_err := Py.wrap180(runway_hdg - s.heading)
	var side := 1 if absf(Py.wrap180(af.heading - runway_hdg)) < 90 else -1
	c.rudder = _clamp(0.12 * hdg_err - 0.02 * across * side, -1, 1)
	var pitch_t := 0.0
	var short := af.length < 600
	var vr := sess.spec.rotate_kts * (0.88 if short else 1.0) * sqrt(maxf(0.6, s.weight_lb / sess.spec.mtow_lb))
	if s.ias_kts >= vr:
		pitch_t = ((11.0 if short else 9.0) if sess.spec.visual.engines == 1 else 7.0)
	if s.on_ground and pitch_t == 0.0:
		c.elevator = 0.0
		c.aileron = 0.0
	else:
		_attitude(c, s, dt, 0.0, pitch_t)
	if not s.on_ground and s.agl > 8:
		if sess_hot(sess) and style.transponder_off and sess.transponder:
			sess.command(role, "transponder", {"on": false})
		_set_phase("climb")
	if t_phase > 90:
		_fail("never got airborne")


func _p_climb(c: FlightModel.Controls, s: FlightModel.FlightState, dt: float) -> void:
	c.throttle = 1.0
	c.flaps = 0.33 if s.ias_kts < sess.spec.rotate_kts + 12 and s.agl < 60 else 0.0
	# obstacle climb at Vx until clear of the trees, then Vy
	var low := s.agl < 60
	var heavy := sqrt(maxf(0.6, s.weight_lb / sess.spec.mtow_lb))
	var v_climb := vapp_kts * 0.88 * heavy if low else vy_kts
	var pitch_t := _clamp(8.0 + (s.ias_kts - v_climb) * 0.5, 8.5 if s.agl < 30 else 0.0, 13.0)
	var lg := leg()
	var hdg_t := runway_hdg if s.agl < 60 else _safe_heading(s, bearing(s.x, s.y, lg.x, lg.y))
	_attitude(c, s, dt, _bank_for(s, hdg_t, 15 if s.agl < 100 else null), pitch_t)
	var want := _terrain_ahead(s) + style.agl_m
	if s.alt >= want - 10 and s.agl > 60:
		pitch_base = s.pitch
		_set_phase("enroute")


## Before a leg: thread a valley route to its entry point (the approach's
## intermediate fix for a landing) and insert it as waypoints.
func _route_to(s: FlightModel.FlightState, lg: Leg) -> void:
	var target := [lg.x, lg.y]
	if lg.kind == "land":
		var af := World.airfield(lg.code)
		var roll := sess.spec.est_landing_roll(s.weight_lb, sess.world.airfield_elev(af))
		approach = plan_approach(sess.world, af, gear_h, roll)
		target = approach.point(_if_dist(approach) + 800)
	var pts := RoutePlanner.plan_route(sess.world, [s.x, s.y], target)
	pts = pts.slice(0, pts.size() - 1)
	if Py.dist2([s.x, s.y], target) < 3000:
		pts = []
	var k := leg_i
	for p in pts:
		legs.insert(k, Leg.new("goto", p[0], p[1]))
		k += 1
	lg.routed = true


func _p_enroute(c: FlightModel.Controls, s: FlightModel.FlightState, dt: float) -> void:
	var lg := leg()
	if lg == null:
		_set_phase("done")
		return
	if style.route and lg.kind != "goto" and not lg.routed:
		_route_to(s, lg)
		lg = leg()
	var d := PyMath.hypot(lg.x - s.x, lg.y - s.y)
	var hdg_t := bearing(s.x, s.y, lg.x, lg.y)
	var agl := style.agl_m
	var throttle := style.cruise_throttle
	var th := _threat(s) if style.evade else [null, ""]
	var threat = th[0]
	if (threat and threat[2] < 5000) or th[1] == "LOCK":
		evading = 20.0
	if evading > 0:
		evading -= dt
		agl = style.evade_agl_m
		throttle = 1.0
		if threat:
			var away := bearing(threat[0], threat[1], s.x, s.y)
			hdg_t = hdg_t + Py.wrap180(away - hdg_t) * 0.6
	if lg.kind == "drop" and d < 3500:
		agl = 110.0
		throttle = 0.6
	hdg_t = _safe_heading(s, hdg_t)
	var alt_t := _terrain_ahead(s) + agl
	var vs_t := _clamp((alt_t - s.alt) * 12.0, -900.0, 1200.0)
	if alt_t - s.alt > 30:
		throttle = 1.0
	var pitch_t := _pitch_for_vs(s, dt, vs_t, vapp_kts * 1.1)
	_attitude(c, s, dt, _bank_for(s, hdg_t), pitch_t)
	c.throttle = throttle
	var turn_r := (s.ias_kts * KT) ** 2 / (9.81 * tan(Py.radians(style.bank_limit)))
	if lg.kind == "goto" and d < maxf(600.0, 1.5 * turn_r):
		leg_i += 1
	elif lg.kind == "drop" and d < 900:
		_set_phase("drop")
	elif lg.kind == "land":
		if approach == null:
			var af := World.airfield(lg.code)
			var roll := sess.spec.est_landing_roll(sess.state.weight_lb, sess.world.airfield_elev(af))
			approach = plan_approach(sess.world, af, gear_h, roll)
		var ap := approach
		var aa := ap.along_across(s.x, s.y)
		var along: float = aa[0]
		var across: float = aa[1]
		var ifp := ap.point(_if_dist(ap))
		if PyMath.hypot(ifp[0] - s.x, ifp[1] - s.y) < 700 or (0 < along and along < _if_dist(ap) + 500
				and absf(across) < 300 and absf(Py.wrap180(ap.hdg - s.heading)) < 45):
			established = false
			_set_phase("approach")
		else:
			# head for the intermediate fix on the extended centreline
			hdg_t = bearing(s.x, s.y, ifp[0], ifp[1])
			_attitude(c, s, dt, _bank_for(s, hdg_t), pitch_t)


func _p_drop(c: FlightModel.Controls, s: FlightModel.FlightState, dt: float) -> void:
	var lg := leg()
	var d := PyMath.hypot(lg.x - s.x, lg.y - s.y)
	var remaining := sess._droppables().size()
	# no airdrop job left (the boat's gone): nothing to drop to, head home with the load
	var abort: bool = not python_drops and not Py.any(sess.active_jobs, func(j): return j.is_airdrop())
	if (remaining == 0 or abort) and sess.kick_queue == 0:
		if sess.autopilot.engaged:
			sess.command(role, "autopilot", {"on": false})
		leg_i += 1
		_set_phase("enroute")
		return
	# orbit the rendezvous clockwise, 110 m above the water, ~95 kt. Python asked for a
	# 500 m circle, outside the 450 m kick radius, so most drops never happened; aim for
	# 250 m and the bank limit settles it near 400 m, inside the circle
	var r := 500.0 if python_drops else 250.0
	var tangent := bearing(lg.x, lg.y, s.x, s.y) + 90.0
	var hdg_t := tangent + _clamp((d - r) * 0.12, -60, 60)
	if d > 1500:
		hdg_t = bearing(s.x, s.y, lg.x, lg.y)
	var alt_t := _terrain_ahead(s, 10) + 110.0
	var vs_t := _clamp((alt_t - s.alt) * 12.0, -700.0, 900.0)
	var pitch_t := _pitch_for_vs(s, dt, vs_t, vapp_kts * 1.1)
	_attitude(c, s, dt, _bank_for(s, hdg_t), pitch_t)
	c.throttle = _throttle_for(s, dt, minf(95.0, vapp_kts * 1.45))
	if d < 450 and sess.kick_queue == 0 and not sess.copilot:
		# solo: autopilot on, go aft and kick them all
		if not sess.autopilot.engaged:
			sess.command(role, "autopilot", {"on": true})
		sess.command(role, "kick", {"count": remaining})
	if t_phase > 400:
		_fail("couldn't get the bales out")


static func _if_dist(ap: Approach) -> float:
	return minf(5000.0, FINAL_HEIGHT_M / tan(Py.radians(ap.gamma))) + 1500.0


func _p_approach(c: FlightModel.Controls, s: FlightModel.FlightState, dt: float) -> void:
	var ap := approach
	var aa := ap.along_across(s.x, s.y)
	var along: float = aa[0]
	var across: float = aa[1]
	var spec := sess.spec
	if absf(across) < 40:
		established = true
	var hdg_t := _track_centreline(s, ap, across, 25.0 if along > 1500 else 10.0)
	var bank_lim := 30.0 if along > 1500 else 15.0
	# vertical: follow the glide path once lined up, never below the terrain ahead
	var gp := ap.path_alt(along if established else maxf(along, _final_len(ap)))
	var floor_ := _terrain_ahead(s, 8) + 30.0 if along > 800 else -1e9
	var alt_t := maxf(gp, floor_) if along > 0 else ap.elev
	var gs_mps := maxf(25.0, s.gs_kts * KT)
	var on_path := alt_t == gp and established
	var vs_nom := -gs_mps * tan(Py.radians(ap.gamma)) / FPM if on_path else 0.0
	var vs_t := _clamp(vs_nom + (alt_t - s.alt) * 15.0, -1400.0, 900.0)
	# approach speed scales with sqrt(weight); short strips get the short-field number
	var heavy := sqrt(maxf(0.6, s.weight_lb / spec.mtow_lb))
	var vref := vapp_kts * heavy * (1.0 + (0.1 if along > 2500 else 0.0)) * (0.93 if ap.af.length < 500 else 1.0)
	var pitch_t := _pitch_for_vs(s, dt, vs_t, vapp_kts * heavy * 0.82)
	_attitude(c, s, dt, _bank_for(s, hdg_t, bank_lim), pitch_t)
	c.throttle = _throttle_for(s, dt, vref, vs_t)
	# too fast on a steep final with the power already off: forward slip
	# (crossed controls; the heading loop banks against the rudder)
	if c.throttle < 0.05 and along < 2000 and established:
		slip = _clamp(slip + (s.ias_kts - vref - 1.0) * 0.05 * dt, 0.0, 0.9)
	else:
		slip = maxf(0.0, slip - dt)
	c.rudder = slip
	if s.ias_kts < spec.max_flap_kts:
		c.flaps = 1.0 if along < 2200 else 0.66
	var wheels := s.alt - gear_h - (ap.elev - gear_h)  # above the runway, not the terrain below
	var sink := maxf(0.0, -s.vs_fpm * FPM)
	var flare_h := 1.0 + 0.9 * sink
	var ahead := []
	for k in [40.0, 80.0, 120.0]:
		if along - k > 0:
			var p := ap.point(along - k)
			if not ap.af.contains(p[0], p[1], 5.0):
				ahead.append(p)
	var cliff := -1e9
	for p in ahead:
		cliff = maxf(cliff, sess.world.obstacle_top(p[0], p[1], 20.0))
	if wheels < flare_h and along < 400 and cliff < s.alt - gear_h - 1.0:
		_set_phase("flare")
	elif cliff > s.alt - gear_h - 3.0 and along > 60:
		_go_around("low on the approach")
		return
	if along < -ap.af.length * 0.5 or (along < 900 and (absf(across) > 60 or s.alt - gp > 60)):
		_go_around("unstable approach")


func _final_len(ap: Approach) -> float:
	return minf(5000.0, FINAL_HEIGHT_M / tan(Py.radians(ap.gamma)))


## Heading that gives a sideways speed proportional to the cross-track error.
func _track_centreline(s: FlightModel.FlightState, ap: Approach, across: float, v_max: float) -> float:
	var gs := maxf(20.0, s.gs_kts * KT)
	var v_lat := _clamp(-across * 0.12, -v_max, v_max)
	return ap.hdg + Py.degrees(asin(_clamp(v_lat / gs, -0.7, 0.7)))


func _p_flare(c: FlightModel.Controls, s: FlightModel.FlightState, dt: float) -> void:
	var ap := approach
	var aa := ap.along_across(s.x, s.y)
	var along: float = aa[0]
	var across: float = aa[1]
	c.flaps = 1.0
	c.throttle = 0.0
	var wheels := s.alt - ap.elev
	var vs_t := -maxf(200.0, minf(350.0, wheels * 80.0))
	var pitch_t := _clamp(s.pitch + (vs_t - s.vs_fpm) * 0.012, -2.0, 12.0)
	_attitude(c, s, dt, _bank_for(s, _track_centreline(s, ap, across, 3.0), 8.0), pitch_t)
	c.rudder = _clamp(0.05 * Py.wrap180(ap.hdg - s.heading), -0.5, 0.5)
	if s.on_ground:
		_set_phase("rollout")
	elif along < -ap.af.length * 0.45:
		_go_around("floated long")


func _p_rollout(c: FlightModel.Controls, s: FlightModel.FlightState, dt: float) -> void:
	var ap := approach
	var across: float = ap.along_across(s.x, s.y)[1]
	c.flaps = 0.0 if t_phase > 0.2 else 1.0
	c.throttle = 0.0
	c.elevator = 0.0
	c.aileron = 0.0
	c.brake = 1.0 if t_phase > 0.3 else 0.0
	c.rudder = _clamp(0.12 * Py.wrap180(ap.hdg - s.heading) - 0.03 * across, -1, 1)
	if sess.phase == "parked" and s.gs_kts < 1.0:
		outcome = "landed"
		leg_i += 1
		approach = null
		if leg() == null:
			_set_phase("done")
		else:
			_begin_departure(s)
	elif not s.on_ground and s.agl > 4:
		_set_phase("flare")


func _go_around(why: String) -> void:
	log.append([sess.time, "go-around: " + why])
	go_arounds += 1
	if go_arounds > 3:
		_fail("too many go-arounds")
		return
	approach = null
	runway_hdg = sess.state.heading
	_set_phase("climb")


func _fail(why: String) -> void:
	outcome = "gave up: " + why
	log.append([sess.time, outcome])
	phase = "done"


## Fuel for the route plus a reserve: what a sensible pilot loads for a short
## strip, instead of brimming the tanks.
static func plan_fuel_lb(s: Session, lgs: Array, reserve_h := 0.6) -> float:
	var st := s.state
	var x := st.x
	var y := st.y
	var dist := 0.0
	for lg in lgs:
		dist += PyMath.hypot(lg.x - x, lg.y - y)
		x = lg.x
		y = lg.y
	var key := s.aircraft_key
	var hours: float = dist / 1852.0 / CRUISE_KTS.get(key, 110) * 1.3 + reserve_h \
		+ (0.15 if Py.any(lgs, func(l): return l.kind == "drop") else 0.0)
	return minf(s.loadout.mass.fuel_capacity_lb(), hours * CRUISE_FUEL_PPH.get(key, 60))


static func sess_hot(s: Session) -> bool:
	return Py.any(s.loadout.items.values(), func(i): return i.hot)


## Legs for one job: an airdrop goes to the boat then home, anything else flies
## to its destination.
static func mission_for(s: Session, job: Jobs.Job, home = null) -> Array:
	if job.is_airdrop():
		if home == null:
			home = s.location
		var af := World.airfield(home)
		return [Leg.new("drop", job.drop_point[0], job.drop_point[1]), Leg.new("land", af.x, af.y, home)]
	var af := World.airfield(job.dest)
	return [Leg.new("land", af.x, af.y, job.dest)]


## Run the session until the bot is done (headless). Returns the outcome.
static func fly(s: Session, bot: PilotBot, max_time := 1800.0, dt := 1.0 / 30, on_frame = null) -> String:
	var t_end := s.time + max_time
	while s.time < t_end:
		var c := bot.step(dt)
		if bot.phase == "done" and bot.outcome != null:
			break
		s.update(dt, null, c)
		if on_frame != null:
			on_frame.call(s)
	if bot.outcome == null:
		bot.outcome = "timeout"
	return bot.outcome
