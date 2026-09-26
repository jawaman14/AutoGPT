class_name GroundWar
extends RefCounted
## The war on the ground: the organisation's soldiers, Los Cuervos' crews and
## the task force's narcotics squads, on foot, in cars and in trucks, on the
## map's roads (RoadGraph).
##
## Squads take orders (patrol, guard, escort, attack, raid, checkpoint and the
## doctrine's tactics below) from a commander: the AI by default, a human
## lieutenant or patrol commander when one takes the seat. Where hostile squads
## see each other within CONTACT_M a firefight runs in 2 s rounds by
## Lanchester's aimed-fire (square) law: each side's losses per round are
##
##   K x (enemy men) x (enemy fire per man: Arsenal tier, ammo, morale)
##     x (own cover: city, jungle and mangrove hide you; a vehicle is a box)
##     x (surprise: an ambush's first volleys)
##
## drawn binomially on their own RNG stream. Losses and being outnumbered
## break morale; a side routs at 40% losses or morale 0.3.
##
## Two doctrines:
##   guerrilla (the organisation, Los Cuervos): never a fair fight - AMBUSH at
##     a chokepoint on the enemy's route (first volleys x2.5, a morale shock),
##     HIT_AND_RUN (two rounds, then break contact), MELT_AWAY into cover when
##     outgunned (hidden: found only within HIDDEN_M), HARASS a checkpoint,
##     DECOY cars on another road while a truck runs, SAFE ZONES (jungle,
##     mangrove, the barrio) to fall back to.
##   narcotics (the task force): STAKEOUT a suspected stash (surveillance heats
##     it until it's known), TAIL a truck to its stash instead of stopping it,
##     informants' CONTROLLED BUYS reveal a stash, BUY-BUST a stash (a hidden
##     team arrests whoever turns up), PERIMETER then BREACH a raid (a cordon
##     first: nobody escapes), CHECKPOINTs on the trucks' roads and SATURATION
##     patrols where the shooting was, SWAT when the arsenal has the rifles.
##     Rules of engagement: police don't fire first on a squad that isn't
##     shooting (they call on it to surrender); arrests beat kills (evidence).
##
## Police wins arrest the survivors and seize their weapons into the police
## arsenal; police losses bring heat and a surge. Squad-minutes in a market
## (Economy's town/west/north/sea) build control: the turf that moves prices
## and, with the season's ground_turf rule, the rivals' turf.
##
## Off for the Python replays (GroundWar.ENABLED = false); built only for
## sessions that ask (live play: ground_war: true).

static var ENABLED := true

const TICK_S := 1.0
const ROUND_S := 2.0
const THINK_S := 30.0
const CONTACT_M := 250.0
const SIGHT_M := 1500.0
const HIDDEN_M := 150.0
const K := 0.011
const SPEED := {"foot": 1.5, "car": 14.0, "truck": 11.0}
const MEN := {"foot": 4, "car": 4, "truck": 8}
const COST := {"foot": 1500, "car": 2500, "truck": 4000}
const CAP := {"org": 5, "rival": 5, "police": 8}
const MAX_SQUADS := 32
const UPKEEP_MIN := 2.0  ## $ per man per minute
const HOSTILE := {"org": ["police", "rival"], "rival": ["police", "org"], "police": ["org", "rival"]}
const DOCTRINE := {"org": "guerrilla", "rival": "guerrilla", "police": "narcotics"}
const MORALE0 := {"org": 0.75, "rival": 0.75, "police": 0.85}
const CONTROL_TAU := 1800.0

class Squad:
	var id: String
	var faction: String
	var kind: String
	var men: int
	var men0: int
	var loadout := {}
	var ammo := 0
	var morale := 0.8
	var x := 0.0
	var y := 0.0
	var route := PackedVector2Array()
	var s := 0.0  ## metres along the route
	var order := {"type": "hold"}
	var tactic := ""  ## the doctrine's move of the moment
	var state := "moving"  ## moving | holding | fighting | routed | gone
	var hidden := false
	var fight = null
	var rounds := 0  ## rounds fought in this contact
	var until := 0.0  ## a tactic's timer (sim seconds)
	var human := false  ## ordered by a human commander (the AI leaves it alone)
	var tag := ""  ## "family": soldiers lent by the Morettis (drawn in their suits)
	var home := Vector2.ZERO

	func pos() -> Vector2:
		return Vector2(x, y)

	func speed() -> float:
		var v: float = GroundWar.SPEED[kind]
		return v * (0.6 if state == "routed" and kind == "foot" else 1.0)

	func dict() -> Dictionary:
		return {"id": id, "faction": faction, "kind": kind, "men": men, "men0": men0, "x": snappedf(x, 0.1),
			"y": snappedf(y, 0.1), "state": state, "order": order.get("type", ""), "tactic": tactic,
			"hidden": hidden, "morale": snappedf(morale, 0.01), "loadout": loadout.duplicate(), "ammo": ammo, "tag": tag,
			"route": Array(route.slice(0, 12)).map(func(p): return [snappedf(p.x, 1.0), snappedf(p.y, 1.0)])}


class Fight:
	var id: int
	var a: Squad
	var b: Squad
	var x: float
	var y: float
	var t0: float
	var surprise := ""  ## faction with the ambush's first volleys
	var cas := {}  ## faction -> men lost
	var arrests := 0
	var rounds := 0
	var over := false


class Commander:
	var faction: String
	var ai := true
	var cash := 0.0  ## Los Cuervos' war chest (the others pay from the session)
	var think_t := 0.0
	var log: Array = []

var sess  ## Session (untyped: no cycle at parse time)
var world: World
var graph: RoadGraph
var rng: PyRandom  ## commanders' choices (seed + 61)
var frng: PyRandom  ## firefights (seed + 67)
var squads: Array = []
var fights: Array = []
var commanders := {}
var control := {}  ## market -> faction -> squad-men presence (decaying)
var events: Array = []  ## [side ("runner" | "law" | "both"), text]
var stakeouts := {}  ## stash id -> police squad id
var tails := {}  ## truck job_id -> police squad id
var hot_spots: Array = []  ## [t, x, y] recent shooting
var arrests_total := 0
var officers_down := 0
var _t := 0.0
var _round_t := 0.0
var _serial := 0
var _fight_serial := 0
var _informant_t := 0.0
var _started := false
var _upkeep_acc := 0.0
var _follow_t := 0.0


