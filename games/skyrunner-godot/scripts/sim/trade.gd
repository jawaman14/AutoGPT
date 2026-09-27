class_name Trade
extends RefCounted
## The product business: what the organisation holds, who sells it on the
## street, who buys it in bulk, and where the guns go.
##
##   stock          pounds of cocaine and marijuana in the organisation's stash
##                  houses. Filled by our own loads (bought at the farm strips -
##                  grass - or from the Colombian connection - cocaine - and
##                  flown to a stash strip); a raid takes part of it
##   street sellers dealers (a payroll role, both outfits) sell it corner by corner
##                  at the street price. Their sales put product on the street
##                  (the price softens); Los Cuervos' dealers compete for the
##                  same buyers; the police pick dealers up (likelier where they're
##                  thick, and for cocaine); a gunfight in their market can take
##                  them; Los Cuervos hit the corners where ours sell
##   bulk buyers    the Moretti family (both drugs at a bulk discount - it sells
##                  them on in town, flooding it - and guns, to arm its crews
##                  against Los Cuervos), the Company (cocaine for its pipeline,
##                  guns at a premium for the war down south - scarcer here), and
##                  Los Cuervos (guns: they fight better, us included). Every buyer
##                  quotes off the market and has only so much appetite at a time
##   the career     (career: true, live play) it starts with grass, the way the
##                  1970s smugglers did: cheap, bulky, less heat. The Colombians
##                  only call once we've proven ourselves (CONNECT_LB of grass
##                  sold, or CONNECT_EARNED made in the trade); until then no
##                  cocaine work, no island, no return legs
##   the law        a street sweep picks dealers up in a market; following the
##                  money traces the Company's pipeline - and our bulk sales
##
## Off for the Python replays (Trade.ENABLED = false; sessions ask: trade: true).
## Own stream (seed + 131).

static var ENABLED := true

const GOODS := ["cocaine", "marijuana"]
const PER_LB := {"cocaine": 55.0, "marijuana": 6.0}  ## street value a pound, before the market
const OWN := {
	"marijuana": {"per_lb": 2.0, "label": "Bale", "lb": [22.0, 32.0], "n": [8, 16], "at": ["bush"], "title": "Our own grass"},
	"cocaine": {"per_lb": 22.0, "label": "Kilo brick crate", "lb": [18.0, 35.0], "n": [2, 5], "at": ["shady"], "title": "The connection"},
}
const DEALER_LB_MIN := {"cocaine": 0.6, "marijuana": 5.0}  ## what one dealer moves a minute
const FLOOD_PER_LB := {"cocaine": 0.0015, "marijuana": 0.0002}  ## street supply a pound adds
const ARREST_MIN := 0.005  ## a dealer's chance of a pinch a minute (x police, x the drug)
const CONNECT_LB := 1200.0
const CONNECT_EARNED := 25000
const SWEEP_COST := 2500
const TRACE_COST := 4000
## buyer -> what it takes and at what share of the street (guns: of the fence's street price)
const BUYERS := {
	"family": {"name": "The Moretti family", "market": "town", "drugs": {"cocaine": 0.72, "marijuana": 0.8}, "guns": 1.0,
		"cap": {"cocaine": 40.0, "marijuana": 600.0, "guns": 12.0}},
	"agency": {"name": "The Company", "market": "north", "drugs": {"cocaine": 0.85}, "guns": 1.3,
		"cap": {"cocaine": 60.0, "guns": 20.0}},
	"rival": {"name": "Los Cuervos", "market": "west", "drugs": {}, "guns": 1.2, "cap": {"guns": 15.0}},
}
const REFILL_S := 1800.0  ## a buyer's appetite comes back over this long

var sess
var rng: PyRandom
var stock := {"cocaine": 0.0, "marijuana": 0.0}
var career := false
var connected := true
var appetite := {}  ## buyer -> good -> room left
var sold := {"cocaine": 0.0, "marijuana": 0.0}  ## lb sold (street + bulk)
var earned := 0  ## money the trade made
var street_sales := {}  ## market -> $ a minute (the last minute, ours)
var last := ""
var bulk_log: Array = []  ## [time, buyer, good, qty] - what following the money finds
var _t := 0.0
var _war_t := 0.0
var _sales_acc := {}


