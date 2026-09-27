class_name Logistics
extends RefCounted
## Logistics: product and cash are somewhere, and moving them is the job.
##
##   - product sits in a stash house (the one its load was trucked to). A
##     dealer sells only what's in a stash in his own market; a bulk buyer
##     takes delivery at its meet (the Morettis' social club in town, the
##     Company's plane at the nearest strip, Los Cuervos' hacienda), so the lot goes out
##     by truck and the money comes back by truck
##   - street money piles up where it's made. Wages, upgrades, lawyers and
##     loads are paid from the organisation's HQ (Session.money), so the cash
##     has to be trucked home - or flown: cash bags weigh (about $4,500 a
##     pound in street bills) and ride in the aircraft
##   - the growers and the connection want cash on the strip: an own load is
##     paid from the cash aboard, so the pilot flies money out and product in
##   - every truck is a StashNet truck: the task force's roadblocks and
##     checkpoints stop it (product and cash forfeited), Los Cuervos' ambushes
##     take it, an escort squad can fight it through, a driver on the payroll
##     can talk his way past. A raided stash loses what's in it, cash too.
##
## Off (null) unless the session asks: then the trade's stock is one pool and
## money is money, as before.

const CASH_PER_LB := 4500.0  ## street money, mostly fives to twenties
const HQ := "hq"
const CHECKPOINT_M := 250.0  ## a checkpoint this close to the road stops what comes down it
const AI_CASH_HOME := 8000.0  ## the organisation's AI batches a stash's cash home past this (fewer, fatter trucks)
const AI_CASH_SHORT := 3000.0  ## ... or past this when the safe can't meet the payroll
const AI_MOVE_EVERY_S := 600.0  ## and moves product at most this often
const AI_PICKUP_S := 1200.0  ## the regular pickup: a stash's cash ($1,000+) that has sat this long goes home
const MEETS := {
	"family": {"name": "the Morettis' social club", "market": "town"},
	"agency": {"name": "the Company's plane", "market": "north"},  ## it lands where the goods are (meet_pos)
	"rival": {"name": "Hacienda Los Cuervos", "market": "west"},
}

var sess
var stock := {}  ## stash id -> {good: lb}
var cash := {}  ## stash id -> $ (the HQ's is Session.money)
var cash_since := {}  ## stash id -> when its cash started piling up (the AI's pickups)
var aboard := 0  ## $ in cash bags in the aircraft
var convoys := {}  ## truck job_id -> {kind: move|buy|cash_back, from, to, buyer, good, lb, cash}
var lost := {"product": 0.0, "cash": 0}  ## what trucks, raids and busts cost us
var lost_by := {"seized": 0, "hijacked": 0, "raided": 0, "bust": 0}  ## ... the cash, by how
var last := ""
var _t := 0.0
var _watch_t := 0.0
var _move_t := -1e9  ## the last product move (the AI waits AI_MOVE_EVERY_S between them)
var _item_id := 0


func _init(sess_) -> void:
	sess = sess_
	for st in sess.stash_net.stashes:
		stock[st.id] = {"cocaine": 0.0, "marijuana": 0.0}
		cash[st.id] = 0.0
	# what the trade already holds starts in the stash nearest the HQ
	var home := nearest_stash(hq_pos())
	for g in Trade.GOODS:
		stock[home][g] = float(sess.trade.stock[g])
	sess.bus.subscribe("stash_raided", func(ev): _raided(str(ev.data.get("stash", ""))))


# ------------------------------------------------------------------ places
func hq_pos() -> Vector2:
	var h: Dictionary = sess.world.map.hqs.get("org", {})
	return Vector2(float(h.get("x", 0.0)), float(h.get("y", 0.0)))


## The airstrip nearest the HQ: where cash bags come off the aircraft.
func hq_strip() -> String:
	var p := hq_pos()
	var best := ""
	var bd := INF
	for af in sess.world.airfields:
		if af.kind == "foreign":
			continue
		var d := Vector2(af.x, af.y).distance_to(p)
		if d < bd:
			bd = d
			best = af.code
	return best