func _init(sess_, rng_: PyRandom, frng_: PyRandom) -> void:
	sess = sess_
	world = sess.world
	rng = rng_
	frng = frng_
	var places := []
	for k in world.map.hqs:
		places.append([world.map.hqs[k].x, world.map.hqs[k].y])
	for st in world.map.stashes:
		places.append([st.x, st.y])
	for a in world.airfields:
		places.append([a.x, a.y])
	if world.map.roads.is_empty():
		graph = RoadGraph.tracks(places)
	else:
		graph = RoadGraph.new(world.map.roads, places)
	for f in ["org", "rival", "police"]:
		var c := Commander.new()
		c.faction = f
		c.cash = 20000.0 if f == "rival" else 0.0
		commanders[f] = c
	for m in Economy.MARKETS:
		control[m] = {"org": 0.0, "rival": 0.0, "police": 0.0}


# ================================================================ helpers
func hq(f: String) -> Vector2:
	var k: String = {"org": "org", "rival": "rival", "police": "law"}[f]
	var h = world.map.hqs.get(k)
	return Vector2(h.x, h.y) if h != null else Vector2.ZERO


func arsenal(f: String):
	var k: String = {"org": "org", "rival": "rival", "police": "law"}[f]
	return sess.arsenals.get(k)


func get_squad(id: String):
	for q in squads:
		if q.id == id:
			return q
	return null


func of(f: String) -> Array:
	return squads.filter(func(q): return q.faction == f and q.state != "gone")


static func market_at(x: float, y: float) -> String:
	var best := "town"
	var bd := INF
	for m in Economy.MARKETS:
		if m == "sea":
			continue
		var c: Array = Economy.centre(m)
		var d := PyMath.hypot(c[0] - x, c[1] - y)
		if d < bd:
			bd = d
			best = m
	var sc: Array = Economy.centre("sea")
	if PyMath.hypot(sc[0] - x, sc[1] - y) < bd * 0.8:
		return "sea"
	return best


## How hard a man is to hit here: city blocks, jungle and mangrove give cover;
## vehicles are boxes to shoot at.
func cover(q: Squad) -> float:
	var c := 1.0
	var lu: PackedByteArray = world.map.land_use
	if not lu.is_empty():
		match MapCity.at(lu, q.x, q.y):
			MapCity.URBAN, MapCity.PORT, MapCity.JUNGLE, MapCity.MANGROVE:
				c = 0.6
			MapCity.SWAMP, MapCity.SCRUB, MapCity.FARM:
				c = 0.85
	if q.kind != "foot" and q.state == "moving":
		c *= 1.25
	return c


func safe_zone(q: Squad) -> bool:
	return cover(q) <= 0.6


## Firepower per man: the weapons, the ammunition, the nerve.
func fire(q: Squad) -> float:
	var p := Arsenal.power(q.loadout, q.men)
	if q.ammo <= 0:
		p *= 0.2
	return p * (0.4 + 0.6 * q.morale)


## Lanchester strength: men x fire (square law: numbers count twice).
func strength(q: Squad) -> float:
	return q.men * fire(q)


## The odds `a` has against `b` (square law), > 1 favours a.
func odds(a: Squad, b: Squad) -> float:
	var sa := a.men * a.men * fire(a) / maxf(0.2, cover(a))
	var sb := b.men * b.men * fire(b) / maxf(0.2, cover(b))
	return sa / maxf(0.01, sb)


func can_see(viewer: String, q: Squad) -> bool:
	var r := HIDDEN_M if q.hidden else SIGHT_M
	for o in squads:
		if o.faction == viewer and o.state != "gone" and o.pos().distance_to(q.pos()) < r:
			return true
	if q.hidden:
		return false
	# own places are watched too
	if viewer == "org" and sess.stash_net != null:
		for st in sess.stash_net.live():
			if Vector2(st.x, st.y).distance_to(q.pos()) < SIGHT_M * 0.6:
				return true
	return hq(viewer).distance_to(q.pos()) < SIGHT_M


func visible_to(viewer: String) -> Array:
	return squads.filter(func(q): return q.state != "gone" and (q.faction == viewer or can_see(viewer, q)))


func _say(side: String, text: String) -> void:
	events.append([side, text])


# ================================================================ squads
## Raise a squad: pays for it (money, the task force's funds or the cartel's
## chest) and arms it from the faction's arsenal. Returns the squad or why not.
func recruit(f: String, kind: String, at = null, pay := true):
	if not SPEED.has(kind):
		return "No such unit."
	if of(f).size() >= CAP[f] or squads.size() >= MAX_SQUADS:
		return "No more squads."
	var cost: int = COST[kind]
	if pay:
		if f == "org":
			if sess.money < cost:
				return "Need $%s." % Py.money(cost)
			sess.money -= cost
		elif f == "police":
			if sess.law_funds < cost:
				return "Need $%s in funds." % Py.money(cost)
			sess.law_funds -= cost
		else:
			if commanders.rival.cash < cost:
				return "Los Cuervos are broke."
			commanders.rival.cash -= cost
	_serial += 1
	var q := Squad.new()
	q.faction = f
	q.kind = kind
	q.men = MEN[kind]
	q.men0 = q.men
	q.id = "%s-%d" % [{"org": "S", "rival": "C", "police": "P"}[f], _serial]
	var ars = arsenal(f)
	if ars != null:
		q.loadout = ars.issue(q.men)
		var rounds := mini(ars.ammo, q.men * 90)
		ars.ammo -= rounds
		q.ammo = rounds
	else:
		q.loadout = {"pistol": q.men}
		q.ammo = q.men * 90
	q.morale = MORALE0[f]
	var p: Vector2 = at if at != null else hq(f)
	q.x = p.x
	q.y = p.y
	q.home = hq(f)
	q.state = "holding"
	squads.append(q)
	return q


func disband(q: Squad) -> void:
	var ars = arsenal(q.faction)
	if ars != null:
		ars.give_back(q.loadout)
		ars.ammo += q.ammo
	q.state = "gone"
	squads.erase(q)


## Send a squad somewhere by road.
func go(q: Squad, to: Vector2) -> void:
	q.route = graph.route(q.pos(), to)
	q.s = 0.0
	if q.state not in ["fighting", "routed"]:
		q.state = "moving"


