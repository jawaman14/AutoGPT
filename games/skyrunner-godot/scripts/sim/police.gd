class_name PoliceSystem
extends RefCounted
## The task force: radar picture, suspicion/wanted per target, air units,
## tips, and the controller (AI or human) that ties it together.
##
## Air units are kinematic point masses with turn/climb/speed limits and a
## short terrain look-ahead - cheap, and deliberately imperfect: drag them
## through a canyon and they can fly into the wall. Units never read the true
## position of a target they can't see: they chase what they see, else the
## radar track, else fly to the last known position and search there.

const KT := 0.514444
#            max kts, turn deg/s, climb m/s, look-ahead m, faction
const UNIT_TYPES := {
	"heli": [120, 14.0, 7.0, 500.0, "police"],
	"interceptor": [230, 9.0, 15.0, 900.0, "police"],
	"rival": [170, 11.0, 9.0, 700.0, "rival"],
}
const ENDURANCE_S := {"heli": 900.0, "interceptor": 1200.0, "rival": 1e9}  # then bingo fuel, back to base
const CALLSIGNS := {"heli": "Hawk", "interceptor": "Falcon", "rival": "Rival", "cutter": "Cutter"}

const BUST_RANGE_M := 350.0
const RIVAL_RANGE_M := 250.0
const SIGHT_RANGE_M := 4500.0
const LANDING_BUST_RANGE_M := 2500.0
const SWEEP_INTERVAL_S := 1.0
const LAUNCH_DELAY_S := 6.0
const ENCRYPTION_DELAY_S := 8.0

# suspicion per second for a primary-only radar track (see _classify)
const PRIMARY_RATE := 1.2
const PRIMARY_RATE_NEAR := 3.0
const INBOUND_LOW_MULT := 2.5
const DROP_PATTERN_RATE := 3.0
const SUSPICION_DECAY := 3.0
const ODD_DESTINATION_SUSPICION := 100.0  ## shady strips: nobody legit goes there
const BUSH_DESTINATION_SUSPICION := 30.0  ## farm and bush strips get honest traffic too

const LAW_FEATURES := ["interceptors", "aerostat", "cutters", "encryption", "df", "informants", "rivals"]


static func _z(obj) -> float:
	return obj.alt if "alt" in obj else obj.z