func nearest_stash(p: Vector2) -> String:
	var live: Array = sess.stash_net.live()
	if live.is_empty():
		live = sess.stash_net.stashes
	return Py.min_by(live, func(st): return Vector2(st.x, st.y).distance_to(p)).id


func pos(site: String) -> Vector2:
	if site == HQ:
		return hq_pos()
	if MEETS.has(site):
		if site == "rival" and sess.world.map.hqs.has("rival"):
			return Vector2(sess.world.map.hqs.rival.x, sess.world.map.hqs.rival.y)
		var c: Array = Economy.centre(MEETS[site].market)
		return Vector2(c[0], c[1])
	var st = sess.stash_net.get_stash(site)
	return Vector2(st.x, st.y)


## Where a lot for `to` is handed over. The Company doesn't keep a shop: its
## plane lands at the strip nearest the goods (not a police strip), as the
## Contra supply flights did - a short drive, not a run through Los Cuervos
## country to the hangar up north. Everyone else: their meet.
func meet_pos(to: String, from: String) -> Vector2:
	if to != "agency":
		return pos(to)
	var p := pos(from)
	var best = null
	var bd := INF
	for af in sess.world.airfields:
		if af.kind == "foreign" or af.police:
			continue
		var d := Vector2(af.x, af.y).distance_to(p)
		if d < bd:
			bd = d
			best = af
	return Vector2(best.x, best.y) if best != null else pos(to)


func name_of(site: String) -> String:
	if site == HQ:
		return str(sess.world.map.hqs.get("org", {}).get("name", "HQ"))
	if MEETS.has(site):
		return MEETS[site].name
	var st = sess.stash_net.get_stash(site)
	return st.name if st != null else site


func market_of(site: String) -> String:
	if MEETS.has(site):
		return MEETS[site].market
	var st = sess.stash_net.get_stash(site)
	return str(st.zone) if st != null else "town"


## The stash whose strip is `code` (or the HQ, at its strip).
func site_at(code: String) -> String:
	for st in sess.stash_net.live():
		if st.strip == code:
			return st.id
	return HQ if code == hq_strip() else ""


# ------------------------------------------------------------------ product
func total(g: String) -> float:
	var n := 0.0
	for s in stock:
		n += stock[s][g]
	return n


## Street money outside the HQ: in the stashes, on the road, in the bags.
func cash_out() -> float:
	var n := float(aboard)
	for s in cash:
		n += cash[s]
	for c in convoys.values():
		n += c.cash
	return n


func sync() -> void:
	for g in Trade.GOODS:
		sess.trade.stock[g] = total(g)


func add(site: String, g: String, lb: float) -> void:
	if not stock.has(site):
		site = nearest_stash(pos(site))
	stock[site][g] += lb
	sync()


## What's in the market's stashes.
func in_market(g: String, m: String) -> float:
	var n := 0.0
	for st in sess.stash_net.live():
		if st.zone == m:
			n += stock[st.id][g]
	return n


## Take up to `lb` from the market's stashes, fullest first. Returns
## [taken, the stash it mostly came from].
func take_market(g: String, m: String, lb: float) -> Array:
	var sites: Array = sess.stash_net.live().filter(func(st): return st.zone == m and stock[st.id][g] > 0.0)
	sites.sort_custom(func(a, b): return stock[a.id][g] > stock[b.id][g])
	var got := 0.0
	var main: String = sites[0].id if not sites.is_empty() else ""
	for st in sites:
		var t := minf(stock[st.id][g], lb - got)
		stock[st.id][g] -= t
		got += t
		if got >= lb - 0.0001:
			break
	sync()
	return [got, main]


func add_cash(site: String, amount: float) -> void:
	if site != HQ and site != "" and cash.get(site, 0.0) < 1.0:
		cash_since[site] = sess.time
	if site == HQ or site == "":
		sess.money += int(amount)
		if amount >= 1.0:
			sess.bus.emit("cash_home", sess.time, "", ["runner"], {"amount": amount})
		return
	cash[site] += amount