## Orders: patrol_zone {market}, guard {stash|xy}, escort {truck job_id},
## attack {squad id}, raid {stash}, checkpoint {xy}, hold, and the tactics:
## ambush {xy}, melt, harass {squad}, decoy {xy}, stakeout {stash}, tail {job_id},
## buy_bust {stash}.
func order(q: Squad, o: Dictionary) -> String:
	var t := str(o.get("type", ""))
	var target = _target_xy(o)
	match t:
		"hold":
			q.route = PackedVector2Array()
			q.state = "holding" if q.state != "fighting" else q.state
		"melt":
			var safe := _nearest_cover(q.pos())
			go(q, safe)
		"patrol_zone", "guard", "attack", "raid", "checkpoint", "ambush", "harass", "decoy", "stakeout", "buy_bust", "escort", "tail":
			if target == null:
				return "Where?"
			go(q, target)
		_:
			return "Unknown order."
	if t == "raid" and q.faction != "police":
		t = "attack"
		o = o.duplicate()
		o["type"] = t
	q.order = o.duplicate()
	q.tactic = t if t in ["ambush", "melt", "harass", "decoy", "stakeout", "buy_bust", "tail", "checkpoint"] else ""
	q.hidden = t in ["melt", "ambush", "stakeout", "buy_bust"]
	q.until = sess.time + (600.0 if t in ["melt", "harass"] else 1800.0)
	return ""


func _target_xy(o: Dictionary):
	if o.has("x") and o.has("y"):
		return Vector2(float(o.x), float(o.y))
	if o.has("stash") and sess.stash_net != null:
		var st = sess.stash_net.get_stash(str(o.stash))
		if st != null:
			return Vector2(st.x, st.y)
	if o.has("market"):
		var c: Array = Economy.centre(str(o.market))
		return Vector2(c[0], c[1])
	if o.has("squad"):
		var q = get_squad(str(o.squad))
		if q != null:
			return q.pos()
	if o.has("job_id") and sess.stash_net != null:
		for t in sess.stash_net.trucks:
			if t.job_id == int(o.job_id):
				var p: Array = t.pos(sess.time)
				return Vector2(p[0], p[1])
	return null


## A random road node in market m (the patrol's next stop).
func _beat(m: String) -> Vector2:
	var c: Array = Economy.centre(m)
	var cv := Vector2(c[0], c[1])
	var near := []
	for i in graph.road_nodes:
		if graph.nodes[i].distance_to(cv) < 4000.0:
			near.append(graph.nodes[i])
	if near.is_empty():
		return graph.nodes[graph.nearest(cv)] if graph.nodes.size() > 0 else cv
	return near[rng.randint(0, near.size() - 1)]


## The nearest good cover: jungle, mangrove or the barrio (a coarse search).
func _nearest_cover(from: Vector2) -> Vector2:
	var lu: PackedByteArray = world.map.land_use
	if lu.is_empty():
		return from
	var best := from
	var bd := INF
	for r in [300.0, 700.0, 1500.0, 3000.0]:
		for k in 12:
			var a := TAU * k / 12.0
			var p: Vector2 = from + Vector2(cos(a), sin(a)) * r
			if MapCity.at(lu, p.x, p.y) in [MapCity.URBAN, MapCity.JUNGLE, MapCity.MANGROVE]:
				var d := from.distance_to(p)
				if d < bd:
					bd = d
					best = p
		if bd < INF:
			break
	return best


# ================================================================ the world moves
func update(dt: float) -> void:
	if not _started:
		_started = true
		_deploy()
	_t += dt
	_round_t += dt
	if _round_t >= ROUND_S:
		var step := _round_t
		_round_t = 0.0
		_rounds(step)
	if _t < TICK_S:
		return
	var step := _t
	_t = 0.0
	_move(step)
	_contacts()
	_trucks(step)
	_control(step)
	_upkeep(step)
	for f in commanders:
		var c: Commander = commanders[f]
		if f == "rival":
			c.cash += 30.0 * step / 60.0
		if c.ai and sess.time >= c.think_t:
			c.think_t = sess.time + THINK_S
			match f:
				"org":
					_think_org()
				"rival":
					_think_rival()
				"police":
					_think_police()
	_informants(step)
	hot_spots = hot_spots.filter(func(h): return sess.time - h[0] < 900.0)


func _deploy() -> void:
	for f in ["org", "rival"]:
		for k in 2:
			recruit(f, "foot" if k == 0 else "car", null, false)
	for k in 3:
		recruit("police", "car", null, false)


func _move(dt: float) -> void:
	for q in squads.duplicate():
		# a tactic's timer runs out: back to orders
		if q.tactic in ["melt", "harass", "ambush", "decoy", "buy_bust"] and sess.time > q.until and q.fight == null:
			q.hidden = false
			q.tactic = ""
			q.order = {"type": "hold"}
			q.human = false
		if q.state in ["fighting", "gone"] or q.route.size() < 2:
			if q.state == "moving":
				q.state = "holding"
			continue
		q.s += q.speed() * dt
		var p := RoadGraph.along(q.route, q.s)
		q.x = p.x
		q.y = p.y
		if q.s >= RoadGraph.length(q.route):
			q.route = PackedVector2Array()
			if q.state == "routed":
				q.state = "holding"
				q.morale = maxf(q.morale, 0.5)
				if q.men * 2 <= q.men0 and q.pos().distance_to(q.home) < 300.0:
					disband(q)  # what's left of it stands down at base
					continue
				if q.men * 2 <= q.men0:
					go(q, q.home)
					q.state = "routed"
					continue
			else:
				q.state = "holding"
			_arrived(q)


func _arrived(q: Squad) -> void:
	var t: String = q.order.get("type", "")
	if t == "raid" and q.faction == "police":
		_breach(q)
	elif t == "patrol_zone" and not q.human:
		# walk the beat: somewhere else in the market next
		go(q, _beat(str(q.order.get("market", "town"))))


# ================================================================ firefights
func _hostile(a: Squad, b: Squad) -> bool:
	if not HOSTILE[a.faction].has(b.faction):
		return false
	# a truce with Los Cuervos (the boss's order) keeps the guns down
	if [a.faction, b.faction].has("rival") and [a.faction, b.faction].has("org") and _truce():
		return false
	return true


func _truce() -> bool:
	if sess.nights == null or sess.nights.season == null or sess.nights.season.rival == null:
		return false
	return sess.nights.season.rival.truce_nights > 0