class Pursuer:
	var kind: String
	var x: float
	var y: float
	var z: float
	var heading: float
	var home: Array
	var speed := 0.0  ## m/s
	var state := "pursuit"  ## pursuit | goto | search | return | crashed
	var sees_player := false
	var crashed_timer := 0.0
	var just_crashed := false
	var id := ""
	var target_id = null
	var goal = null
	var chatter_t := -1e9
	var had_visual := false
	var fuel_s := -1.0  ## seconds of flying left; set at launch
	var pilot = null  ## a human flying it (role name); null = AI
	var stick := [0.0, 0.0, 0.6]  ## roll, pitch (+ = climb), throttle
	var bank := 0.0  ## deg, for rendering and the human flight model

	func _init(kind_: String, x_: float, y_: float, z_: float, heading_: float, home_: Array, opts := {}) -> void:
		kind = kind_
		x = x_
		y = y_
		z = z_
		heading = heading_
		home = home_
		for k in opts:
			set(k, opts[k])

	func spec() -> Array:
		return UNIT_TYPES[kind]

	func faction() -> String:
		return UNIT_TYPES[kind][4]

	func dist_to(s) -> float:
		return PyMath.hypot3(x - s.x, y - s.y, z - PoliceSystem._z(s))

	## target: something with x, y, alt|z, vx, vy to intercept (seen or tracked).
	## goal: fly there and orbit when there's no target.
	func update(dt: float, target, world: World, goal_ = null) -> void:
		if state == "crashed":
			crashed_timer += dt
			return
		if fuel_s < 0:
			fuel_s = ENDURANCE_S[kind]
		fuel_s -= dt
		if pilot != null:
			_fly_manual(dt, world)
			return
		var sp := spec()
		var vmax: float = sp[0] * KT
		var turn: float = sp[1]
		var climb: float = sp[2]
		var look: float = sp[3]
		var orbit := false
		var tx: float
		var ty: float
		var tz: float
		var want_speed: float
		if target != null and state != "return":
			var d := PyMath.hypot(target.x - x, target.y - y)
			var lead := minf(8.0, d / maxf(vmax, 1.0))
			tx = target.x + target.vx * lead
			ty = target.y + target.vy * lead
			tz = PoliceSystem._z(target)
			# close to ~150 m formation, then match speed
			var tspeed := PyMath.hypot(target.vx, target.vy)
			want_speed = maxf(35.0, minf(vmax, tspeed + (d - 150.0) * 0.15))
		elif goal_ != null and state != "return":
			tx = goal_[0]
			ty = goal_[1]
			tz = world.ground(tx, ty) + 350
			want_speed = vmax * 0.75
			orbit = PyMath.hypot(tx - x, ty - y) < 700
		else:
			tx = home[0]
			ty = home[1]
			tz = world.ground(tx, ty) + 300
			want_speed = vmax * 0.7
		if orbit:
			heading = fposmod(heading + turn * 0.6 * dt, 360)
		else:
			var desired := Py.degrees(atan2(tx - x, ty - y))
			var err := Py.wrap180(desired - heading)
			heading = fposmod(heading + maxf(-turn * dt, minf(turn * dt, err)), 360)
		speed += maxf(-6 * dt, minf(6 * dt, want_speed - speed))
		# terrain look-ahead (only straight ahead: canyons can still catch them)
		var h := Py.radians(heading)
		var ax := x + sin(h) * look
		var ay := y + cos(h) * look
		var floor_ := maxf(world.ground(ax, ay), world.ground(x, y)) + 60
		tz = maxf(tz, floor_)
		var dz := maxf(-climb * dt, minf(climb * dt, tz - z))
		x += sin(h) * speed * dt
		y += cos(h) * speed * dt
		z += dz
		if z < world.ground(x, y) + 2 or world.tree_hit(x, y, z, 4):
			state = "crashed"
			just_crashed = true
			z = world.ground(x, y)

	## A human at the controls. Same envelope as the AI (speed, turn, climb
	## limits from UNIT_TYPES) so balance numbers from AI units still hold;
	## what a human adds is judgement, not performance.
	func _fly_manual(dt: float, world: World) -> void:
		var sp := spec()
		var vmax: float = sp[0] * KT
		var turn: float = sp[1]
		var climb: float = sp[2]
		var roll_in := maxf(-1.0, minf(1.0, stick[0]))
		var pitch_in := maxf(-1.0, minf(1.0, stick[1]))
		var thr := maxf(-1.0, minf(1.0, stick[2]))
		if kind == "heli":
			# helicopter: pedals/cyclic turn it on the spot, throttle is forward speed
			var want := maxf(0.0, thr) * vmax
			speed += maxf(-5 * dt, minf(5 * dt, want - speed))
			bank = roll_in * 20.0
			heading = fposmod(heading + roll_in * turn * dt, 360)
		else:
			var vmin := 0.35 * vmax
			var want := vmin + maxf(0.0, thr) * (vmax - vmin)
			speed += maxf(-6 * dt, minf(6 * dt, want - speed))
			var bank_t := roll_in * 60.0
			bank += maxf(-60 * dt, minf(60 * dt, bank_t - bank))
			var rate := Py.degrees(9.81 * tan(Py.radians(bank)) / maxf(speed, 30.0))
			heading = fposmod(heading + maxf(-turn * 1.4, minf(turn * 1.4, rate)) * dt, 360)
		var h := Py.radians(heading)
		x += sin(h) * speed * dt
		y += cos(h) * speed * dt
		z += pitch_in * climb * dt
		z = minf(z, 4000.0)
		if z < world.ground(x, y) + 2 or world.tree_hit(x, y, z, 4):
			state = "crashed"
			just_crashed = true
			pilot = null
			z = world.ground(x, y)

	var vx: float:
		get:
			return sin(Py.radians(heading)) * speed

	var vy: float:
		get:
			return cos(Py.radians(heading)) * speed