# ------------------------------------------------------------------ trucks
## Put product or cash on the road: `what` is a good or "cash". Returns "" or why not.
## A police checkpoint on the road from `a` to `b` (the street war's), or "".
func checkpoint_on(a: Vector2, b: Vector2) -> String:
	if sess.ground == null:
		return ""
	var r: PackedVector2Array = sess.ground.graph.route(a, b)
	for q in sess.ground.of("police"):
		if q.tactic != "checkpoint" or q.state == "gone":
			continue
		var p: Vector2 = q.pos()
		for i in range(1, r.size()):
			if Geometry2D.get_closest_point_to_segment(p, r[i - 1], r[i]).distance_to(p) < CHECKPOINT_M:
				return q.id
	return ""


## `careful` (the AI): don't send into a checkpoint - wait for the road to clear.
## A human gets the warning and the choice.
func send(from: String, to: String, what: String, amount: float, careful := false) -> String:
	if from == to:
		return "It's already there."
	if not stock.has(from) and from != HQ:
		return "No such stash."
	if not (stock.has(to) or to == HQ or MEETS.has(to)):
		return "No such place."
	var st_from = sess.stash_net.get_stash(from)
	if st_from != null and st_from.burned:
		return "%s is burned." % name_of(from)
	var st_to = sess.stash_net.get_stash(to)
	if st_to != null and st_to.burned:
		return "%s is burned." % name_of(to)
	var c := {"kind": "move", "from": from, "to": to, "good": "", "lb": 0.0, "cash": 0.0, "buyer": ""}
	if what == "cash":
		var have: float = float(sess.money) if from == HQ else cash[from]
		amount = minf(amount, have)
		if amount < 1.0:
			return "No cash at %s." % name_of(from)
		if from == HQ:
			sess.money -= int(amount)
		else:
			cash[from] -= amount
		c.cash = amount
	else:
		if from == HQ:
			return "The HQ keeps no product."
		if MEETS.has(to):
			var why: String = sess.trade.available(to)
			if why != "":
				return why
			if not Trade.BUYERS[to].cap.has(what):
				return "%s don't buy %s." % [Trade.BUYERS[to].name, what]
			c.kind = "buy"
			c.buyer = to
		elif to == HQ:
			return "Product goes to a stash, not the club."
		amount = minf(amount, stock[from][what])
		if amount < 0.5:
			return "No %s at %s." % [what, name_of(from)]
		stock[from][what] -= amount
		c.good = what
		c.lb = amount
		sync()
	var dest := meet_pos(to, from)
	if MEETS.has(to):
		c["meet"] = [dest.x, dest.y]
	var cp := checkpoint_on(pos(from), dest)
	if cp != "" and careful:
		_undo(c)
		return "A police checkpoint (%s) is on the road to %s: waiting." % [cp, name_of(to)]
	_dispatch(c, pos(from), dest)
	last = "Truck out: %s from %s to %s." % [_describe(c), name_of(from), name_of(to)]
	if cp != "":
		last += " Careful: a police checkpoint (%s) sits on that road - an escort, or wait." % cp
	sess.say(last)
	return ""


## Put back what a truck that didn't leave was carrying.
func _undo(c: Dictionary) -> void:
	if c.cash > 0.0:
		if c.from == HQ:
			sess.money += int(c.cash)
		else:
			cash[c.from] += c.cash
	if c.lb > 0.0:
		stock[c.from][c.good] += c.lb
		sync()
	if not c.get("weapons", {}).is_empty():
		sess.arsenals["org"].add_all(c.weapons)


func _describe(c: Dictionary) -> String:
	var parts := []
	if c.lb > 0.0:
		parts.append("%d lb of %s" % [int(c.lb), c.good])
	var w: Dictionary = c.get("weapons", {})
	if not w.is_empty():
		parts.append(Arsenal.describe(w))
	if c.cash > 0.0:
		parts.append("$%s cash" % Py.money(int(c.cash)))
	return " + ".join(parts) if not parts.is_empty() else "an empty van"