## Who opens fire when two squads meet: the ambusher, else anyone but police
## facing a squad that isn't shooting (they call on it to surrender first).
func _contacts() -> void:
	var all := squads.duplicate()
	for i in all.size():
		var a: Squad = all[i]
		if a.state in ["gone", "routed"] or a.fight != null:
			continue
		for j in range(i + 1, all.size()):
			var b: Squad = all[j]
			if a.state == "gone" or a.fight != null:
				break
			if b.state in ["gone", "routed"] or b.fight != null or not _hostile(a, b):
				continue
			var d := a.pos().distance_to(b.pos())
			if d > CONTACT_M:
				continue
			# hidden squads are found only close in; they choose whether to open up
			var a_sees := not b.hidden or d < HIDDEN_M
			var b_sees := not a.hidden or d < HIDDEN_M
			if not a_sees and not b_sees:
				continue
			var cop: Squad = a if a.faction == "police" else (b if b.faction == "police" else null)
			if cop != null:
				var perp: Squad = b if cop == a else a
				if perp.tactic != "ambush" and perp.hidden and not (cop == a and a_sees or cop == b and b_sees):
					continue  # they never saw him
				if perp.tactic != "ambush" and odds(cop, perp) >= 2.5 and not _will_fight(perp, cop):
					_surrender(perp, cop)
					continue
				if perp.tactic == "melt" or (perp.faction != "police" and odds(perp, cop) < 0.5 and perp.tactic != "ambush"):
					if safe_zone(perp):
						continue  # melted into the crowd: they walk past
			_open(a, b)


## A guerrilla fights when it's worth it: an ambush, good odds, or cornered.
func _will_fight(perp: Squad, cop: Squad) -> bool:
	if perp.tactic == "ambush":
		return true
	if odds(perp, cop) >= 0.7:
		return true
	return not safe_zone(perp) and frng.random() < 0.3


func _surrender(perp: Squad, cop: Squad) -> void:
	var n := perp.men
	_arrest(perp, cop, n)
	_say("both", "%s surrendered to %s: %d arrested" % [perp.id, cop.id, n])


func _open(a: Squad, b: Squad) -> void:
	_fight_serial += 1
	var f := Fight.new()
	f.id = _fight_serial
	f.a = a
	f.b = b
	f.x = (a.x + b.x) / 2
	f.y = (a.y + b.y) / 2
	f.t0 = sess.time
	for q in [a, b]:
		if q.tactic in ["ambush", "buy_bust"] and q.hidden:
			f.surprise = q.faction
			var other: Squad = b if q == a else a
			other.morale = maxf(0.0, other.morale - 0.2)
	for q in [a, b]:
		q.fight = f
		q.state = "fighting"
		q.rounds = 0
		q.hidden = false
	f.cas = {a.faction: 0, b.faction: 0}
	fights.append(f)
	hot_spots.append([sess.time, f.x, f.y])
	var place := _place_name(f.x, f.y)
	_say("both", "Shots fired %s: %s vs %s%s" % [place, a.id, b.id, " - an ambush!" if f.surprise != "" else ""])


func _place_name(x: float, y: float) -> String:
	if sess.stash_net != null:
		for st in sess.stash_net.stashes:
			if PyMath.hypot(st.x - x, st.y - y) < 600:
				return "at " + st.name
	var af = world.airfield_at(x, y, 1500.0)
	if af != null:
		return "near " + af.name
	return "in the %s" % market_at(x, y)


## One 2 s round of every open fight.
func _rounds(step: float) -> void:
	for f in fights.duplicate():
		if f.over:
			continue
		f.rounds += 1
		var a: Squad = f.a
		var b: Squad = f.b
		if a.state == "gone" or b.state == "gone" or a.pos().distance_to(b.pos()) > CONTACT_M * 1.6:
			_end(f)
			continue
		var la := _losses(b, a, f)
		var lb := _losses(a, b, f)
		for pair in [[a, la, b], [b, lb, a]]:
			var q: Squad = pair[0]
			var lost: int = pair[1]
			var enemy: Squad = pair[2]
			if lost > 0:
				q.men -= lost
				f.cas[q.faction] += lost
				q.morale = maxf(0.0, q.morale - 0.6 * float(lost) / q.men0)
				_drop_weapons(q, lost, enemy)
			if enemy.men > 1.8 * q.men:
				q.morale = maxf(0.0, q.morale - 0.03)
			q.ammo = maxi(0, q.ammo - q.men * 6)
			q.rounds += 1
		if f.surprise != "" and f.rounds >= 2:
			f.surprise = ""
		# hit and run: two rounds, then gone
		for q in [a, b]:
			if q.tactic in ["harass", "ambush"] and q.rounds >= 2 and q.faction != "police" and q.men > 0:
				var other: Squad = b if q == a else a
				if odds(q, other) < 1.5 or q.tactic == "harass":
					_break_off(q, f, "hit and run")
		if f.over:
			continue
		for q in [a, b]:
			if q.men <= 0 or q.men <= int(0.6 * q.men0) and q.morale < 0.5 or q.morale < 0.3:
				_rout(q, f)
				break


func _losses(shooter: Squad, target: Squad, f: Fight) -> int:
	if shooter.men <= 0 or target.men <= 0:
		return 0
	# police hold fire until fired upon, except on a breach
	if shooter.faction == "police" and f.rounds <= 1 and f.surprise != "police" and shooter.order.get("type", "") != "raid":
		return 0
	var mult := 2.5 if f.surprise == shooter.faction else 1.0
	var exp := K * shooter.men * fire(shooter) * cover(target) * mult * ROUND_S
	# vehicles: only RPGs and machine guns stop them quickly
	if target.kind != "foot" and not Arsenal.anti_vehicle(shooter.loadout) and not shooter.loadout.has("mg"):
		exp *= 0.7
	var p := clampf(exp / target.men, 0.0, 0.9)
	var n := 0
	for i in target.men:
		if frng.random() < p:
			n += 1
	return n


## Men who fall drop their guns: the police seize them, gangs pick them up.
func _drop_weapons(q: Squad, lost: int, enemy: Squad) -> void:
	var taken := {}
	var left := lost
	for t in Arsenal.ORDER.duplicate():
		var k: int = int(q.loadout.get(t, 0))
		if k > 0 and left > 0:
			var n := mini(k, left)
			q.loadout[t] = k - n
			taken[t] = n
			left -= n
	if taken.is_empty():
		return
	if enemy.faction == "police":
		if sess.arsenals.has("law"):
			sess.arsenals.law.take_seized(taken)
	else:
		var ars = arsenal(enemy.faction)
		if ars != null:
			ars.add_all(taken)