## A thing the task force might chase. `hot` is ground truth, used only for
## game outcomes (a bust on a clean aircraft finds nothing).
class Target:
	var sig: SensorNet.Signature
	var hot := false
	var value := 0
	var label := ""

	func _init(sig_: SensorNet.Signature, hot_ := false, value_ := 0, label_ := "") -> void:
		sig = sig_
		hot = hot_
		value = value_
		label = label_


class Case:
	var target_id: String
	var suspicion := 0.0
	var wanted := 0
	var bust_meter := 0.0
	var rival_meter := 0.0
	var seen_time := 0.0
	var unseen_time := 0.0
	var last_known = null  ## [x, y, t]
	var detected_by = null
	var identified_t := -1e9  ## last time we saw its transponder
	var squawk := ""
	var tipped := false
	var drop_alerted := false
	var odd_destination := {}  ## strips a squawking "legit" flight let down into
	var last_contact = null  ## [x, y, agl, vx, vy, squawking] at the last radar contact

	func _init(tid: String, opts := {}) -> void:
		target_id = tid
		for k in opts:
			set(k, opts[k])


class Tip:
	var t: float
	var x: float
	var y: float
	var radius: float
	var text: String
	var squawk := ""

	func _init(t_: float, x_: float, y_: float, radius_: float, text_: String, squawk_ := "") -> void:
		t = t_
		x = x_
		y = y_
		radius = radius_
		text = text_
		squawk = squawk_


var world: World
var rng: PyRandom
var radio: RadioNet
var controller := "ai"  ## ai | human
var features := {"interceptors": true, "rivals": true}
var stock := {"heli": 1, "interceptor": 2, "cutter": 1}
var units: Array = []
var cases := {}
var tips: Array = []
var events: Array = []  ## runner-facing messages
var law_events: Array = []  ## controller-facing messages
var score := {"busts": 0, "clean_stops": 0, "bales_seized": 0, "boats_seized": 0}
var no_customs := false  ## the tower chief is on the organisation's payroll tonight
var sensors: SensorNet
var detections := {}
var _launches: Array = []
var _sweep_acc := SWEEP_INTERVAL_S
var _serial := 0
var _rival_spawned := {}
var _flight_time := {}
var now := 0.0
var aerostat_ready_t = null
var _alias := {}
var _unalias := {}
var pending_claim := {}  ## role -> unit kind waiting to launch
var frozen := false  ## tests: stand the task force down (Python monkeypatches tick)


func _init(world_: World, rng_: PyRandom = null, radio_: RadioNet = null, controller_ := "ai", features_ = null) -> void:
	world = world_
	rng = rng_ if rng_ != null else PyRandom.new()
	controller = controller_
	if features_ != null:
		features = features_
	var srng := PyRandom.new()
	srng.seed_float(rng.random())
	sensors = SensorNet.new(world, srng)
	if radio_ != null:
		radio = radio_
	else:
		var rrng := PyRandom.new()
		rrng.seed_float(rng.random())
		radio = RadioNet.new(rrng)


# ---------------------------------------------------- anonymous track numbers
## What the desk calls a contact: 'T3', never the internal id.
func alias(target_id):
	if target_id == null:
		return null
	if not _alias.has(target_id):
		var a := "T%d" % (_alias.size() + 1)
		_alias[target_id] = a
		_unalias[a] = target_id
	return _alias[target_id]


func resolve(name):
	if name == null or name == "":
		return name
	return _unalias.get(name, name)


# ---------------------------------------------------- runner-facing compat
func case(tid := "runner") -> Case:
	if not cases.has(tid):
		cases[tid] = Case.new(tid)
	return cases[tid]


var suspicion: float:
	get:
		return case().suspicion
	set(v):
		case().suspicion = v

var wanted: int:
	get:
		return case().wanted
	set(v):
		case().wanted = v

var bust_meter: float:
	get:
		return case().bust_meter

