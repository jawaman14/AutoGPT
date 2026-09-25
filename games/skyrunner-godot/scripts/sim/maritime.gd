class_name Maritime
extends RefCounted
## Airdrops, go-fast boats and Coast Guard cutters.
##
## The 1980s pattern: an aircraft never lands with the load. Kickers push bales
## out over open water, a go-fast boat fishes them out and runs for a cove, and
## the task force tries to catch the boat or seize the floating bales.

const KT := 0.514444
const G := 9.81
const BALE_TERMINAL_V := 35.0
const BALE_K := G / (BALE_TERMINAL_V * BALE_TERMINAL_V)
const CURRENT := [0.25, 0.08]  ## m/s surface drift
const PICKUP_RADIUS_M := 40.0
const PICKUP_TIME_S := 5.0
const SEIZE_RADIUS_M := 120.0
const SEIZE_TIME_S := 6.0
const SURFACE_RADAR_M := 7000.0
const BOAT_TYPES := {"gofast": 45.0, "cutter": 32.0}  ## max kts


static func is_sea(world: World, x: float, y: float, depth := -1.5) -> bool:
	return world.height(x, y) < depth


## Deep-ish water nearest Smuggler's Cove: where boats hand off the load.
static func cove_point(world: World) -> Array:
	var cov := World.airfield("COV")
	for r in range(300, 5000, 100):
		for k in 36:
			var a := 2 * PI * k / 36
			var x := cov.x + r * cos(a)
			var y := cov.y + r * sin(a)
			if is_sea(world, x, y, -4.0):
				return [x, y]
	return [cov.x + 2000, cov.y]


## Open water 1.5-8 km off the coast, inside the map.
static func random_drop_point(world: World, rng: PyRandom, near = null) -> Array:
	var half := World.HALF
	for i in 4000:
		var x: float
		var y: float
		if near != null:
			var a := rng.uniform(0, 2 * PI)
			var r := rng.uniform(3000, 12000)
			x = near[0] + r * cos(a)
			y = near[1] + r * sin(a)
		else:
			x = rng.uniform(-half + 1500, half - 1500)
			y = rng.uniform(-half + 1500, half - 1500)
		if absf(x) > half - 1500 or absf(y) > half - 1500 or not is_sea(world, x, y, -20.0):
			continue
		# not too far from land (boats have to reach it)
		for b in [0.0, PI / 2, PI, 3 * PI / 2]:
			if not is_sea(world, x + 8000 * cos(b), y + 8000 * sin(b)):
				return [x, y]
	return [0.0, -half + 2500]


class Bale:
	var id: int
	var job_id: int
	var x: float
	var y: float
	var z: float
	var vx: float
	var vy: float
	var vz := 0.0
	var weight_lb := 60.0
	var state := "falling"  ## falling | floating | landed | collected | seized | sunk
	var t_state := 0.0

	## Returns the new state on a transition, else "".
	func update(dt: float, world: World) -> String:
		t_state += dt
		if state == "falling":
			var n := maxi(1, int(dt / 0.02))
			var h := dt / n
			for i in n:
				var v := sqrt(vx * vx + vy * vy + vz * vz)
				vx -= BALE_K * v * vx * h
				vy -= BALE_K * v * vy * h
				vz += (-G - BALE_K * v * vz) * h
				x += vx * h
				y += vy * h
				z += vz * h
				var surface := world.ground(x, y)
				if z <= surface:
					z = surface
					vx = 0.0
					vy = 0.0
					vz = 0.0
					state = "floating" if world.is_water(x, y) else "landed"
					t_state = 0.0
					return state
		elif state == "floating":
			x += CURRENT[0] * dt
			y += CURRENT[1] * dt
			if t_state > 1200:  # waterlogged, gone
				state = "sunk"
				return state
		return ""