func _break_off(q: Squad, f: Fight, why: String) -> void:
	q.fight = null
	q.state = "moving"
	q.hidden = true
	q.tactic = "melt"
	q.until = sess.time + 600.0
	go(q, _nearest_cover(q.pos()))
	var other: Squad = f.b if q == f.a else f.a
	other.fight = null
	other.state = "holding"
	f.over = true
	fights.erase(f)
	_say("both", "%s broke contact (%s)" % [q.id, why])


func _rout(q: Squad, f: Fight) -> void:
	var winner: Squad = f.b if q == f.a else f.a
	f.over = true
	fights.erase(f)
	q.fight = null
	winner.fight = null
	winner.state = "holding"
	winner.morale = minf(1.0, winner.morale + 0.1)
	if q.men <= 0:
		_gone(q)
	elif winner.faction == "police":
		# a cordon lets nobody out; otherwise some get away into cover
		var escape := 0.0 if winner.order.get("perimeter", false) else (0.6 if safe_zone(q) else 0.35)
		var fled := 0
		for i in q.men:
			if frng.random() < escape:
				fled += 1
		_arrest(q, winner, q.men - fled)
		if q.men > 0:
			q.state = "routed"
			q.hidden = true
			go(q, _nearest_cover(q.pos()))
	else:
		q.state = "routed"
		go(q, q.home)
	var lost_p: int = f.cas.get("police", 0)
	if lost_p > 0:
		officers_down += lost_p
		if "org" in [q.faction, winner.faction]:
			var c = sess.police.case("runner")
			c.suspicion = minf(100.0, c.suspicion + 8.0 * lost_p)
		_say("law", "Officers down: %d. Every unit to %s" % [lost_p, _place_name(f.x, f.y)])
	# turf: winning a gang fight takes the street
	if winner.faction != "police" and q.faction != "police":
		var m := market_at(f.x, f.y)
		control[m][winner.faction] += 60.0 * winner.men
	_say("both", "%s routed %s%s" % [winner.id, q.id, (" - %d arrested" % f.arrests) if f.arrests else ""])


func _arrest(q: Squad, cop: Squad, n: int) -> void:
	n = mini(n, q.men)
	if n <= 0:
		return
	_drop_weapons(q, n, cop)
	q.men -= n
	arrests_total += n
	if cop.fight != null:
		cop.fight.arrests += n
	sess.police.score["arrests"] = sess.police.score.get("arrests", 0) + n
	if q.faction == "org":
		# men in custody talk: evidence and heat on the organisation
		sess.police.case("runner").suspicion = minf(100.0, sess.police.case("runner").suspicion + 3.0 * n)
		if sess.stash_net != null and cop.order.get("type", "") != "raid":
			var live: Array = sess.stash_net.live()
			if not live.is_empty() and frng.random() < 0.25 * n:
				var st: Dictionary = live[frng.randint(0, live.size() - 1)]
				st.intel += 20.0
				_say("law", "A prisoner talked: %s" % st.name)
	if q.men <= 0:
		_gone(q)


func _gone(q: Squad) -> void:
	q.state = "gone"
	if q.fight != null:
		q.fight.over = true
		fights.erase(q.fight)
	squads.erase(q)
	var ars = arsenal(q.faction)
	if ars != null:
		ars.ammo += q.ammo


func _end(f: Fight) -> void:
	f.over = true
	fights.erase(f)
	for q in [f.a, f.b]:
		q.fight = null
		if q.state == "fighting":
			q.state = "holding"


# ================================================================ raids
## A police raid squad at the door: burns the stash (and the armoury in it)
## unless the guards are still fighting.
func _breach(q: Squad) -> void:
	var id := str(q.order.get("stash", ""))
	if id == "" or sess.stash_net == null:
		return
	var st = sess.stash_net.get_stash(id)
	if st == null or st.burned:
		q.order = {"type": "hold"}
		return
	if q.pos().distance_to(Vector2(st.x, st.y)) > 200.0:
		return
	var cordon = get_squad(str(q.order.get("cordon", "")))
	if cordon != null and cordon.pos().distance_to(Vector2(st.x, st.y)) > 500.0 and sess.time - float(q.order.get("t", 0.0)) < 300.0:
		return  # wait for the perimeter (not forever)
	for g in squads:
		if g.faction == "org" and g.state != "gone" and g.pos().distance_to(Vector2(st.x, st.y)) < CONTACT_M:
			return  # the guards first; the fight decides
	st.intel = maxf(st.intel, StashNet.KNOWN_HEAT)
	sess._raid(id)
	q.order = {"type": "hold"}
	q.tactic = ""


# ================================================================ trucks on the road
## Trucks meet checkpoints, tails and Los Cuervos. Returns the StashNet style
## results [[truck, "seized" | "hijacked", why], ...] for the session.
func truck_contacts() -> Array:
	var out := []
	if sess.stash_net == null:
		return out
	# a decoy car pulled over: the checkpoint wastes its time on it
	for d in squads:
		if d.faction != "org" or d.tactic != "decoy" or d.state == "gone":
			continue
		for q in squads:
			if q.faction == "police" and q.tactic == "checkpoint" and q.fight == null and q.pos().distance_to(d.pos()) < 150.0:
				q.tactic = ""
				q.order = {"type": "hold"}
				q.until = sess.time + 180.0
				d.tactic = ""
				d.order = {"type": "hold"}
				_say("law", "%s pulled over a car: clean. A decoy?" % q.id)
				break
	for t in sess.stash_net.trucks.duplicate():
		var p: Array = t.pos(sess.time)
		var tp := Vector2(p[0], p[1])
		if sess.time - t.t0 < StashNet.TRUCK_LOAD_S:
			continue
		var escort = Py.first(squads, func(q): return (q.faction == "org" and q.order.get("type", "") == "escort"
			and int(q.order.get("job_id", -1)) == t.job_id and q.state != "gone"))
		for q in squads.duplicate():
			if q.state in ["gone", "routed"] or q.pos().distance_to(tp) > 120.0:
				continue
			if q.faction == "police" and q.tactic == "tail":
				continue  # following, not stopping
			if q.faction == "police" and q.tactic in ["checkpoint", ""] and q.state != "fighting":
				if escort != null and escort.pos().distance_to(tp) < 600.0:
					if escort.fight == null:
						escort.tactic = "ambush"  # they open up on the checkpoint
						escort.hidden = true
						_open(escort, q)
					t.t0 += TICK_S  # the truck waits while it's fought out
				elif _should_tail(q, t):
					q.tactic = "tail"
					q.order = {"type": "tail", "job_id": t.job_id}
					tails[t.job_id] = [q.id, t.stash]
					_say("law", "%s is tailing a truck instead of stopping it" % q.id)
				elif t.waved or (sess.agency != null and sess.agency.waves_through(frng)):
					if not t.waved:
						_say("law", "%s was told to let a truck through: orders from Washington" % q.id)
					t.waved = true
				else:
					out.append([t, "seized", "a %s checkpoint" % q.id])
				break
			if q.faction == "rival" and q.tactic == "ambush" and (escort == null or escort.pos().distance_to(tp) > 600.0):
				out.append([t, "hijacked", "Los Cuervos"])
				commanders.rival.cash += t.pay * 0.5
				if not t.weapons.is_empty():
					arsenal("rival").add_all(t.weapons)
				q.tactic = ""
				q.hidden = false
				break
	return out