func _init(sess_, rng_: PyRandom, career_ := false) -> void:
	sess = sess_
	rng = rng_
	career = career_
	connected = not career
	for b in BUYERS:
		appetite[b] = {}
		for g in BUYERS[b].cap:
			appetite[b][g] = float(BUYERS[b].cap[g])
	for m in Economy.MARKETS:
		street_sales[m] = 0.0
	# a raid finds product in the house: a share of the stash goes to evidence
	sess.bus.subscribe("stash_raided", func(_e):
		var lost := []
		for g in GOODS:
			if stock[g] >= 1.0:
				lost.append("%d lb of %s" % [int(stock[g] * 0.3), g])
				stock[g] *= 0.7
		if not lost.is_empty():
			sess.say("The raid took %s from the stash." % ", ".join(lost)))


# ------------------------------------------------------------------ prices
func street_price(g: String, m: String) -> float:
	return PER_LB[g] * sess.econ.mult(g, m)


func available(buyer: String) -> String:
	match buyer:
		"family":
			if sess.family == null or not sess.family.active():
				return "There's no Family to sell to."
			if sess.family.respect < 25.0:
				return "The Morettis won't deal with us - not with respect this low."
		"agency":
			if sess.agency == null or not sess.agency.active():
				return "The Company isn't buying."
			if sess.agency.hung_out:
				return "The Company doesn't return our calls."
		"rival":
			if sess.ground == null:
				return "Los Cuervos aren't in this game."
		_:
			return "No such buyer."
	return ""


## A buyer's quote: {price (a pound, or a weapon of `tier`), room, why ("" = open)}.
func quote(buyer: String, good: String, tier := "rifle") -> Dictionary:
	var why := available(buyer)
	var b: Dictionary = BUYERS.get(buyer, {})
	if why == "" and not b.cap.has(good):
		why = "%s don't buy %s." % [b.name, good]
	if why == "" and good == "cocaine" and not connected:
		why = "Nobody deals cocaine with us yet."
	var m: String = b.get("market", "town")
	var price := 0.0
	if good == "guns":
		price = Arsenal.TIERS[tier].price * sess.econ.mult("guns", m) * float(b.get("guns", 1.0))
	elif why == "" or b.get("drugs", {}).has(good):
		price = street_price(good, m) * float(b.get("drugs", {}).get(good, 0.0))
	return {"price": price, "room": float(appetite.get(buyer, {}).get(good, 0.0)), "why": why}


# ------------------------------------------------------------------ selling in bulk
## Sell `qty` (pounds; guns: weapons of `tier`) to `buyer`. Returns "" or why not.
func sell(buyer: String, good: String, qty: float, tier := "rifle") -> String:
	var q := quote(buyer, good, tier)
	if q.why != "":
		return q.why
	qty = minf(qty, q.room)
	if good == "guns":
		qty = floorf(qty)
	if qty <= 0.0:
		return "%s have had enough for now." % BUYERS[buyer].name
	var have: float = float(sess.arsenals["org"].stock.get(tier, 0)) if good == "guns" else stock[good]
	qty = minf(qty, have)
	if qty <= 0.0:
		return "We have no %s to sell." % (Arsenal.TIERS[tier].name.to_lower() if good == "guns" else good)
	var pay := int(q.price * qty)
	if good == "guns":
		sess.arsenals["org"].take(tier, int(qty))
	else:
		stock[good] -= qty
		sold[good] += qty
	appetite[buyer][good] -= qty
	sess.money += pay
	earned += pay
	bulk_log.append([sess.time, buyer, good, qty])
	Py.keep_last(bulk_log, 30)
	_effects(buyer, good, qty, pay)
	last = "Sold %s %s to %s: +$%s" % [("%d" % int(qty)) if good == "guns" else ("%d lb of" % int(qty)),
		Arsenal.TIERS[tier].name.to_lower() if good == "guns" else good, BUYERS[buyer].name, Py.money(pay)]
	sess.say(last)
	sess.bus.emit("bulk_sale", sess.time, last, ["runner"], {"buyer": buyer, "good": good, "qty": qty})
	_check_connection()
	return ""