class Boat:
	var id: String
	var kind: String  ## gofast | cutter
	var x: float
	var y: float
	var heading := 0.0
	var speed := 0.0  ## m/s
	var state := "standby"
	var goal = null
	var home := [0.0, 0.0]
	var cargo: Array = []  ## bale ids aboard
	var job_id = null
	var work_t := 0.0
	var seize_meter := 0.0
	var wait_t := 0.0
	var target_id = null  ## cutters: boat being chased

	func _init(id_: String, kind_: String, x_: float, y_: float, opts := {}) -> void:
		id = id_
		kind = kind_
		x = x_
		y = y_
		for k in opts:
			set(k, opts[k])

	func side() -> String:
		return "law" if kind == "cutter" else "runner"

	func max_speed() -> float:
		return BOAT_TYPES[kind] * KT

	## Head for goal while keeping to water. Returns remaining distance.
	func steer(dt: float, world: World, goal_: Array, speed_frac := 1.0) -> float:
		var gx: float = goal_[0]
		var gy: float = goal_[1]
		var dist := PyMath.hypot(gx - x, gy - y)
		var desired := Py.degrees(atan2(gx - x, gy - y))
		var best = null
		for off in [0, 20, -20, 40, -40, 60, -60, 90, -90, 120, -120, 150, -150, 180]:
			var h := Py.radians(desired + off)
			var ok := true
			for r in [60, 200, 400]:
				if not Maritime.is_sea(world, x + sin(h) * r, y + cos(h) * r):
					ok = false
					break
			if ok:
				best = desired + off
				break
		var want := speed_frac * max_speed() if dist > 30 else 0.0
		if best == null:  # boxed in: stop and turn around
			best = heading + 90
			want = 2.0
		var err := Py.wrap180(best - heading)
		heading = fposmod(heading + maxf(-25 * dt, minf(25 * dt, err)), 360)
		speed += maxf(-4 * dt, minf(3 * dt, want - speed))
		var hh := Py.radians(heading)
		var nx := x + sin(hh) * speed * dt
		var ny := y + cos(hh) * speed * dt
		if Maritime.is_sea(world, nx, ny, -0.5):
			x = nx
			y = ny
		else:
			speed = 0.0
		return dist

	var vx: float:
		get:
			return sin(Py.radians(heading)) * speed

	var vy: float:
		get:
			return cos(Py.radians(heading)) * speed


var world: World
var rng: PyRandom
var boats: Array = []
var bales: Array = []
var events: Array = []  ## [[kind, data]]
var boats_return := true  ## a go-fast that fled empty goes back out once the cutter's gone (Godot-only)
var cove: Array
var cg_station: Array
var _serial := 0
var _bale_serial := 0


func _init(world_: World, rng_: PyRandom = null) -> void:
	world = world_
	rng = rng_ if rng_ != null else PyRandom.new()
	cove = cove_point(world)
	var har := World.airfield("HAR")
	cg_station = []
	for r in range(300, 6000, 100):
		for k in 24:
			var a := 2 * PI * k / 24
			if is_sea(world, har.x + r * cos(a), har.y + r * sin(a), -4.0):
				cg_station = [har.x + r * cos(a), har.y + r * sin(a)]
				break
		if not cg_station.is_empty():
			break


# ------------------------------------------------------------ spawning
func new_gofast(rendezvous: Array, job_id: int) -> Boat:
	_serial += 1
	var b := Boat.new("LadyLuck-%d" % _serial, "gofast", cove[0], cove[1], {"home": cove, "job_id": job_id,
		"goal": rendezvous, "state": "to_rendezvous"})
	boats.append(b)
	return b


## A Coast Guard cutter, from the station or already on picket at `at`.
func new_cutter(goal = null, at = null) -> Boat:
	_serial += 1
	var p: Array = at if at != null else cg_station
	var g = goal if goal != null else (at if at != null else null)
	var b := Boat.new("Cutter-%d" % _serial, "cutter", p[0], p[1], {"home": cg_station, "goal": g,
		"state": "patrol" if (goal != null or at != null) else "standby"})
	boats.append(b)
	return b


func drop_bale(job_id: int, x: float, y: float, z: float, vx: float, vy: float, vz: float, weight_lb: float) -> Bale:
	_bale_serial += 1
	var b := Bale.new()
	b.id = _bale_serial
	b.job_id = job_id
	b.x = x
	b.y = y
	b.z = z
	b.vx = vx
	b.vy = vy
	b.vz = vz
	b.weight_lb = weight_lb
	bales.append(b)
	return b


func boat(boat_id) -> Boat:
	return Py.first(boats, func(b): return b.id == boat_id)


func gofast_for(job_id: int) -> Boat:
	return Py.first(boats, func(b): return b.kind == "gofast" and b.job_id == job_id)


# ------------------------------------------------------------ tick
func update(dt: float, law_goals: Array = []) -> void:
	for bale in bales:
		var nw: String = bale.update(dt, world)
		if nw == "landed":
			events.append(["bale_lost", {"bale": bale.id, "job_id": bale.job_id, "why": "landed on land"}])
		elif nw == "floating":
			events.append(["bale_splash", {"bale": bale.id, "job_id": bale.job_id, "x": bale.x, "y": bale.y}])
		elif nw == "sunk":
			events.append(["bale_lost", {"bale": bale.id, "job_id": bale.job_id, "why": "sank"}])
	var floating := bales.filter(func(b): return b.state == "floating")
	for b in boats.duplicate():
		if b.kind == "gofast":
			_gofast(b, dt, floating)
		else:
			_cutter(b, dt, floating, law_goals)
	bales = bales.filter(func(b): return b.state in ["falling", "floating"] or b.t_state < 5)