func _value(c: Dictionary) -> int:
	var v: float = c.cash
	if c.lb > 0.0:
		v += c.lb * sess.trade.street_price(c.good, "town")
	var w: Dictionary = c.get("weapons", {})
	if not w.is_empty():
		v += Arsenal.worth(w, sess.econ.mult("guns", "town"))
	return int(v)


# ------------------------------------------------------------------ guns
## Where the armoury is: a stash (Arsenal.cache), or the club.
func armoury_site() -> String:
	var c: String = sess.arsenals["org"].cache if sess.arsenals.has("org") else ""
	return c if c != "" and stock.has(c) and not sess.stash_net.get_stash(c).burned else HQ


## Guns on the road, from the armoury: `weapons` ({tier: n}) to a buyer's meet,
## or the whole armoury ({} ) to another stash or the club - it moves with them.
func send_guns(to: String, weapons: Dictionary, careful := false) -> String:
	if not Arsenal.REALISM or not sess.arsenals.has("org"):
		return "No armoury in this game."
	if not sess.unlocked("guns"):
		return "No gun dealer will talk to us yet."
	var ars: Arsenal = sess.arsenals["org"]
	var from := armoury_site()
	if from == to:
		return "The armoury is already there."
	var c := {"kind": "move", "from": from, "to": to, "good": "", "lb": 0.0, "cash": 0.0, "buyer": "", "weapons": {}}
	if MEETS.has(to):
		var why: String = sess.trade.available(to)
		if why != "":
			return why
		c.kind = "buy"
		c.buyer = to
		for tier in weapons:
			var n := ars.take(tier, int(weapons[tier]))
			if n > 0:
				c.weapons[tier] = n
		if c.weapons.is_empty():
			return "Nothing like that in the armoury."
	else:
		if not (stock.has(to) or to == HQ):
			return "No such place."
		var st = sess.stash_net.get_stash(to)
		if st != null and st.burned:
			return "%s is burned." % name_of(to)
		for tier in Arsenal.ORDER:
			var n := ars.take(tier, int(ars.stock.get(tier, 0)))
			if n > 0:
				c.weapons[tier] = n
		if c.weapons.is_empty():
			return "The armoury is empty."
	var dest := meet_pos(to, from)
	if MEETS.has(to):
		c["meet"] = [dest.x, dest.y]
	var cp := checkpoint_on(pos(from), dest)
	if cp != "" and careful:
		_undo(c)
		return "A police checkpoint (%s) is on the road to %s: waiting." % [cp, name_of(to)]
	_dispatch(c, pos(from), dest)
	last = "Truck out: %s from %s to %s." % [_describe(c), name_of(from), name_of(to)]
	if cp != "":
		last += " Careful: a police checkpoint (%s) sits on that road - an escort, or wait." % cp
	sess.say(last)
	return ""


func _dispatch(c: Dictionary, a: Vector2, b: Vector2) -> void:
	var sn: StashNet = sess.stash_net
	var t := StashNet.Truck.new()
	t.job_id = Jobs.new_id()
	t.title = "Truck: " + _describe(c)
	# the stash the police would follow it to (heat, tails, raids)
	t.stash = c.to if sn.get_stash(c.to) != null else (c.from if sn.get_stash(c.from) != null else nearest_stash(b))
	t.x0 = a.x
	t.y0 = a.y
	t.x1 = b.x
	t.y1 = b.y
	t.t0 = sess.time
	t.dur = StashNet.TRUCK_LOAD_S + a.distance_to(b) * 1.3 / StashNet.TRUCK_MS
	t.pay = _value(c)
	t.heat = 5.0  # a van between our own places: quieter than a load off an aircraft
	t.no_trail = c.to == HQ  # cash for the club: stop it or let it go, there's nowhere to follow it
	t.items = maxi(1, int(c.lb / 25.0))
	var heat: float = float(sn.get_stash(t.stash).heat)
	var risk := 0.02 + heat / 400.0 + (0.1 if sess.police.case("runner").tipped else 0.0)
	if sess.payroll != null:
		var d: Array = sess.payroll.driver_for(str(t.job_id))
		t.driver = d[0]
		t.waved = d[1]
	if sess.ground != null:
		t.route = sess.ground.graph.route(a, b)
		t.dur = StashNet.TRUCK_LOAD_S + RoadGraph.length(t.route) / StashNet.TRUCK_MS
	elif sn.rng.random() < clampf(risk, 0.0, 0.8) and not t.waved:
		t.stop_at = sn.rng.uniform(0.2, 0.9)
	sn.trucks.append(t)
	convoys[t.job_id] = c