## Tail a truck when we don't know where it's going: the stash is worth more.
func _should_tail(q: Squad, t) -> bool:
	var st = sess.stash_net.get_stash(t.stash)
	return st != null and StashNet.suspicion(st) < StashNet.KNOWN_HEAT and sess.police.controller != "human" and rng.random() < 0.6


func _trucks(dt: float) -> void:
	if sess.stash_net == null:
		return
	_follow_t += dt
	if _follow_t >= 5.0:
		_follow_t = 0.0
		for q in squads:
			if q.faction == "org" and q.order.get("type", "") == "escort" and q.fight == null:
				var t = Py.first(sess.stash_net.trucks, func(tt): return tt.job_id == int(q.order.get("job_id", -1)))
				if t == null:
					q.order = {"type": "hold"}
					continue
				var p: Array = t.pos(sess.time)
				if q.pos().distance_to(Vector2(p[0], p[1])) > 250.0:
					go(q, Vector2(p[0], p[1]))
			# a raid team at the door goes in once the cordon is up
			if q.faction == "police" and q.order.get("type", "") == "raid" and q.fight == null and q.route.size() < 2:
				_breach(q)
	for jid in tails.keys():
		var q = get_squad(tails[jid][0])
		var st = sess.stash_net.get_stash(tails[jid][1])
		var t = Py.first(sess.stash_net.trucks, func(tt): return tt.job_id == jid)
		if q == null or st == null:
			tails.erase(jid)
			continue
		var arrived: bool = t == null or t.frac(sess.time) >= 0.97
		if arrived:
			tails.erase(jid)
			q.tactic = ""
			q.order = {"type": "hold"}
			# close enough behind it to see the door: now we know the house
			if q.pos().distance_to(Vector2(st.x, st.y)) < 1500.0:
				st.intel = maxf(st.intel, StashNet.KNOWN_HEAT + 15.0)
				_say("law", "%s followed a truck to %s" % [q.id, st.name])
			continue
		# shadow it along its own road, a few hundred metres back
		var d: float = clampf((sess.time - t.t0 - StashNet.TRUCK_LOAD_S) / maxf(1.0, t.dur - StashNet.TRUCK_LOAD_S), 0.0, 1.0)
		var lag: PackedVector2Array = t.route if t.route.size() >= 2 else PackedVector2Array([Vector2(t.x0, t.y0), Vector2(t.x1, t.y1)])
		var spot := RoadGraph.along(lag, maxf(0.0, d * RoadGraph.length(lag) - 350.0))
		if q.pos().distance_to(spot) < 900.0:
			q.x = spot.x
			q.y = spot.y
			q.route = PackedVector2Array()
			q.state = "moving"
		elif q.route.size() < 2:
			go(q, spot)
	# stakeouts watch: a watched stash warms up
	for id in stakeouts.keys():
		var q = get_squad(stakeouts[id])
		var st = sess.stash_net.get_stash(id)
		if q == null or st == null or st.burned:
			stakeouts.erase(id)
			continue
		if q.pos().distance_to(Vector2(st.x, st.y)) < 600.0:
			st.intel += 1.5 * dt / 60.0 + (0.3 if sess.stash_net.trucks_to(id).size() > 0 else 0.0)


## Informants: now and then a controlled buy gives away a stash.
func _informants(dt: float) -> void:
	if sess.stash_net == null:
		return
	_informant_t += dt
	if _informant_t < 600.0:
		return
	_informant_t = 0.0
	var p := 0.15 + (0.2 if sess.upgrades["law"].has("informants") else 0.0) - (0.1 if sess.upgrades["runner"].has("bug_sweep") else 0.0)
	if rng.random() < p:
		var live: Array = sess.stash_net.live()
		if not live.is_empty():
			var st: Dictionary = live[rng.randint(0, live.size() - 1)]
			st.intel += 18.0
			_say("law", "Controlled buy by an informant: product from %s" % st.name)


# ================================================================ turf and money
func _control(dt: float) -> void:
	var k := exp(-dt / CONTROL_TAU)
	for m in control:
		for f in control[m]:
			control[m][f] *= k
	for q in squads:
		if q.state != "gone":
			control[market_at(q.x, q.y)][q.faction] += q.men * dt / 60.0


## Los Cuervos' share of the streets in market m (0..1), from who's out there.
func rival_share(m: String) -> float:
	var c: Dictionary = control[m]
	var tot: float = c.org + c.rival + 0.5 * c.police
	return c.rival / tot if tot > 1.0 else -1.0


func org_share(m: String) -> float:
	var c: Dictionary = control[m]
	var tot: float = c.org + c.rival + 0.5 * c.police
	return c.org / tot if tot > 1.0 else -1.0


## The turf the markets see: the season's (or the default) nudged by the streets.
func turf(base: Dictionary) -> Dictionary:
	var out := {}
	for m in Economy.MARKETS:
		var b: float = float(base.get(m, 0.15 if m == "town" else 0.3))
		var r := rival_share(m)
		out[m] = b if r < 0.0 else clampf(0.5 * b + 0.5 * r, 0.0, 1.0)
	return out


## The season's night-end nudge (the ground_turf rule): the rivals' share
## against the organisation's in each HQ zone, at most +-0.06.
func turf_delta(zone: String) -> float:
	var r := rival_share(zone)
	var o := org_share(zone)
	if r < 0.0:
		return 0.0
	return clampf((r - o) * 0.1, -0.06, 0.06)


func _upkeep(dt: float) -> void:
	for q in squads:
		var c: float = q.men * UPKEEP_MIN * dt / 60.0
		if q.faction == "org":
			_upkeep_acc += c
		elif q.faction == "police":
			sess.law_funds -= c * 0.5
		else:
			commanders.rival.cash -= c


	if _upkeep_acc >= 1.0:
		sess.money -= int(_upkeep_acc)
		_upkeep_acc -= int(_upkeep_acc)


