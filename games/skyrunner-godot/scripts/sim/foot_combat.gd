class_name FootCombat
extends RefCounted
## The pilot on foot with a gun (the ground war's first-person side). The
## session decides everything; the 3D walker only aims:
##
##   - a weapon is drawn from the organisation's armoury (1 pistol, 2 rifle,
##     3 machine gun) with up to three magazines from its ammunition, and goes
##     back when you climb in
##   - a shot the walker says hit a man of squad X is checked here (in range,
##     a round in the magazine) and applied: a man down, the squad's nerve
##     shaken, it turns on you; shooting at police is a crime that brings them
##   - squads within LIVE_M that are hostile to you shoot back every round:
##     Los Cuervos when you're on their streets or shot at them, the police
##     when you shot at them or you're wanted; hit chance by weapon, range and
##     whether you're moving (own RNG stream: live play, never replayed)
##   - at 0 health you're down: with police close, arrested (the bust); else
##     you wake up at the aircraft $500 lighter, the gun gone
##   - a patrol that reaches a wanted man on foot who isn't shooting arrests him

const LIVE_M := 300.0
const LIVE_OUT_M := 350.0
const ROUND_S := 2.0
const HP := 100.0
const MAG := {"pistol": 12, "rifle": 30, "mg": 100, "rpg": 1}
const DAMAGE := {"pistol": 34.0, "rifle": 55.0, "mg": 45.0, "rpg": 250.0}
const ACCURACY := {"pistol": 0.07, "rifle": 0.1, "mg": 0.09, "rpg": 0.05}  ## an AI man's hit chance per round at 50 m
const KEYS := {"1": "pistol", "2": "rifle", "3": "mg", "4": "rpg"}

var sess  ## Session
var rng: PyRandom
var active := false
var x := 0.0
var y := 0.0
var moving := false
var hp := HP
var tier := ""
var mag := 0
var reserve := 0
var man_hp := {}  ## squad id -> hp of the man you're working on (a hit may not drop him)
var angry := {}  ## squad id -> until (they're shooting at you)
var shot_police_t := -1e9
var shot_rival_t := -1e9
var down := ""  ## "" | "hospital" | "arrested": the walker's cue to end the walk
var hits_taken := 0
var kills := 0
var _t := 0.0


func _init(sess_, rng_: PyRandom) -> void:
	sess = sess_
	rng = rng_


func enter(x_: float, y_: float) -> void:
	active = true
	x = x_
	y = y_
	hp = HP
	down = ""
	angry.clear()


## Climbing back in: the gun and its rounds go back in the armoury.
func leave() -> void:
	holster()
	active = false


func move(x_: float, y_: float, moving_ := false) -> void:
	x = x_
	y = y_
	moving = moving_


func armoury():
	return sess.arsenals.get("org")


## Draw a weapon of `tier` from the armoury. Returns "" or why not.
func draw(t: String) -> String:
	if not Arsenal.REALISM or armoury() == null:
		return "No armoury."
	if not MAG.has(t):
		return "No such weapon."
	if tier == t:
		return ""
	holster()
	if armoury().take(t, 1) == 0:
		return "No %s in the armoury." % Arsenal.TIERS[t].name.to_lower()
	tier = t
	var want: int = MAG[t] * 4
	var got := mini(want, armoury().ammo)
	armoury().ammo -= got
	mag = mini(MAG[t], got)
	reserve = got - mag
	return ""


func holster() -> void:
	if tier != "" and armoury() != null:
		armoury().stock[tier] += 1
		armoury().ammo += mag + reserve
	tier = ""
	mag = 0
	reserve = 0


func reload() -> bool:
	if tier == "" or reserve <= 0 or mag >= MAG[tier]:
		return false
	var k := mini(MAG[tier] - mag, reserve)
	mag += k
	reserve -= k
	return true


## One trigger pull; false when the magazine is empty (the walker clicks).
func fire() -> bool:
	if tier == "" or mag <= 0 or not active:
		return false
	mag -= 1
	return true