## The drivers watch the road: a checkpoint set up ahead (a few hundred metres
## on) and the truck pulls over until it's gone - or an escort comes. Only the
## surprise of one round the next bend still catches it.
func _pull_over(dt: float) -> void:
	if sess.ground == null:
		return
	# checkpoints and the patrols that stop what they meet (a tail follows, a fight is busy)
	var cps: Array = sess.ground.of("police").filter(func(q): return q.tactic in ["checkpoint", ""] and q.state not in ["gone", "fighting", "routed"])
	if cps.is_empty():
		return
	for t in sess.stash_net.trucks:
		if not convoys.has(t.job_id) or sess.time - t.t0 < StashNet.TRUCK_LOAD_S or t.route.size() < 2:
			continue
		var here := Vector2(t.pos(sess.time)[0], t.pos(sess.time)[1])
		var escorted: bool = sess.ground.squads.any(func(q): return q.faction == "org" and int(q.order.get("job_id", -1)) == t.job_id and q.state != "gone")
		if escorted:
			continue
		var ahead := false
		for q in cps:
			var d: float = q.pos().distance_to(here)
			if d > 350.0 and d < 2500.0 and _near_route(t.route, q.pos()):
				ahead = true
				break
		if ahead:
			t.t0 += dt  # parked in a side street, engine off
			var c: Dictionary = convoys[t.job_id]
			if not c.get("waiting", false):
				c["waiting"] = true
				sess.say("The driver to %s spotted police on the road ahead and pulled over." % name_of(c.to))
		else:
			convoys[t.job_id]["waiting"] = false


func _near_route(r: PackedVector2Array, p: Vector2) -> bool:
	for i in range(1, r.size()):
		if Geometry2D.get_closest_point_to_segment(p, r[i - 1], r[i]).distance_to(p) < CHECKPOINT_M:
			return true
	return false


## What a truck of ours carries, for the maps: cash, product, guns, a lot for a
## buyer, or a load off an aircraft (a stash job's truck) - and where it's going.
func truck_info(t) -> Dictionary:
	if not convoys.has(t.job_id):
		return {"kind": "load", "to": t.stash, "tx": t.x1, "ty": t.y1}
	var c: Dictionary = convoys[t.job_id]
	var kind := "product"
	if c.kind == "buy":
		kind = "buyer"
	elif not c.get("weapons", {}).is_empty():
		kind = "guns"
	elif c.lb <= 0.0 and c.cash > 0.0:
		kind = "cash"
	return {"kind": kind, "to": name_of(c.to), "tx": t.x1, "ty": t.y1, "waiting": c.get("waiting", false)}


func owns(t) -> bool:
	return convoys.has(t.job_id)