var rival_meter: float:
	get:
		return case().rival_meter

var detected_by:
	get:
		return case().detected_by


func detector(tid := "runner") -> String:
	var d: SensorNet.Detection = detections.get(tid)
	return d.detector_level() if d else ""


func reset(keep_wanted := false, tid := "runner") -> void:
	var c := case(tid)
	var w := c.wanted
	cases[tid] = Case.new(tid, {"wanted": w if keep_wanted else 0, "tipped": c.tipped and keep_wanted,
		"last_known": c.last_known if keep_wanted and w else null})
	for u in units:
		if u.target_id == tid and u.faction() == "rival":
			u.state = "return"
	if not keep_wanted:
		for u in units:
			if u.target_id == tid:
				u.target_id = null
				u.state = "return"
	_rival_spawned.erase(tid)
	_flight_time[tid] = 0.0


# ---------------------------------------------------- radio
func _say(sender: String, text: String, pos = null) -> void:
	radio.transmit(now, "police", sender, text, pos)
	law_events.append("%s: %s" % [sender, text])


# ---------------------------------------------------- resources / commands
func police_bases() -> Array:
	return world.airfields.filter(func(a): return a.police)


## Queue a unit launch. Returns an error string or null.
func launch(kind: String, base_code = null, target_id = null, goal = null, near = null):
	if kind == "interceptor" and not features.has("interceptors"):
		return "No interceptors assigned to this task force yet."
	if kind == "cutter":
		return "Cutters are launched by the maritime desk."  # handled by Session/maritime
	if stock.get(kind, 0) <= 0:
		return "No %s available." % kind
	var bases := police_bases()
	var base: Airfield
	if base_code:
		base = Py.first(bases, func(b): return b.code == base_code)
		if base == null:
			return "%s is not a police base." % base_code
	else:
		var ref: Array = near if near != null else (goal if goal != null else [0.0, 0.0])
		base = Py.min_by(bases, func(a): return (a.x - ref[0]) ** 2 + (a.y - ref[1]) ** 2)
	stock[kind] -= 1
	var delay := LAUNCH_DELAY_S + (ENCRYPTION_DELAY_S if radio.encrypted else 0.0)
	_launches.append([now + delay, kind, base.code, target_id, goal])
	return null


func _spawn_now(kind: String, base_code: String, target_id, goal) -> Pursuer:
	var base: Airfield = Py.first(world.airfields, func(a): return a.code == base_code)
	_serial += 1
	var u := Pursuer.new(kind, base.x, base.y, world.airfield_elev(base) + 60, base.heading, [base.x, base.y], {
		"speed": UNIT_TYPES[kind][0] * KT * 0.5, "id": "%s-%d" % [CALLSIGNS[kind], _serial],
		"target_id": target_id, "goal": goal, "state": "pursuit" if target_id else "goto"})
	units.append(u)
	for role in pending_claim.keys():
		if pending_claim[role] == kind:
			u.pilot = role
			pending_claim.erase(role)
			break
	var where: String = ("toward %s" % alias(target_id)) if target_id else "to assigned area"
	_say(u.id, "airborne from %s, vectoring %s" % [base.name, where], [u.x, u.y])
	return u


func spawn_rival(near: Array, target_id: String) -> Pursuer:
	var ang := rng.uniform(0, 2 * PI)
	var x: float = near[0] + 5000 * cos(ang)
	var y: float = near[1] + 5000 * sin(ang)
	_serial += 1
	var u := Pursuer.new("rival", x, y, world.ground(x, y) + 250, 0.0, [x, y], {
		"speed": UNIT_TYPES["rival"][0] * KT * 0.6, "id": "Rival-%d" % _serial, "target_id": target_id})
	units.append(u)
	return u


func dispatch(unit_id: String, target_id = null, point = null):
	var u: Pursuer = Py.first(units, func(u): return u.id == unit_id and u.state != "crashed")
	if u == null:
		return "No unit %s." % unit_id
	u.target_id = target_id
	u.goal = point
	u.state = "pursuit" if target_id else "goto"
	_say(u.id, "copies, %s" % [("intercepting " + alias(target_id)) if target_id else "proceeding to area"], [u.x, u.y])
	return null