## The walker's ray hit a man of `squad_id` at `dist` metres: apply it. Returns
## "down" | "hit" | "" (not valid: out of range, no such squad).
func hit(squad_id: String, dist: float) -> String:
	var g = sess.ground
	if g == null or tier == "":
		return ""
	var q = g.get_squad(squad_id)
	if q == null or q.men <= 0:
		return ""
	var range: float = Arsenal.TIERS[tier].range
	if dist > range * 1.5 or Vector2(q.x, q.y).distance_to(Vector2(x, y)) > range * 1.5 + 40.0:
		return ""
	var h: float = man_hp.get(squad_id, HP) - DAMAGE[tier]
	angry[squad_id] = sess.time + 120.0
	q.morale = maxf(0.0, q.morale - 0.03)
	if q.faction == "police":
		shot_police_t = sess.time
		var c = sess.police.case("runner")
		c.suspicion = minf(100.0, c.suspicion + 12.0)
	elif q.faction == "rival":
		shot_rival_t = sess.time
	if h > 0.0:
		man_hp[squad_id] = h
		return "hit"
	man_hp.erase(squad_id)
	kills += 1
	var dropped := {}
	for t in Arsenal.ORDER:
		if int(q.loadout.get(t, 0)) > 0:
			q.loadout[t] = int(q.loadout[t]) - 1
			dropped[t] = 1
			break
	q.men -= 1
	q.morale = maxf(0.0, q.morale - 0.6 / maxf(1.0, q.men0))
	if armoury() != null and not dropped.is_empty():
		armoury().add_all(dropped)  # you pick his gun up
	if q.faction == "police":
		g.officers_down += 1
		sess.law_say("Officer down - shots fired by a man on foot near %s" % g._place_name(q.x, q.y))
	g.hot_spots.append([sess.time, q.x, q.y])
	if q.men <= 0:
		g._gone(q)
	elif q.men * 2 <= q.men0 or q.morale < 0.3:
		q.state = "routed"
		g.go(q, g._nearest_cover(q.pos()))
	return "down"


## Who's out to get you right now.
func hostile(q) -> bool:
	if q.faction == "org" or q.state in ["gone", "routed"]:
		return false
	if angry.get(q.id, 0.0) > sess.time:
		return true
	if q.faction == "police":
		var c = sess.police.case("runner")
		return sess.time - shot_police_t < 180.0 or c.wanted
	# Los Cuervos: on their streets, or you shot at them
	if sess.time - shot_rival_t < 180.0:
		return true
	return sess.ground.rival_share(GroundWar.market_at(x, y)) > 0.4 and Vector2(q.x, q.y).distance_to(Vector2(x, y)) < 150.0


func live_squads() -> Array:
	if sess.ground == null:
		return []
	return sess.ground.squads.filter(func(q): return q.state != "gone" and Vector2(q.x, q.y).distance_to(Vector2(x, y)) < LIVE_M)


func update(dt: float) -> void:
	if not active or down != "" or sess.ground == null:
		return
	_t += dt
	if _t < ROUND_S:
		return
	var step := _t
	_t = 0.0
	var me := Vector2(x, y)
	for q in live_squads():
		var d := Vector2(q.x, q.y).distance_to(me)
		# a patrol walks up to a wanted man who isn't shooting: hands up
		if q.faction == "police" and d < 40.0 and sess.police.case("runner").wanted and sess.time - shot_police_t > 60.0:
			_down("arrested")
			sess._bust("arrested on foot by %s" % q.id)
			return
		if not hostile(q):
			continue
		# they stop and fight you
		if q.fight == null and q.route.size() >= 2 and d < 200.0:
			q.route = PackedVector2Array()
			q.state = "holding"
		var shots := 0
		for t in q.loadout:
			shots += int(q.loadout[t])
		shots = mini(shots, q.men)
		var tier_q := "pistol"
		for t in Arsenal.ORDER:
			if int(q.loadout.get(t, 0)) > 0:
				tier_q = t
				break
		var p: float = ACCURACY[tier_q] * clampf(60.0 / maxf(10.0, d), 0.15, 2.0) * (0.55 if moving else 1.0) * (0.4 + 0.6 * q.morale)
		if d > float(Arsenal.TIERS[tier_q].range):
			continue
		for i in shots:
			if rng.random() < p:
				hits_taken += 1
				hp -= DAMAGE[tier_q] * 0.35  # you're behind something, mostly
		q.ammo = maxi(0, q.ammo - shots * 3)
		if hp <= 0.0:
			var cops := live_squads().any(func(s): return s.faction == "police" and Vector2(s.x, s.y).distance_to(me) < LIVE_M)
			if cops:
				_down("arrested")
				sess._bust("shot and arrested on foot")
			else:
				_down("hospital")
			return
	# the AI comes for you: Los Cuervos on their turf, the police for a wanted man
	if sess.ground != null and rng.random() < 0.05 * step:
		for f in ["rival", "police"]:
			var want: bool = (f == "rival" and sess.ground.rival_share(GroundWar.market_at(x, y)) > 0.4) or (f == "police" and sess.police.case("runner").wanted)
			if not want:
				continue
			var free: Array = sess.ground._free(f)
			if not free.is_empty():
				var q = Py.min_by(free, func(s): return Vector2(s.x, s.y).distance_to(me))
				sess.ground.order(q, {"type": "attack", "x": x, "y": y})


func _down(how: String) -> void:
	down = how
	if how == "hospital":
		var fee := mini(maxi(0, sess.money), 500)
		sess.money -= fee
		sess.say("You went down. You wake up by the aircraft, $%d lighter; the gun's gone." % fee)
	tier = ""
	mag = 0
	reserve = 0
	hp = HP


func dict() -> Dictionary:
	return {"active": active, "hp": int(hp), "tier": tier, "mag": mag, "reserve": reserve, "kills": kills, "down": down,
		"armoury": armoury().to_dict().stock if armoury() != null else {}}