## A truck of ours reached the end of the road, one way or another.
func arrived(t, outcome: String, why: String) -> void:
	var c: Dictionary = convoys[t.job_id]
	convoys.erase(t.job_id)
	if sess.payroll != null and t.driver != "":
		if outcome == "delivered":
			sess.payroll.release([t.driver])
		else:
			sess.payroll.lose(t.driver, "arrested")
	if outcome == "delivered":
		match c.kind:
			"move":
				if c.lb > 0.0:
					add(c.to, c.good, c.lb)
				add_cash(c.to, c.cash)
				if not c.get("weapons", {}).is_empty():
					sess.arsenals["org"].add_all(c.weapons)
					sess.arsenals["org"].cache = "" if c.to == HQ else c.to  # the armoury is here now
				last = "Truck in at %s: %s." % [name_of(c.to), _describe(c)]
			"buy":
				_settle(c)
			"cash_back":
				if c.lb > 0.0:
					add(c.to, c.good, c.lb)
				add_cash(c.to, c.cash)
				if not c.get("weapons", {}).is_empty():
					sess.arsenals["org"].add_all(c.weapons)  # what the buyer didn't want: back in the rack
				last = "The money's home at %s: %s." % [name_of(c.to), _describe(c)]
		sess.say(last)
		return
	var what := _describe(c)
	lost.product += c.lb
	lost.cash += int(c.cash)
	lost_by[outcome if outcome == "hijacked" else "seized"] += _value(c)
	var guns: Dictionary = c.get("weapons", {})
	if not guns.is_empty():
		if outcome == "hijacked":
			if sess.arsenals.has("rival"):
				sess.arsenals["rival"].add_all(guns)  # Los Cuervos are better armed tonight
		else:
			sess._seize_weapons(guns, "a truck")
	if outcome == "hijacked":
		last = "Los Cuervos took the truck (%s) near %s." % [what, name_of(c.to)]
		if sess.ground != null:
			sess.ground.commanders.rival.cash += c.cash
		sess.bus.emit("truck_hijacked", sess.time, "", ["runner"], {"stash": t.stash})
	else:
		last = "The truck (%s) was stopped: %s. All of it forfeited." % [what, why]
		sess.law_funds += c.cash * 0.5 + 300.0 * t.items
		if c.lb > 0.0:
			sess.econ.record_seizure(c.good, market_of(c.to))
		var case_ = sess.police.case("runner")
		# cash is a money-laundering lead; product is a drug case
		case_.suspicion = minf(100.0, case_.suspicion + (4.0 if c.lb <= 0.0 else (10.0 if c.lb >= 100.0 else 6.0)))
		sess.law_say("Truck stopped: %s seized." % what)
		sess.bus.emit("truck_seized", sess.time, "", ["runner", "law"], {"stash": t.stash})
	sess.say(last)


## The lot reaches the buyer: it pays for what it takes, and the money (and
## anything it didn't want) rides back to the stash it came from.
func _settle(c: Dictionary) -> void:
	var tr: Trade = sess.trade
	var name: String = Trade.BUYERS[c.buyer].name
	var back := {"kind": "cash_back", "from": c.buyer, "to": c.from, "good": c.good, "lb": 0.0, "cash": 0.0, "buyer": c.buyer, "weapons": {}}
	var took := []
	if c.lb > 0.0:
		var q: Dictionary = tr.quote(c.buyer, c.good)
		var take := minf(c.lb, float(q.room)) if q.why == "" else 0.0
		back.lb = c.lb - take
		if take > 0.0:
			back.cash += tr.settle(c.buyer, c.good, take)
			took.append("%d lb of %s" % [int(take), c.good])
	for tier in c.get("weapons", {}):
		var n: int = c.weapons[tier]
		var q: Dictionary = tr.quote(c.buyer, "guns", tier)
		var take := mini(n, int(q.room)) if q.why == "" else 0
		if take > 0:
			back.cash += tr.settle(c.buyer, "guns", float(take), tier)
			took.append("%d %s" % [take, Arsenal.TIERS[tier].name.to_lower()])
		if n - take > 0:
			back.weapons[tier] = n - take
	if took.is_empty():
		last = "%s wouldn't take it. It's coming back." % name
	else:
		last = "%s took %s: $%s coming back to %s." % [name, ", ".join(took), Py.money(int(back.cash)), name_of(c.from)]
	var st = sess.stash_net.get_stash(c.from)
	if st != null and st.burned:
		back.to = nearest_stash(pos(c.buyer))
	var at: Vector2 = Vector2(c.meet[0], c.meet[1]) if c.has("meet") else pos(c.buyer)
	_dispatch(back, at, pos(back.to))