func recall(unit_id: String):
	var u: Pursuer = Py.first(units, func(u): return u.id == unit_id)
	if u == null:
		return "No unit %s." % unit_id
	u.state = "return"
	u.target_id = null
	u.goal = null
	_say(u.id, "RTB", [u.x, u.y])
	return null


func set_encryption(on: bool):
	if on and not features.has("encryption"):
		return "Encryption not budgeted yet."
	radio.encrypted = on
	law_events.append("Radio encryption %s" % ("ON (slower dispatch)" if on else "OFF"))
	return null


func set_aerostat(on: bool):
	if not features.has("aerostat"):
		return "No aerostat on station."
	var site := sensors.site("AER")
	if on:
		aerostat_ready_t = now + 60.0
		law_events.append("Aerostat going up - radar live in 60 s")
	else:
		site.active = false
		aerostat_ready_t = null
	return null


func add_tip(x: float, y: float, radius: float, text: String, squawk := "", target_id = null) -> void:
	if not features.has("informants"):
		return
	tips.append(Tip.new(now, x, y, radius, text, squawk))
	Py.keep_last(tips, 12)
	law_events.append("TIP: " + text)
	if target_id:
		case(target_id).tipped = true
		case(target_id).suspicion = maxf(case(target_id).suspicion, 40.0)
	if controller == "ai" and stock.get("heli", 0) > 0:
		launch("heli", null, null, [x, y])


# ---------------------------------------------------- AI controller
func _ai_escalate(c: Case, level: int, sig: SensorNet.Signature) -> void:
	level = maxi(0, mini(3, level))
	if level > c.wanted:
		events.append("WANTED LEVEL %d" % level)
		var need: Array = {1: ["heli"], 2: ["heli", "interceptor"], 3: ["heli", "interceptor", "interceptor"]}[level]
		var have := []
		for u in units:
			if u.faction() == "police" and u.target_id == c.target_id and not (u.state in ["crashed", "return"]):
				have.append(u.kind)
		for l in _launches:
			if l[3] == c.target_id:
				have.append(l[1])
		for k in need:
			if have.has(k):
				have.erase(k)
				continue
			# re-task an idle unit first, then launch
			var idle: Pursuer = Py.first(units, func(u): return u.kind == k and u.faction() == "police" \
				and u.target_id == null and u.state in ["goto", "return", "search"])
			if idle:
				idle.target_id = c.target_id
				idle.state = "pursuit"
				idle.goal = null
			elif not (k == "interceptor" and not features.has("interceptors")):
				launch(k, null, c.target_id, null, [sig.x, sig.y])
	elif level < c.wanted:
		events.append("Wanted level down" if level else "You lost them. Heat is off.")
		if level == 0:
			for u in units:
				if u.faction() == "police" and u.target_id == c.target_id:
					u.state = "return"
					u.target_id = null
	c.wanted = level