## What each sale does to the markets and the wars.
func _effects(buyer: String, good: String, qty: float, pay: int) -> void:
	var mk: Market = sess.econ.market
	match buyer:
		"family":
			sess.family.respect = minf(100.0, sess.family.respect + 2.0)
			if good == "guns":
				# the Family arms its crews and goes after Los Cuervos
				if sess.ground != null:
					sess.ground.commanders.rival.cash = maxf(0.0, sess.ground.commanders.rival.cash - 500.0 * qty)
				if mk != null:
					mk.flow("guns", "town", 0.01 * qty, "the Family's crews are armed")
				sess.law_say("The Moretti crews are carrying new rifles; Los Cuervos lose a corner downtown")
			elif mk != null:
				mk.flow(good, "town", FLOOD_PER_LB[good] * qty * 1.5, "the Family is moving our product")
		"agency":
			var a = sess.agency
			a.trust = minf(100.0, a.trust + 3.0)
			a.exposure = minf(100.0, a.exposure + 0.5)
			if good == "guns":
				a.war_chest = maxf(0.0, a.war_chest - pay * 0.2)
				if mk != null:
					mk.source_shock("guns", -0.01 * qty)  # south, out of circulation: scarcer here
			else:
				a.war_chest += pay * 1.2
				a.extra_lots += int(qty / 30.0)
		"rival":
			if sess.arsenals.has("rival"):
				sess.arsenals["rival"].add("rifle", int(qty))
			sess.ground.commanders.rival.cash = maxf(0.0, sess.ground.commanders.rival.cash - pay)
			if mk != null:
				mk.flow("guns", "west", 0.01 * qty)
				mk.demand_shock("guns", "west", 0.9, 30)
			var c = sess.police.case("runner")
			c.suspicion = minf(100.0, c.suspicion + 0.3 * qty)  # guns to a gang get noticed


# ------------------------------------------------------------------ own loads
## Our own load on a strip's board: grass at the bush strips, the connection's
## cocaine at the shady ones (once connected). Flown to a stash strip.
func board_offer(origin: Airfield, jobs_rng: PyRandom):
	if sess.stash_net == null:
		return null
	var good := ""
	for g in ["marijuana", "cocaine"]:
		if origin.kind in OWN[g].at and (g != "cocaine" or connected):
			good = g
	if good == "":
		return null
	var dests: Array = sess.stash_net.live().filter(func(s): return s.strip != origin.code)
	if dests.is_empty():
		return null
	var st: Dictionary = dests[jobs_rng.randint(0, dests.size() - 1)]
	var o: Dictionary = OWN[good]
	var jid := Jobs.new_id()
	var n := jobs_rng.randint(o.n[0], o.n[1])
	var items := []
	for k in n:
		items.append(Jobs.item(o.label, "cargo", jobs_rng.uniform(o.lb[0], o.lb[1]), jid, {"hot": true}))
	var lb := Py.sum_by(items, func(i): return i.weight_lb)
	var cost := int(lb * float(o.per_lb) * sess.econ.wholesale(good))
	var job := Jobs.Job.new(jid, "%s: %d lb -> %s" % [o.title, int(lb), World.airfield(st.strip).name], "contraband", origin.code, st.strip,
		items, 0, {"cost": cost, "notes": "Ours: $%s up front, worth about $%s on the street. Into the stash at %s for the dealers - or a buyer." % [
			Py.money(cost), Py.money(int(lb * street_price(good, st.zone))), st.name]})
	job.own_good = good
	return job


## Our own load landed at a stash strip: into the stash.
func delivered(job) -> void:
	var lb := Py.sum_by(job.items, func(i): return i.weight_lb)
	stock[job.own_good] += lb
	sess.say("Delivered '%s': %d lb of %s into the stash (%d lb held)" % [job.title, int(lb), job.own_good, int(stock[job.own_good])])


# ------------------------------------------------------------------ the street
func dealers(o: String, m := "") -> Array:
	if sess.payroll == null:
		return []
	return sess.payroll.of(o, "dealer", "assigned").filter(func(w): return m == "" or w.assigned == "corner-" + m)


## Where the outfit sells: ours where our stash houses are; Los Cuervos where they hold turf.
func _corners(o: String) -> Array:
	if o == "org":
		var ms := {}
		if sess.stash_net != null:
			for st in sess.stash_net.live():
				ms[st.zone] = true
		return ms.keys() if not ms.is_empty() else ["town"]
	var turf: Dictionary = sess.ground.turf({}) if sess.ground != null else {}
	var best := ["west"]
	for m in turf:
		if float(turf[m]) >= 0.35 and m != "west":
			best.append(m)
	return best