func _gofast(b: Boat, dt: float, floating: Array) -> void:
	if b.state in ["seized", "delivered"]:
		return
	var mine := floating.filter(func(bl): return bl.job_id == b.job_id)
	# a cutter close by? run for it
	var cutters := boats.filter(func(c): return c.kind == "cutter" and c.state != "standby")
	var threat: Boat = Py.min_by(cutters, func(c): return PyMath.hypot(c.x - b.x, c.y - b.y))
	if threat and PyMath.hypot(threat.x - b.x, threat.y - b.y) < 2500 and b.state != "fleeing":
		b.state = "fleeing"
		events.append(["boat_fleeing", {"boat": b.id}])
	if b.state == "fleeing":
		b.steer(dt, world, cove)
		# nothing aboard yet: hide, then go back for the drop (Python ran home and
		# "delivered" 0 bales, which closed the job before the plane arrived)
		var empty_handed: bool = boats_return and b.cargo.is_empty() and b.goal != null
		if threat == null or PyMath.hypot(threat.x - b.x, threat.y - b.y) > 5000:
			if empty_handed and mine.is_empty():
				b.state = "to_rendezvous"
				events.append(["boat_returning", {"boat": b.id}])
			else:
				b.state = "collecting" if not mine.is_empty() else "running"
		elif PyMath.hypot(cove[0] - b.x, cove[1] - b.y) < 80 and not empty_handed:
			_deliver(b)
		return
	if b.state == "to_rendezvous":
		if b.steer(dt, world, b.goal, 1.0) < 150:
			b.state = "waiting"
	elif b.state == "waiting":
		b.wait_t += dt
		b.steer(dt, world, b.goal, 0.0)
		if not mine.is_empty():
			b.state = "collecting"
		elif b.wait_t > 900:
			b.state = "running"
	if b.state == "collecting":
		if mine.is_empty():
			b.state = "running" if not b.cargo.is_empty() else "waiting"
			return
		var tgt: Bale = Py.min_by(mine, func(bl): return PyMath.hypot(bl.x - b.x, bl.y - b.y))
		var d := b.steer(dt, world, [tgt.x, tgt.y], 0.6)
		if d < PICKUP_RADIUS_M:
			b.work_t += dt
			if b.work_t >= PICKUP_TIME_S:
				b.work_t = 0.0
				tgt.state = "collected"
				b.cargo.append(tgt.id)
				events.append(["bale_collected", {"boat": b.id, "job_id": b.job_id, "bale": tgt.id}])
	elif b.state == "running":
		if b.steer(dt, world, cove) < 80:
			_deliver(b)


func _deliver(b: Boat) -> void:
	b.state = "delivered"
	events.append(["bales_delivered", {"boat": b.id, "job_id": b.job_id, "count": b.cargo.size()}])


func _cutter(c: Boat, dt: float, floating: Array, law_goals: Array) -> void:
	if c.state == "standby":
		if not law_goals.is_empty():
			c.goal = law_goals.back()
			c.state = "patrol"
		else:
			return
	# surface radar: nearest runner boat still at sea
	var runners := boats.filter(func(b): return b.kind == "gofast" and not (b.state in ["seized", "delivered"]))
	var seen := runners.filter(func(b): return PyMath.hypot(b.x - c.x, b.y - c.y) < SURFACE_RADAR_M)
	if not seen.is_empty():
		var tgt: Boat = Py.min_by(seen, func(b): return PyMath.hypot(b.x - c.x, b.y - c.y))
		if c.target_id != tgt.id:
			c.target_id = tgt.id
			events.append(["cutter_contact", {"cutter": c.id, "boat": tgt.id, "x": tgt.x, "y": tgt.y}])
		var d := c.steer(dt, world, [tgt.x + tgt.vx * 20, tgt.y + tgt.vy * 20])
		if d < SEIZE_RADIUS_M:
			tgt.seize_meter += dt
			if tgt.seize_meter >= SEIZE_TIME_S:
				tgt.state = "seized"
				events.append(["boat_seized", {"boat": tgt.id, "job_id": tgt.job_id, "count": tgt.cargo.size(), "cutter": c.id}])
		else:
			tgt.seize_meter = maxf(0.0, tgt.seize_meter - dt)
		return
	c.target_id = null
	var near := floating.filter(func(bl): return PyMath.hypot(bl.x - c.x, bl.y - c.y) < SURFACE_RADAR_M * 0.6)
	if not near.is_empty():
		var bl: Bale = Py.min_by(near, func(bl): return PyMath.hypot(bl.x - c.x, bl.y - c.y))
		if c.steer(dt, world, [bl.x, bl.y], 0.7) < 60:
			c.work_t += dt
			if c.work_t > 3.0:
				c.work_t = 0.0
				bl.state = "seized"
				events.append(["bale_seized", {"cutter": c.id, "job_id": bl.job_id, "bale": bl.id}])
		return
	if c.goal != null:
		if c.steer(dt, world, c.goal, 0.8) < 200:
			c.goal = null
	elif c.state == "return" or law_goals.is_empty():
		if c.steer(dt, world, c.home, 0.5) < 100:
			c.state = "standby"
	else:
		c.goal = law_goals.back()