func positions(f: String) -> Array:
	return of(f).map(func(q): return [q.x, q.y])


# ================================================================ AI commanders
func _free(f: String) -> Array:
	return of(f).filter(func(q): return not q.human and q.fight == null and q.state != "routed")


## The organisation's lieutenant (guerrilla): guard the hottest stash, escort
## the trucks (decoys on other roads), ambush raids, melt away when outgunned,
## harass checkpoints, hold the streets where Los Cuervos push.
func _think_org() -> void:
	var mine := _free("org")
	var cops := visible_to("org").filter(func(q): return q.faction == "police")
	# outgunned: melt away
	for q in mine:
		for c in cops:
			if c.pos().distance_to(q.pos()) < 900.0 and odds(q, c) < 0.7 and q.tactic != "melt":
				order(q, {"type": "melt"})
				_log("org", "%s melts away from %s" % [q.id, c.id])
				break
	mine = mine.filter(func(q): return q.tactic != "melt")
	# a raid coming: ambush it on the road
	for c in cops:
		if c.order.get("type", "") == "raid" and c.route.size() >= 2 and not mine.is_empty():
			var best = _pick(mine, func(q): return strength(q) - q.pos().distance_to(c.pos()) / 1000.0)
			if best != null and odds(best, c) >= 0.6:
				var at := graph.chokepoint(c.route, 600.0)
				order(best, {"type": "ambush", "x": at.x, "y": at.y})
				mine.erase(best)
				_log("org", "%s sets an ambush for %s" % [best.id, c.id])
	# escort each truck; a decoy when checkpoints are out
	if sess.stash_net != null:
		for t in sess.stash_net.trucks:
			if mine.is_empty():
				break
			if not squads.any(func(q): return q.faction == "org" and int(q.order.get("job_id", -1)) == t.job_id):
				var e = _pick(mine, func(q): return -Vector2(t.x0, t.y0).distance_to(q.pos()) + (5000.0 if q.kind != "foot" else 0.0))
				if e != null:
					order(e, {"type": "escort", "job_id": t.job_id})
					mine.erase(e)
			var checkpoints := cops.filter(func(c): return c.tactic == "checkpoint")
			if not checkpoints.is_empty() and not mine.is_empty():
				var d = _pick(mine.filter(func(q): return q.kind != "foot"), func(q): return 0.0)
				if d != null:
					var other: Array = sess.stash_net.live().filter(func(s): return s.id != t.stash)
					if not other.is_empty():
						var st: Dictionary = other[rng.randint(0, other.size() - 1)]
						order(d, {"type": "decoy", "x": st.x, "y": st.y})
						mine.erase(d)
		# guard the stash that matters most
		var hot = _pick(sess.stash_net.live(), func(s): return s.heat + (100.0 if arsenal("org") != null and arsenal("org").cache == s.id else 0.0))
		if hot != null and not squads.any(func(q): return q.faction == "org" and q.order.get("stash", "") == hot.id) and not mine.is_empty():
			var g = _pick(mine, func(q): return -q.pos().distance_to(Vector2(hot.x, hot.y)))
			order(g, {"type": "guard", "stash": hot.id})
			mine.erase(g)
	# harass a checkpoint when the odds are fair
	for c in cops.filter(func(c): return c.tactic == "checkpoint"):
		if mine.is_empty():
			break
		var h = _pick(mine, func(q): return odds(q, c))
		if h != null and odds(h, c) >= 0.8 and rng.random() < 0.3:
			order(h, {"type": "harass", "x": c.x, "y": c.y})
			mine.erase(h)
	# the rest hold the street where Los Cuervos push hardest
	for q in mine:
		if q.order.get("type", "hold") == "hold" or q.route.size() < 2 and q.order.get("type", "") == "patrol_zone":
			var m := _contested("org")
			order(q, {"type": "patrol_zone", "market": m})
	_recruit_ai("org", sess.money > 12000)


## Los Cuervos (guerrilla, greedier): ambush the organisation's trucks, raid
## its stashes when the odds are good, hold their own turf.
func _think_rival() -> void:
	var mine := _free("rival")
	var orgs := visible_to("rival").filter(func(q): return q.faction == "org")
	var cops := visible_to("rival").filter(func(q): return q.faction == "police")
	for q in mine.duplicate():
		for c in cops:
			if c.pos().distance_to(q.pos()) < 900.0 and odds(q, c) < 0.8:
				order(q, {"type": "melt"})
				mine.erase(q)
				break
	if sess.stash_net != null and not _truce():
		for t in sess.stash_net.trucks:
			if mine.is_empty() or rng.random() > 0.5:
				break
			var r = mine[0]
			var route := graph.route(Vector2(t.x0, t.y0), Vector2(t.x1, t.y1))
			var at := graph.chokepoint(route, 1000.0)
			order(r, {"type": "ambush", "x": at.x, "y": at.y})
			mine.erase(r)
		var known: Array = sess.stash_net.live().filter(func(s): return s.heat >= 20.0)
		for st in known:
			if mine.is_empty():
				break
			var guards := orgs.filter(func(q): return q.pos().distance_to(Vector2(st.x, st.y)) < 800.0)
			var mine_str := Py.sum_by(mine, func(q): return strength(q))
			var their := Py.sum_by(guards, func(q): return strength(q))
			if mine_str > 1.4 * their and rng.random() < 0.25:
				var a = mine[0]
				order(a, {"type": "attack", "stash": st.id})
				mine.erase(a)
	for q in mine:
		if q.order.get("type", "hold") == "hold":
			var m := _contested("rival")
			order(q, {"type": "patrol_zone", "market": m})
	_recruit_ai("rival", commanders.rival.cash > 8000)