# ---------------------------------------------------- main tick
## Advance the task force. Returns {target_id: "busted" | "clean" | "hijacked"}.
func tick(dt: float, now_: float, targets: Array) -> Dictionary:
	if frozen:
		return {}
	now = now_
	var outcomes := {}
	var by_id := {}
	for t in targets:
		by_id[t.sig.id] = t

	# aerostat winch
	if aerostat_ready_t != null and now >= aerostat_ready_t:
		sensors.site("AER").active = true
		aerostat_ready_t = null
		law_events.append("Aerostat radar on line")

	# launches
	for item in _launches.filter(func(l): return l[0] <= now):
		_launches.erase(item)
		_spawn_now(item[1], item[2], item[3], item[4])

	# radar sweep (1 Hz, like a rotating antenna)
	_sweep_acc += dt
	if _sweep_acc >= SWEEP_INTERVAL_S:
		_sweep_acc = 0.0
		detections = sensors.sweep(targets.map(func(t): return t.sig), now)
		for t in targets:
			_classify(t, SWEEP_INTERVAL_S)

	# units
	var seen_by := {}
	for u in units:
		var tgt: Target = by_id.get(u.target_id) if u.target_id else null
		var chase = null
		var goal = u.goal
		if tgt != null:
			if _can_see(u, tgt.sig):
				chase = tgt.sig
			else:
				var tr: SensorNet.Track = sensors.tracks.get(tgt.sig.id)
				if tr != null and tr.age(now) < 3.0:
					chase = tr
				else:
					var c := case(tgt.sig.id)
					goal = c.last_known.slice(0, 2) if c.last_known else goal
		elif u.target_id and not by_id.has(u.target_id) and u.faction() == "police":
			# target landed or left: search where it was last seen
			var c: Case = cases.get(u.target_id)
			goal = c.last_known.slice(0, 2) if c and c.last_known else null
			if goal == null:
				u.state = "return"
		if u.faction() == "police" and 0 <= u.fuel_s and u.fuel_s < 1.0 and u.state != "return":
			if u.pilot:
				law_events.append("%s: bingo fuel - autopilot taking her home" % u.id)
				u.pilot = null
			u.state = "return"
			u.target_id = null
			u.goal = null
			_say(u.id, "bingo fuel, RTB", [u.x, u.y])
		if u.state == "return":
			chase = null
			goal = null
		var was_crashed: bool = u.state == "crashed"
		u.update(dt, chase, world, goal)
		if u.state == "crashed":
			if u.just_crashed and not was_crashed:
				u.just_crashed = false
				events.append("The %s %s hit the terrain!" % [u.faction(), u.kind])
				law_events.append("%s DOWN - crashed into terrain" % u.id)
			continue
		# visual acquisition of anything suspicious
		u.sees_player = false
		for t in targets:
			if not _can_see(u, t.sig):
				continue
			var c := case(t.sig.id)
			if u.faction() == "rival":
				if u.target_id == t.sig.id:
					u.sees_player = true
					_append(seen_by, "rival:" + t.sig.id, u)
				continue
			if u.target_id == t.sig.id or (u.target_id == null and (c.wanted or c.suspicion >= 50)):
				u.target_id = t.sig.id
				u.state = "pursuit"
				u.sees_player = true
				_append(seen_by, t.sig.id, u)
				c.last_known = [t.sig.x, t.sig.y, now]
				if not u.had_visual and now - u.chatter_t > 12:
					u.chatter_t = now
					var hdg := Py.fmod(Py.degrees(atan2(t.sig.vx, t.sig.vy)), 360)
					_say(u.id, "tally on %s, heading %s, %s" % [alias(t.sig.id), Py.f0(hdg, 3),
						"low" if t.sig.agl < 150 else "medium"], [u.x, u.y])
		if u.had_visual and not u.sees_player and u.faction() == "police" and now - u.chatter_t > 12:
			u.chatter_t = now
			_say(u.id, "lost visual, searching last known", [u.x, u.y])
		u.had_visual = u.sees_player
	units = units.filter(func(u): return not (u.state == "crashed" and u.crashed_timer > 20))
	var returned := units.filter(func(u): return u.state == "return" and PyMath.hypot(u.x - u.home[0], u.y - u.home[1]) < 300)
	for u in returned:
		if u.faction() == "police":
			stock[u.kind] = stock.get(u.kind, 0) + 1
	units = units.filter(func(u): return not returned.has(u))

	# per-target bookkeeping
	for t in targets:
		var tid: String = t.sig.id
		var c := case(tid)
		_flight_time[tid] = _flight_time.get(tid, 0.0) + dt
		var seen: bool = not seen_by.get(tid, []).is_empty() or Py.truthy(c.detected_by)
		if c.wanted:
			if seen:
				c.seen_time += dt
				c.unseen_time = 0.0
				if c.seen_time > 60 and c.wanted < 3 and controller == "ai":
					c.seen_time = 0.0
					_ai_escalate(c, c.wanted + 1, t.sig)
			else:
				c.unseen_time += dt
				if c.unseen_time > 15 + 12 * c.wanted:
					c.unseen_time = 0.0
					c.seen_time = 0.0
					if controller == "ai":
						_ai_escalate(c, c.wanted - 1, t.sig)
					else:
						c.wanted -= 1
					if c.wanted == 0:
						c.suspicion = 0.0
		var close := Py.any(seen_by.get(tid, []), func(u): return u.dist_to(t.sig) < BUST_RANGE_M)
		c.bust_meter = minf(100.0, c.bust_meter + 22 * dt) if close else maxf(0.0, c.bust_meter - 12 * dt)
		if c.bust_meter >= 100:
			c.bust_meter = 0.0
			outcomes[tid] = "busted" if t.hot else "clean"
			_close_case(tid, t.hot)
			continue
		# rivals
		if (features.has("rivals") and t.hot and t.value > 2000 and not _rival_spawned.has(tid)
				and _flight_time[tid] > 45 and tid == "runner"):
			_rival_spawned[tid] = true
			if rng.random() < 0.6:
				spawn_rival([t.sig.x, t.sig.y], tid)
				events.append("Rival smugglers inbound! Don't let them close in.")
		var rclose := Py.any(seen_by.get("rival:" + tid, []), func(u): return u.dist_to(t.sig) < RIVAL_RANGE_M)
		c.rival_meter = minf(100.0, c.rival_meter + 14 * dt) if rclose else maxf(0.0, c.rival_meter - 10 * dt)
		if c.rival_meter >= 100:
			c.rival_meter = 0.0
			for u in units:
				if u.faction() == "rival" and u.target_id == tid:
					u.state = "return"
			outcomes[tid] = "hijacked"
	return outcomes