## How many dealers the outfit's AI wants.
func dealers_wanted(o: String) -> int:
	if o == "org":
		var lb_min := 0.0
		for g in GOODS:
			lb_min += stock[g] / DEALER_LB_MIN[g] / 60.0  # hours of work for one dealer
		return clampi(int(ceil(lb_min)), 0, 6)
	return 4 if sess.ground != null else 0


func update(dt: float) -> void:
	_t += dt
	if _t < 60.0:
		return
	var step := _t
	_t = 0.0
	for b in appetite:
		for g in appetite[b]:
			appetite[b][g] = minf(float(BUYERS[b].cap[g]), appetite[b][g] + float(BUYERS[b].cap[g]) * step / REFILL_S)
	if sess.payroll == null:
		return
	_post_dealers()
	for m in Economy.MARKETS:
		street_sales[m] = 0.0
	_sell_street("org", step)
	if sess.ground != null:
		_sell_street("rival", step)
		_street_war(step)
	if sess.payroll.ai.get("org", false):
		_ai_bulk()
	_check_connection()


## The organisation's AI (no boss in the chair): what the dealers can't move in
## about two hours goes to the best buyer, a lot at a time.
func _ai_bulk() -> void:
	for g in GOODS:
		var street_rate: float = DEALER_LB_MIN[g] * 120.0 * maxf(1.0, float(dealers("org").size()))
		if stock[g] <= street_rate:
			continue
		var best := ""
		var bp := 0.0
		for b in BUYERS:
			var q := quote(b, g)
			if q.why == "" and q.room >= 1.0 and q.price > bp:
				best = b
				bp = q.price
		if best != "":
			sell(best, g, stock[g] - street_rate)


## Free dealers go to the outfit's corners, spread evenly.
func _post_dealers() -> void:
	for o in ["org", "rival"]:
		if not sess.payroll.has_outfit(o):
			continue
		var corners := _corners(o)
		for w in sess.payroll.of(o, "dealer", "free"):
			var m: String = Py.min_by(corners, func(c): return dealers(o, c).size())
			w.status = "assigned"
			w.assigned = "corner-" + m


func _sell_street(o: String, step: float) -> void:
	var mins := step / 60.0
	for w in dealers(o):
		var m: String = str(w.assigned).trim_prefix("corner-")
		# competition: the other outfit's dealers and its hold on the market
		var other := "rival" if o == "org" else "org"
		var share := clampf(1.0 - 0.12 * dealers(other, m).size() - 0.4 * (sess.econ.rival[m] if o == "org" else 0.0), 0.3, 1.0)
		var g := ""
		if o == "org":
			g = "cocaine" if stock.cocaine >= DEALER_LB_MIN.cocaine * mins else ("marijuana" if stock.marijuana > 0.0 else "")
			if g == "":
				continue
		else:
			g = "cocaine"
		var lb: float = DEALER_LB_MIN[g] * mins * share * (0.6 + 0.8 * float(w.skill))
		if o == "org":
			lb = minf(lb, stock[g])
			stock[g] -= lb
			sold[g] += lb
		var pay := lb * street_price(g, m)
		sess.payroll.earn(o, pay)
		if o == "org":
			earned += int(pay)
			street_sales[m] += pay / mins
		if sess.econ.market != null:
			sess.econ.market.flow(g, m, FLOOD_PER_LB[g] * lb)
		# the police pick dealers up: likelier where they're thick, and for cocaine
		var p: float = ARREST_MIN * mins * (1.0 + 1.5 * sess.econ.heat[m]) * (1.0 if g == "cocaine" else 0.5)
		if rng.random() < p:
			sess.payroll.lose(w.id, "arrested")


## The street wars: a fight in a market is a fight on its corners; and Los
## Cuervos go after the corners where ours sell.
func _street_war(step: float) -> void:
	var mins := step / 60.0
	for f in sess.ground.fights:
		if f.over:
			continue
		var m: String = GroundWar.market_at(f.x, f.y)
		for o in ["org", "rival"]:
			for w in dealers(o, m):
				if rng.random() < 0.05 * mins:
					sess.payroll.lose(w.id, "arrested" if rng.random() < 0.6 else "killed")
	_war_t += step
	if _war_t < 600.0:
		return
	_war_t = 0.0
	var ours := {}
	for w in dealers("org"):
		var m := str(w.assigned).trim_prefix("corner-")
		ours[m] = ours.get(m, 0) + 1
	for m in ours:
		if ours[m] >= 2 and sess.ground.rival_share(m) >= 0.25 and sess.ground.commanders.rival.ai:
			var free: Array = sess.ground._free("rival")
			if free.is_empty():
				break
			var c: Array = Economy.centre(m)
			sess.ground.order(free[0], {"type": "attack", "x": c[0], "y": c[1], "market": m})
			sess.say("Los Cuervos are coming for our corners in the %s." % Market._name(m))
			break