func _raided(site: String) -> void:
	if not stock.has(site):
		return
	var took := []
	for g in Trade.GOODS:
		if stock[site][g] >= 1.0:
			took.append("%d lb of %s" % [int(stock[site][g]), g])
			lost.product += stock[site][g]
			stock[site][g] = 0.0
	lost_by.raided += int(cash[site])
	for g in Trade.GOODS:
		lost_by.raided += int(stock[site][g] * sess.trade.street_price(g, "town"))
	if cash[site] >= 1.0:
		took.append("$%s in cash" % Py.money(int(cash[site])))
		sess.law_funds += cash[site] * 0.5
		lost.cash += int(cash[site])
		cash[site] = 0.0
	# trucks the raid took at the door
	for id in convoys.keys():
		if not Py.any(sess.stash_net.trucks, func(t): return t.job_id == id):
			var c: Dictionary = convoys[id]
			lost.product += c.lb
			lost.cash += int(c.cash)
			convoys.erase(id)
	sync()
	if not took.is_empty():
		sess.say("The raid took %s." % ", ".join(took))


# ------------------------------------------------------------------ the aircraft
## Load cash bags where we're parked: from the stash here, or the HQ's safe.
func load_cash(amount: float) -> String:
	if not sess.parked:
		return "Land first."
	var site := site_at(sess.location)
	if site == "":
		return "No cash of ours at %s." % sess.location
	if site != HQ and cash[site] < 1.0 and sess.location == hq_strip():
		site = HQ  # the stash here is dry: the club's safe is next door
	var have: float = float(sess.money) if site == HQ else cash[site]
	amount = minf(amount, have)
	if amount < 1.0:
		return "No cash at %s." % name_of(site)
	if site == HQ:
		sess.money -= int(amount)
	else:
		cash[site] -= amount
	aboard += int(amount)
	_bags()
	sess.say("Loaded $%s in cash bags (%d lb): $%s aboard." % [Py.money(int(amount)), int(amount / CASH_PER_LB), Py.money(aboard)])
	return ""


## Unload the bags: into the stash here, or the HQ's safe.
func unload_cash() -> String:
	if not sess.parked:
		return "Land first."
	if aboard <= 0:
		return "No cash aboard."
	var site := HQ if sess.location == hq_strip() else site_at(sess.location)  # the club's safe first
	if site == "":
		return "Nowhere safe to leave it at %s." % sess.location
	add_cash(site, aboard)
	sess.say("$%s into %s." % [Py.money(aboard), name_of(site)])
	aboard = 0
	_bags()
	return ""


## The growers and the connection: cash on the strip.
func pay_seller(cost: int) -> String:
	if aboard < cost:
		return "They want $%s in cash on the strip - you have $%s aboard. Fly the money out first [SHIFT+C loads it at a stash or the club's strip]." % [
			Py.money(cost), Py.money(aboard)]
	aboard -= cost
	_bags()
	return ""


## A bust: the bags are evidence.
func seize_aboard() -> void:
	if aboard <= 0:
		return
	lost.cash += aboard
	lost_by.bust += aboard
	sess.law_funds += aboard * 0.5
	sess.say("And the $%s in cash bags." % Py.money(aboard))
	aboard = 0
	_bags()


func _bags() -> void:
	var lo: Loadout = sess.loadout
	for it in lo.items.values().filter(func(i): return i.label == "Cash bags"):
		lo.remove_item(it.id)
	if aboard > 0:
		_item_id -= 1
		lo.add(Loadout.Item.new(-100000 + _item_id, "Cash bags", "cargo", maxf(1.0, aboard / CASH_PER_LB), 0, {"hot": true}))
		lo.auto_balance()
		lo.pending.clear()
	if sess.fm != null:
		sess.fm.apply_loadout(lo)