## The narcotics task force: stake out what it suspects, tail trucks to what
## it doesn't know, checkpoints on the trucks' roads, saturate where the
## shooting was, buy-busts, and raids with a perimeter first.
func _think_police() -> void:
	var mine := _free("police")
	if sess.stash_net != null:
		var live: Array = sess.stash_net.live()
		# raid: a cordon, then the entry team
		var ripe = _pick(live.filter(func(s): return StashNet.suspicion(s) >= 55.0), func(s): return StashNet.suspicion(s))
		if ripe != null and mine.size() >= 2 and not squads.any(func(q): return q.order.get("type", "") == "raid"):
			var guards := of("org").filter(func(q): return q.pos().distance_to(Vector2(ripe.x, ripe.y)) < 800.0)
			var team = _pick(mine, func(q): return strength(q))
			var cordon = _pick(mine.filter(func(q): return q != team), func(q): return -q.pos().distance_to(Vector2(ripe.x, ripe.y)))
			var need := Py.sum_by(guards, func(q): return strength(q)) * 1.3
			if team != null and strength(team) + (strength(cordon) if cordon else 0.0) >= need:
				if cordon != null:
					order(cordon, {"type": "checkpoint", "x": ripe.x + 250.0, "y": ripe.y + 250.0, "perimeter": true})
					mine.erase(cordon)
				order(team, {"type": "raid", "stash": ripe.id, "perimeter": cordon != null, "cordon": cordon.id if cordon else "", "t": sess.time})
				mine.erase(team)
				_log("police", "Raid on %s: %s%s" % [ripe.name, team.id, (", cordon " + cordon.id) if cordon else ""])
		# stake out the suspected ones
		for st in live.filter(func(s): return StashNet.suspicion(s) >= 10.0 and StashNet.suspicion(s) < 55.0):
			if mine.is_empty():
				break
			if stakeouts.has(st.id):
				continue
			var q = _pick(mine.filter(func(q): return q.kind == "car"), func(q): return -q.pos().distance_to(Vector2(st.x, st.y)))
			if q != null:
				order(q, {"type": "stakeout", "stash": st.id})
				stakeouts[st.id] = q.id
				mine.erase(q)
		# a buy-bust at a known house
		var known := live.filter(func(s): return StashNet.suspicion(s) >= StashNet.KNOWN_HEAT)
		if not known.is_empty() and not mine.is_empty() and rng.random() < 0.2:
			var st: Dictionary = known[rng.randint(0, known.size() - 1)]
			var q = mine.back()
			order(q, {"type": "buy_bust", "stash": st.id})
			mine.erase(q)
		# checkpoints on the trucks' roads (strip to stash)
		for t in sess.stash_net.trucks:
			if mine.is_empty():
				break
			if tails.has(t.job_id) or squads.any(func(q): return q.faction == "police" and q.tactic == "checkpoint" and int(q.order.get("job_id", -1)) == t.job_id):
				continue
			if rng.random() < 0.5:
				var route := graph.route(Vector2(t.x0, t.y0), Vector2(t.x1, t.y1))
				var p: Array = t.pos(sess.time)
				var ahead := RoadGraph.along(route, clampf(Vector2(p[0], p[1]).distance_to(Vector2(t.x0, t.y0)) + 1500.0, 0.0, RoadGraph.length(route)))
				var q = _pick(mine, func(q): return -q.pos().distance_to(ahead))
				if q != null and q.pos().distance_to(ahead) / q.speed() < (1.0 - t.frac(sess.time)) * t.dur:
					order(q, {"type": "checkpoint", "x": ahead.x, "y": ahead.y, "job_id": t.job_id})
					mine.erase(q)
	# saturation: where the shooting was
	for h in hot_spots:
		if mine.is_empty():
			break
		var q = _pick(mine, func(q): return -q.pos().distance_to(Vector2(h[1], h[2])))
		order(q, {"type": "patrol_zone", "x": h[1], "y": h[2], "market": market_at(h[1], h[2])})
		mine.erase(q)
	for q in mine:
		if q.order.get("type", "hold") == "hold":
			var m := _contested("police")
			order(q, {"type": "patrol_zone", "market": m})
	var swat := arsenal("police") != null and (int(arsenal("police").stock.mg) > 0 or int(arsenal("police").stock.rifle) >= 8)
	_recruit_ai("police", sess.law_funds > 6000.0, "truck" if swat and officers_down > 0 else "car")


func _recruit_ai(f: String, rich: bool, kind := "") -> void:
	if not rich or of(f).size() >= CAP[f]:
		return
	var k := kind if kind != "" else ("car" if rng.random() < 0.5 else "foot")
	var ars = arsenal(f)
	if ars != null and ars.count() * 2 < MEN[k]:
		# nobody sends men out unarmed: buy guns first (the dealer, or police procurement)
		var price: int = 4 * int(Arsenal.TIERS.rifle.price * (1.0 if f == "police" else 1.4))
		if f == "org" and sess.money > price + 15000:
			sess.money -= price
		elif f == "police" and sess.law_funds > price + 5000.0:
			sess.law_funds -= price
		elif f == "rival" and commanders.rival.cash > price + 5000.0:
			commanders.rival.cash -= price
		else:
			return
		ars.add("rifle", 4)
		_log(f, "Bought four rifles")
		if ars.count() * 2 < MEN[k]:
			return
	var q = recruit(f, k)
	if q is Squad:
		_log(f, "Raised %s (%s, %s)" % [q.id, k, Arsenal.describe(q.loadout)])


## The market where the enemy is strongest against us.
func _contested(f: String) -> String:
	var best := "town"
	var bv := -INF
	for m in control:
		var c: Dictionary = control[m]
		var enemy := 0.0
		for e in HOSTILE[f]:
			enemy += c[e]
		var v: float = enemy - c[f] + rng.random() * 5.0
		if v > bv:
			bv = v
			best = m
	return best


func _pick(arr: Array, score: Callable):
	var best = null
	var bs := -INF
	for x in arr:
		var s: float = score.call(x)
		if s > bs:
			bs = s
			best = x
	return best


func _log(f: String, text: String) -> void:
	commanders[f].log.append([sess.time, text])
	Py.keep_last(commanders[f].log, 20)
	if f == "police":
		_say("law", text)
	elif f == "org":
		_say("runner", text)


# ================================================================ views
func snapshot(viewer: String) -> Dictionary:
	var vis := visible_to(viewer)
	return {
		"squads": vis.map(func(q): return q.dict()),
		"fights": fights.map(func(f): return {"id": f.id, "x": snappedf(f.x, 1.0), "y": snappedf(f.y, 1.0),
			"a": f.a.id, "b": f.b.id, "cas": f.cas.duplicate(), "age": snappedf(sess.time - f.t0, 0.1)}),
		"control": control.duplicate(true),
		"commander": {"ai": commanders[viewer].ai, "log": commanders[viewer].log.slice(-6).map(func(l): return l[1]),
			"cash": int(commanders.rival.cash) if viewer == "rival" else null},
		"arrests": arrests_total, "officers_down": officers_down,
	}