static func _append(d: Dictionary, k: String, v) -> void:
	if not d.has(k):
		d[k] = []
	d[k].append(v)


func _close_case(tid: String, hot: bool) -> void:
	if hot:
		score["busts"] += 1
		law_events.append("BUST: %s forced down, contraband found" % alias(tid))
	else:
		score["clean_stops"] += 1
		law_events.append("%s forced down - search found nothing" % alias(tid))
	for u in units:
		if u.target_id == tid:
			u.target_id = null
			u.state = "return"
	cases[tid] = Case.new(tid)


func _can_see(u: Pursuer, sig: SensorNet.Signature) -> bool:
	if u.state == "crashed":
		return false
	if u.dist_to(sig) > SIGHT_RANGE_M:
		return false
	return world.line_of_sight([u.x, u.y, u.z], [sig.x, sig.y, sig.z], 100)


func _classify(t: Target, dt: float) -> void:
	var sig := t.sig
	var c := case(sig.id)
	var det: SensorNet.Detection = detections.get(sig.id)
	var site_code = det.detected_by[0] if det and not det.detected_by.is_empty() else null
	c.detected_by = site_code
	if site_code:
		c.last_known = [sig.x, sig.y, now]
		if sig.transponder:
			c.identified_t = now
			c.squawk = sig.squawk
	# squawk lost while being tracked: the classic tell
	if site_code and not sig.transponder and 0 < now - c.identified_t and now - c.identified_t < 20 and c.squawk:
		c.suspicion = minf(100.0, c.suspicion + 50)
		_say("Center", "squawk %s lost at %s, primary only" % [c.squawk, site_code], null)
		c.squawk = ""
	if c.wanted:
		return
	if site_code:
		c.last_contact = [sig.x, sig.y, sig.agl, sig.vx, sig.vy, sig.transponder]
	elif c.last_contact != null:
		# radar just lost it: where, how low, and heading where?
		var lc: Array = c.last_contact
		var x: float = lc[0]
		var y: float = lc[1]
		c.last_contact = null
		var na := world.nearest_airfield(x, y)
		var af: Airfield = na[0]
		var dist: float = na[1]
		var toward := Py.degrees(atan2(af.x - x, af.y - y))
		var track := Py.degrees(atan2(lc[3], lc[4]))
		if (lc[5] and lc[2] < 700 and af.kind in ["bush", "shady"] and dist < 6000
				and absf(Py.wrap180(toward - track)) < 50 and not c.odd_destination.has(af.code)):
			# legitimate traffic doesn't let down into an unlit quarry or a farmer's field
			c.odd_destination[af.code] = true
			var bump := ODD_DESTINATION_SUSPICION if af.kind == "shady" else BUSH_DESTINATION_SUSPICION
			c.suspicion = minf(100.0, c.suspicion + bump)
			if c.suspicion >= 100:
				law_events.append("Track %s flagged: nobody legit lands at %s" % [alias(sig.id), af.name])
				if controller == "ai":
					_ai_escalate(c, 1, sig)
				else:
					c.wanted = 1
			_say("Center", "%s dropped off the scope low, toward %s" % [sig.squawk if sig.squawk else "squawking traffic", af.name], null)
			c.last_known = [af.x, af.y, now]
	if site_code:
		var site := sensors.site(site_code)
		var d := PyMath.hypot(sig.x - site.x, sig.y - site.y)
		# A primary-only blip is not a crime: plenty of VFR traffic flies without a
		# transponder. Suspicion comes from a sustained track and from behaviour
		# (tuned by the tactical sim; see docs/BALANCE.md).
		var rate := PRIMARY_RATE + PRIMARY_RATE_NEAR * (1 - d / site.range_m)
		if sig.transponder and not c.tipped:
			rate = 0.0  # identified, filed traffic
		elif sig.transponder:
			rate *= 0.5
		elif sig.agl < 150 and sig.speed_kts() > 100 and _inbound_from_sea(sig):
			rate *= INBOUND_LOW_MULT  # low and fast, coming in off the sea: the classic profile
		# low and slow over water looks like an airdrop
		if world.is_water(sig.x, sig.y) and sig.speed_kts() < 110 and sig.agl < 350:
			rate += DROP_PATTERN_RATE
			if not c.drop_alerted:
				c.drop_alerted = true
				law_events.append("ALERT: possible airdrop pattern near %s,%s km" % [Py.f(sig.x / 1000, 1), Py.f(sig.y / 1000, 1)])
				tips.append(Tip.new(now, sig.x, sig.y, 1500, "possible airdrop"))
		c.suspicion += dt * rate
		if c.suspicion >= 100:
			c.suspicion = 100
			events.append("%s has you. Police dispatched!" % site.name)
			law_events.append("Track %s flagged suspicious by %s" % [alias(sig.id), site.name])
			if controller == "ai":
				_ai_escalate(c, 1, sig)
			else:
				c.wanted = 1
	else:
		c.suspicion = maxf(0.0, c.suspicion - SUSPICION_DECAY * dt)


