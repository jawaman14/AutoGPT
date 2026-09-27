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
##   - the pack: what you carry besides the gun in your hands - spare weapons,
##     rounds, medkits - up to CARRY_KG, and over HEAVY_KG it slows you. Switching
##     guns keeps the other in the pack; climbing in, the guns and rounds go back
##     to the armoury (medkits stay with you). Go down and the pack is lost;
##     arrested, the guns and rounds go to the task force's armoury.

const LIVE_M := 300.0
const LIVE_OUT_M := 350.0
const ROUND_S := 2.0
const HP := 100.0
const MAG := {"pistol": 12, "rifle": 30, "mg": 100, "rpg": 1}
const DAMAGE := {"pistol": 34.0, "rifle": 55.0, "mg": 45.0, "rpg": 250.0}
const ACCURACY := {"pistol": 0.07, "rifle": 0.1, "mg": 0.09, "rpg": 0.05}  ## an AI man's hit chance per round at 50 m
const KEYS := {"1": "pistol", "2": "rifle", "3": "mg", "4": "rpg"}
const KG := {"pistol": 1.0, "rifle": 3.6, "mg": 10.5, "rpg": 6.5, "ammo": 0.025, "medkit": 0.8}  ## per item; per round
const CARRY_KG := 24.0
const HEAVY_KG := 12.0  ## heavier than this and you slow down, to 60% at the limit
const MEDKIT_COST := 150
const MEDKIT_HP := 45.0

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
var pack := {}  ## item -> count ("ammo": rounds): what you carry besides the gun in your hands
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


## Climbing back in: the guns and rounds go back in the armoury; medkits stay with you.
func leave() -> void:
	holster()
	if armoury() != null:
		for t in MAG:
			armoury().stock[t] += int(pack.get(t, 0))
		armoury().ammo += int(pack.get("ammo", 0))
	var kits := int(pack.get("medkit", 0))
	pack.clear()
	if kits > 0:
		pack["medkit"] = kits
	active = false


## Everything you carry, the gun in your hands and its rounds included.
func weight() -> float:
	var kg := 0.0
	for k in pack:
		kg += KG.get(k, 0.0) * int(pack[k])
	if tier != "":
		kg += KG[tier] + KG.ammo * (mag + reserve)
	return kg


## Walking and running speed: full up to HEAVY_KG, 60% at CARRY_KG.
func speed_factor() -> float:
	return 1.0 - 0.4 * clampf((weight() - HEAVY_KG) / (CARRY_KG - HEAVY_KG), 0.0, 1.0)


## Put `n` of `item` in the pack: guns and rounds from the armoury, medkits
## bought (at the aircraft). Returns "" or why not.
func pack_add(item: String, n := 1) -> String:
	if not KG.has(item) or n <= 0:
		return "No such thing."
	if weight() + KG[item] * n > CARRY_KG + 1e-6:
		return "Too heavy - you're carrying %.1f of %.0f kg." % [weight(), CARRY_KG]
	if item == "medkit":
		if sess.money < MEDKIT_COST * n:
			return "A medkit is $%d." % MEDKIT_COST
		sess.money -= MEDKIT_COST * n
	elif armoury() == null:
		return "No armoury."
	elif item == "ammo":
		n = mini(n, armoury().ammo)
		if n <= 0:
			return "No rounds in the armoury."
		armoury().ammo -= n
	else:
		if armoury().take(item, n) < n:
			return "No %s in the armoury." % Arsenal.TIERS[item].name.to_lower()
	pack[item] = int(pack.get(item, 0)) + n
	return ""


## Leave `n` of `item` behind: guns and rounds back in the armoury.
func pack_drop(item: String, n := 1) -> String:
	n = mini(n, int(pack.get(item, 0)))
	if n <= 0:
		return "You're not carrying that."
	pack[item] -= n
	if pack[item] == 0:
		pack.erase(item)
	if armoury() != null:
		if item == "ammo":
			armoury().ammo += n
		elif MAG.has(item):
			armoury().stock[item] += n
	return ""


## Patch yourself up.
func use_medkit() -> String:
	if int(pack.get("medkit", 0)) <= 0:
		return "No medkit."
	if hp >= HP:
		return "You're fine."
	pack_drop("medkit")
	hp = minf(HP, hp + MEDKIT_HP)
	return ""


func move(x_: float, y_: float, moving_ := false) -> void:
	x = x_
	y = y_
	moving = moving_


func armoury():
	return sess.arsenals.get("org")


## Draw a weapon of `tier`: from the pack, else off the armoury's rack (if you
## can carry it), with rounds from the pack, then the armoury, up to four
## magazines and what you can carry. Returns "" or why not.
func draw(t: String) -> String:
	if not Arsenal.REALISM or armoury() == null:
		return "No armoury."
	if not MAG.has(t):
		return "No such weapon."
	if tier == t:
		return ""
	holster()
	if int(pack.get(t, 0)) > 0:
		pack[t] -= 1
		if pack[t] == 0:
			pack.erase(t)
	else:
		if weight() + KG[t] > CARRY_KG + 1e-6:
			return "Too heavy for a %s - you're carrying %.1f of %.0f kg (I: your pack)." % [Arsenal.TIERS[t].name.to_lower(), weight(), CARRY_KG]
		if armoury().take(t, 1) == 0:
			return "No %s in the armoury." % Arsenal.TIERS[t].name.to_lower()
	tier = t
	var want: int = MAG[t] * 4
	var carried := int(pack.get("ammo", 0))
	var from_pack := mini(want, carried)
	pack["ammo"] = carried - from_pack
	if pack.ammo == 0:
		pack.erase("ammo")
	var room := int(floor((CARRY_KG - weight()) / KG.ammo))
	var from_rack := clampi(mini(want - from_pack, armoury().ammo), 0, maxi(0, room))
	armoury().ammo -= from_rack
	var got := from_pack + from_rack
	mag = mini(MAG[t], got)
	reserve = got - mag
	return ""


## Put the gun away: it goes in the pack with its rounds.
func holster() -> void:
	if tier != "":
		pack[tier] = int(pack.get(tier, 0)) + 1
		if mag + reserve > 0:
			pack["ammo"] = int(pack.get("ammo", 0)) + mag + reserve
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
		sess.say("You went down. You wake up by the aircraft, $%d lighter; the gun and your pack are gone." % fee)
	elif how == "arrested" and sess.arsenals.has("law"):
		# the guns and rounds on you go into evidence, then the task force's armoury
		var law = sess.arsenals.law
		holster()
		for t in MAG:
			law.stock[t] += int(pack.get(t, 0))
		law.ammo += int(pack.get("ammo", 0))
	tier = ""
	mag = 0
	reserve = 0
	pack.clear()
	hp = HP


func dict() -> Dictionary:
	return {"active": active, "hp": int(hp), "tier": tier, "mag": mag, "reserve": reserve, "kills": kills, "down": down,
		"pack": pack.duplicate(), "kg": snappedf(weight(), 0.1),
		"armoury": armoury().to_dict().stock if armoury() != null else {}}