# ------------------------------------------------------------------ the AI
## The organisation's AI (no boss in the chair): cash home, product to where
## the dealers are, the surplus to the best buyer.
func update(dt: float) -> void:
	_watch_t += dt
	if _watch_t >= 5.0:
		_pull_over(_watch_t)
		_watch_t = 0.0
	_t += dt
	if _t < 60.0:
		return
	_t = 0.0
	if sess.payroll == null or not sess.payroll.ai.get("org", false):
		return
	var busy := {}
	var cash_moving := false
	for c in convoys.values():
		busy[c.from] = true
		cash_moving = cash_moving or c.cash > 0.0
	# one cash truck at a time, the fattest stash first; sooner if the payroll is short
	var short: bool = sess.money < sess.payroll.wage_bill("org") * 2.0
	var fattest = null
	for s in cash:
		var due: bool = cash[s] >= 1000.0 and sess.time - float(cash_since.get(s, sess.time)) >= AI_PICKUP_S
		if not busy.has(s) and not sess.stash_net.get_stash(s).burned and (due or cash[s] >= (AI_CASH_SHORT if short else AI_CASH_HOME)):
			if fattest == null or cash[s] > cash[fattest]:
				fattest = s
	if fattest != null and not cash_moving:
		send(fattest, HQ, "cash", cash[fattest], true)
		busy[fattest] = true
	if sess.time - _move_t < AI_MOVE_EVERY_S:
		return
	# product where the dealers work
	var tr: Trade = sess.trade
	for m in Economy.MARKETS:
		var n: int = tr.dealers("org", m).size()
		if n == 0:
			continue
		for g in Trade.GOODS:
			var want: float = Trade.DEALER_LB_MIN[g] * 90.0 * n  # an hour and a half of work
			if in_market(g, m) >= want * 0.25:
				continue
			var from = null
			var most := want * 0.5
			for st in sess.stash_net.live():
				if st.zone != m and stock[st.id][g] > most and not busy.has(st.id):
					from = st.id
					most = stock[st.id][g]
			var to = Py.first(sess.stash_net.live(), func(st): return st.zone == m)
			if from != null and to != null:
				send(from, to.id, g, minf(most, want), true)
				_move_t = sess.time
				return


# ------------------------------------------------------------------ views
func view() -> Dictionary:
	var sites := []
	for st in sess.stash_net.stashes:
		sites.append({"id": st.id, "name": st.name, "market": st.zone, "burned": st.burned, "strip": st.strip,
			"cocaine": snappedf(stock[st.id].cocaine, 0.1), "marijuana": snappedf(stock[st.id].marijuana, 0.1), "cash": int(cash[st.id])})
	var trucks := []
	for t in sess.stash_net.trucks:
		if convoys.has(t.job_id):
			var c: Dictionary = convoys[t.job_id]
			var p: Array = t.pos(sess.time)
			trucks.append({"id": t.job_id, "what": _describe(c), "from": name_of(c.from), "to": name_of(c.to), "x": p[0], "y": p[1],
				"eta": int(maxf(0.0, t.t0 + t.dur - sess.time)), "waiting": c.get("waiting", false),
				"escort": sess.ground != null and sess.ground.squads.any(func(q): return q.faction == "org" and int(q.order.get("job_id", -1)) == t.job_id and q.state != "gone")})
	var arm := {}
	if sess.arsenals.has("org"):
		arm = {"site": armoury_site(), "at": name_of(armoury_site()), "weapons": sess.arsenals["org"].stock.duplicate(),
			"count": sess.arsenals["org"].count()}
	return {"sites": sites, "trucks": trucks, "aboard": aboard, "armoury": arm, "war": sess.ground != null, "hq": name_of(HQ), "hq_strip": hq_strip(),
		"lost": lost.duplicate(), "last": last}