## Is the track heading inland from open water behind it?
func _inbound_from_sea(sig: SensorNet.Signature) -> bool:
	var sp := PyMath.hypot(sig.vx, sig.vy)
	if sp < 1:
		return false
	var bx := sig.x - sig.vx / sp * 3000
	var by := sig.y - sig.vy / sp * 3000
	return world.is_water(bx, by) and not world.is_water(sig.x, sig.y)


# ---------------------------------------------------- landing
## Called once when the player comes to a stop. true -> police grab you.
func landing_check(s, field_: Airfield, carrying_hot: bool, tid := "runner") -> bool:
	var c := case(tid)
	for u in units:
		if u.faction() == "police" and u.target_id == tid and u.state != "crashed" and u.dist_to(s) < LANDING_BUST_RANGE_M:
			return true
	if field_.police and c.wanted > 0:
		return true
	if field_.police and carrying_hot and not no_customs and rng.random() < 0.35:
		events.append("Customs inspection!")
		return true
	return false


## [Pursuer, distance] or null
func nearest_threat(s):
	var live := units.filter(func(u): return not (u.state in ["crashed", "return"]))
	if live.is_empty():
		return null
	var u: Pursuer = Py.min_by(live, func(u): return u.dist_to(s))
	return [u, u.dist_to(s)]
