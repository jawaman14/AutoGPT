class_name AISmuggler
extends RefCounted
## AI runner flights for the task-force side to hunt.
##
## A kinematic aircraft that comes in from the edge of the map at low level,
## flies to a drop point at sea, circles while kicking bales to a waiting boat,
## and runs for the map edge. It dives and turns away when it sees a police unit.

const KT := 0.514444

var id: String
var x: float
var y: float
var z: float
var heading: float
var drop_point: Array
var exit_point: Array
var job_id: int
var bales_left := 6
var speed := 140 * KT
var state := "inbound"  ## inbound | dropping | outbound | escaped | busted | crashed
var agl_target := 70.0
var evade_t := 0.0
var kick_t := 0.0
var orbit_t := 0.0
var vx := 0.0
var vy := 0.0
var squawk := ""
var hot := true  ## false: a decoy flying the same profile with nothing aboard
var kind := "ai"  ## ai (police-mode traffic) | crew (organisation contract run) | decoy


func _init(id_: String, x_: float, y_: float, z_: float, heading_: float, drop_point_: Array, exit_point_: Array,
		job_id_: int, opts := {}) -> void:
	id = id_
	x = x_
	y = y_
	z = z_
	heading = heading_
	drop_point = drop_point_
	exit_point = exit_point_
	job_id = job_id_
	for k in opts:
		set(k, opts[k])


func active() -> bool:
	return state in ["inbound", "dropping", "outbound"]


func signature(world: World) -> SensorNet.Signature:
	return SensorNet.Signature.new(id, x, y, z, z - world.ground(x, y), vx, vy, "air", false)


## drop_fn.call(job_id, x, y, z, vx, vy) spawns a bale. Returns a state transition name or "".
func update(dt: float, world: World, threats: Array, drop_fn: Callable) -> String:
	if not active():
		return ""
	var turn := 9.0
	var goal = null
	if state == "inbound":
		goal = drop_point
	elif state == "outbound":
		goal = exit_point
	# evasion: nearest threat within 4 km -> dive and break away
	var near = Py.min_by(threats, func(t): return PyMath.hypot(t[0] - x, t[1] - y))
	if near and PyMath.hypot(near[0] - x, near[1] - y) < 4000:
		evade_t = 20.0
	var desired: float
	var spd: float
	if evade_t > 0:
		evade_t -= dt
		agl_target = 35.0
		if near:
			var away := Py.degrees(atan2(x - near[0], y - near[1]))
			if goal:
				var to_goal := Py.degrees(atan2(goal[0] - x, goal[1] - y))
				desired = to_goal + Py.wrap180(away - to_goal) * 0.6
			else:
				desired = away
		else:
			desired = heading
		spd = 165 * KT
	elif state == "dropping":
		agl_target = 120.0
		desired = heading + 12.0  # standard-rate-ish orbit
		spd = 100 * KT
	else:
		agl_target = 70.0
		desired = Py.degrees(atan2(goal[0] - x, goal[1] - y))
		spd = 140 * KT
	var err := Py.wrap180(desired - heading)
	heading = fposmod(heading + maxf(-turn * dt, minf(turn * dt, err)), 360)
	speed += maxf(-5 * dt, minf(5 * dt, spd - speed))
	var h := Py.radians(heading)
	vx = sin(h) * speed
	vy = cos(h) * speed
	# terrain following with a 600 m look-ahead
	var ahead := -INF
	for t in [0.0, 3.0, 6.0, 10.0]:
		ahead = maxf(ahead, world.ground(x + vx * t, y + vy * t))
	var tz := ahead + agl_target
	z += maxf(-8 * dt, minf(10 * dt, tz - z))
	x += vx * dt
	y += vy * dt
	if z < world.ground(x, y) + 2:
		state = "crashed"
		return "crashed"
	if state == "inbound" and PyMath.hypot(drop_point[0] - x, drop_point[1] - y) < 500:
		state = "dropping"
		return "dropping"
	if state == "dropping":
		orbit_t += dt
		kick_t += dt
		if kick_t > 4.0 and bales_left > 0 and world.is_water(x, y):
			kick_t = 0.0
			bales_left -= 1
			drop_fn.call(job_id, x, y, z, vx, vy)
		if bales_left == 0 or orbit_t > 150:
			state = "outbound"
			return "outbound"
	if state == "outbound" and (absf(x) > World.HALF + 500 or absf(y) > World.HALF + 500):
		state = "escaped"
		return "escaped"
	return ""


## A point just outside the map on the south/east (where the flights came from) and an exit:
## [entry, exit, heading]
static func entry_and_exit(rng: PyRandom) -> Array:
	var half := World.HALF
	var side: String = rng.choice(["south", "east", "southeast"])
	var entry: Array
	if side == "south":
		entry = [rng.uniform(-half * 0.6, half * 0.6), -half - 400]
	elif side == "east":
		entry = [half + 400, rng.uniform(-half * 0.6, half * 0.3)]
	else:
		entry = [half + 200, -half - 200]
	# both candidates are drawn before the choice, as in the Python tuple
	var a := [rng.uniform(-half, half), -half - 800]
	var b := [half + 800, rng.uniform(-half, 0)]
	var exit_: Array = rng.choice([a, b])
	var heading := Py.fmod(Py.degrees(atan2(-entry[0], -entry[1])), 360)
	return [entry, exit_, heading]


## Spawns AI runs for the police-vs-AI mode.
class Director:
	var rng: PyRandom
	var first_at := 20.0
	var interval := 150.0
	var max_active := 2
	var next_t := 20.0
	var serial := 0

	func _init(rng_: PyRandom = null) -> void:
		rng = rng_ if rng_ != null else PyRandom.new()

	func due(now: float, active: int) -> bool:
		return now >= next_t and active < max_active

	func schedule_next(now: float) -> void:
		next_t = now + interval * rng.uniform(0.7, 1.3)