# ------------------------------------------------------------------ the career
func _check_connection() -> void:
	if connected or not career:
		return
	if sold.marijuana >= CONNECT_LB or earned >= CONNECT_EARNED:
		connected = true
		last = "The Colombians came calling: a man from Medellin wants a pilot who delivers. Cocaine work is open."
		sess.say("NEWS - " + last)
		sess.bus.emit("connection", sess.time, last, ["runner"], {})


# ------------------------------------------------------------------ the law
## A sweep through a market's corners: dealers picked up, ours and theirs.
func sweep(m: String) -> String:
	if not Economy.MARKETS.has(m):
		return "Which market?"
	if sess.law_funds < SWEEP_COST:
		return "Need $%d in funds." % SWEEP_COST
	sess.law_funds -= SWEEP_COST
	var n := 0
	if sess.payroll != null:
		for o in ["org", "rival"]:
			for w in dealers(o, m):
				if rng.random() < 0.45:
					sess.payroll.lose(w.id, "arrested")
					n += 1
	if sess.econ.market != null:
		sess.econ.market.disrupt(m, 0.15 + 0.05 * n, "a police sweep", "A police sweep through the %s: %d dealers in cuffs" % [Market._name(m), n])
	sess.law_say("Street sweep in the %s: %d dealers arrested" % [Market._name(m), n])
	return ""


## Follow the money: the Company's pipeline, and our bulk sales in its trail.
func trace() -> String:
	if sess.law_funds < TRACE_COST:
		return "Need $%d in funds." % TRACE_COST
	sess.law_funds -= TRACE_COST
	var found := []
	var a = sess.agency
	if a != null and a.active() and a.coke_lots > 0:
		var gain: float = 5.0 + 2.0 * mini(a.coke_lots, 6)
		a.exposure = minf(100.0, a.exposure + gain)
		var seized: float = a.war_chest * 0.25
		a.war_chest -= seized
		sess.law_funds += seized
		found.append("the Company's pipeline: exposure +%d, $%s forfeited; the next load lands in the %s" % [int(gain), Py.money(int(seized)),
			Market._name(a.next_market)])
		a._check_exposed()
	var recent := bulk_log.filter(func(x): return sess.time - x[0] < 3600.0)
	if not recent.is_empty():
		var c = sess.police.case("runner")
		c.suspicion = minf(100.0, c.suspicion + 4.0 * recent.size())
		found.append("%d bulk sales by the smuggling organisation (suspicion +%d)" % [recent.size(), 4 * recent.size()])
	sess.law_say("Following the money: " + ("; ".join(found) if not found.is_empty() else "the trail's cold"))
	return ""


# ------------------------------------------------------------------ views
func view(side: String) -> Dictionary:
	var corners := {}
	for m in Economy.MARKETS:
		corners[m] = {"ours": dealers("org", m).size(), "theirs": dealers("rival", m).size()}
	if side == "law":
		return {"corners": corners}
	var quotes := {}
	for b in BUYERS:
		quotes[b] = {}
		for g in BUYERS[b].cap:
			var q := quote(b, g)
			quotes[b][g] = {"price": snappedf(q.price, 0.1), "room": int(q.room), "why": q.why}
	var st := {}
	for g in GOODS:
		st[g] = int(stock[g])
	var sales := {}
	for m in street_sales:
		sales[m] = int(street_sales[m])
	return {"stock": st, "corners": corners, "quotes": quotes, "connected": connected, "career": career, "last": last,
		"sales": sales, "sold": {"cocaine": int(sold.cocaine), "marijuana": int(sold.marijuana)}, "earned": earned,
		"street": {"cocaine": snappedf(street_price("cocaine", "town"), 0.1), "marijuana": snappedf(street_price("marijuana", "town"), 0.1)}}
