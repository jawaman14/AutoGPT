class_name Market
extends RefCounted
## Supply and demand on the street, under Economy's price walk.
##
## Economy prices each good in each market as a random walk with premiums
## (rivals, police, scarcity, glut, news). This is what's actually on the
## street, for the hot goods (cocaine, marijuana, guns):
##
##   supply[g][m]   how much is reaching buyers in market m (1 = normal)
##   demand[g][m]   how much they want (1 = normal)
##   disruption[m]  damage to the distribution network - dealers arrested,
##                  stash houses raided, corners shot up (0..1): supply can't
##                  get through, so it falls toward source x (1 - 0.6 x disruption)
##   source[g]      upstream: what the island, the farms and the fences can
##                  sell (1 = normal) - hurricanes, purges, crackdowns and
##                  gluts move it; the island's wholesale price follows it
##
## The street price moves with (demand / supply) ^ ELASTICITY. Everything
## relaxes back toward normal: supply to its target in ~15 min, demand in
## ~40, disruption heals in ~25, the source recovers in ~60.
##
## What moves it (Session wires the event bus in; see hook()):
##   arrests and busts - yours, your workers', Los Cuervos' men, the fights'
##       prisoners: the network that sold is gone for a while - disruption
##   raids and seizures - the stash house, the truck, the boat: supply falls
##   informants and sentences - a flipped worker or a cooperation deal rolls up
##       corners; a long sentence scares the street (demand dips)
##   competing factions - Los Cuervos' containers from the island flood their
##       markets; their losses in the fights dry them up; the Family's fall
##       takes the town's fence and wholesale with it
##   the island and the Agency - a purge or a hurricane chokes the source, a
##       glut floods it; the Company's pipeline shuts while it covers itself
##   the street's own news - spring break, a bad batch, a crusade (own table)
##
## Own RNG stream (seed + 113); off with Economy.REALISM (the Python replays).

const HOT := ["cocaine", "marijuana", "guns"]
const ELASTICITY := 0.55
const SUPPLY_TAU := 900.0
const DEMAND_TAU := 2400.0
const HEAL_TAU := 1500.0
const SOURCE_TAU := 3600.0
const NEWS_GAP_S := 240.0  ## one market headline per this, at most, per kind
## [good ("*" = all hot), market ("*" = all), demand multiplier, minutes, headline]
const STREET_NEWS := [
	["*", "town", 1.3, 60, "Spring break: the town is full and it wants everything"],
	["cocaine", "*", 0.7, 50, "A bad batch on the street - three dead in a week. Buyers are scared off"],
	["*", "town", 0.8, 60, "A church crusade marches on the waterfront; the corners go quiet"],
	["cocaine", "north", 1.35, 60, "A new disco opens up north: the money's in the VIP room"],
	["marijuana", "*", 1.25, 70, "Mainland paraquat scare: island grass in demand"],
	["guns", "west", 1.4, 50, "Los Cuervos are arming for a war: guns wanted in the west"],
	["*", "sea", 1.2, 60, "The fishing fleet's paid out: money on the docks"],
]

var rng: PyRandom
var supply := {}
var demand := {}
var disruption := {}
var source := {}
var news: Array = []  ## [time, text] - Economy folds these into its own news
var why := {}  ## market -> the last thing that moved it (for the desk)
var _last_news := {}
var _fights := {}  ## fight id -> [arrests, casualties] seen
var _demand_events: Array = []  ## {good, market, mult, until}
var _t := 0.0
var _now := 0.0


func _init(rng_: PyRandom) -> void:
	rng = rng_
	for g in HOT:
		supply[g] = {}
		demand[g] = {}
		source[g] = 1.0
		for m in Economy.MARKETS:
			supply[g][m] = 1.0
			demand[g][m] = 1.0
	for m in Economy.MARKETS:
		disruption[m] = 0.0
		why[m] = ""


# ------------------------------------------------------------------ what the price sees
## The street's supply-and-demand factor on `g`'s price in `m` (1 = normal).
func factor(g: String, m: String) -> float:
	if not supply.has(g):
		return 1.0
	return clampf(pow(demand[g][m] / maxf(0.15, supply[g][m]), ELASTICITY), 0.55, 1.9)


## What the upstream sells at: dear when the source is short, cheap in a glut.
func wholesale(g: String) -> float:
	return clampf(pow(1.0 / maxf(0.2, source.get(g, 1.0)), 0.7), 0.6, 2.2)


## How long the source needs between loads (1 = normal): longer when it's short.
func restock_mult(g: String) -> float:
	return clampf(pow(1.0 / maxf(0.25, source.get(g, 1.0)), 0.5), 0.8, 2.0)


# ------------------------------------------------------------------ shocks
func _markets(m: String) -> Array:
	return Economy.MARKETS if m == "*" else [m]


func _goods(g: String) -> Array:
	return HOT if g == "*" else ([g] if supply.has(g) else [])


## Product reaches (+) or is taken off (-) the street.
func flow(g: String, m: String, amount: float, reason := "") -> void:
	for gg in _goods(g):
		for mm in _markets(m):
			supply[gg][mm] = clampf(supply[gg][mm] + amount, 0.15, 2.5)
			if reason != "":
				why[mm] = reason


## The distribution network in `m` takes a hit: at once, less gets through
## (and it stays down while the network heals).
func disrupt(m: String, amount: float, reason := "", headline := "") -> void:
	for mm in _markets(m):
		disruption[mm] = clampf(disruption[mm] + amount, 0.0, 1.0)
		for g in HOT:
			supply[g][mm] = clampf(supply[g][mm] - 0.5 * amount, 0.15, 2.5)
		if reason != "":
			why[mm] = reason
	if headline != "":
		_headline("disrupt-" + m, headline)


## Upstream: the island, the farms, the fences.
func source_shock(g: String, amount: float, headline := "") -> void:
	for gg in _goods(g):
		source[gg] = clampf(source[gg] + amount, 0.2, 2.0)
	if headline != "":
		_headline("source-" + g, headline)


## Buyers want more (mult > 1) or less for `minutes`.
func demand_shock(g: String, m: String, mult: float, minutes: float, headline := "") -> void:
	_demand_events.append({"good": g, "market": m, "mult": mult, "until": _now + minutes * 60.0})
	if headline != "":
		_headline("demand-%s-%s" % [g, m], headline)


func _headline(key: String, text: String) -> void:
	if _now - float(_last_news.get(key, -1e9)) < NEWS_GAP_S:
		return
	_last_news[key] = _now
	news.append([_now, text])
	Py.keep_last(news, 12)


# ------------------------------------------------------------------ the clock
## Advance `step` seconds. `ground` (or null): its fights disrupt the markets they're in.
func update(step: float, now: float, ground) -> void:
	_now = now
	_demand_events = _demand_events.filter(func(e): return e.until > now)
	var ks := exp(-step / SUPPLY_TAU)
	var kd := exp(-step / DEMAND_TAU)
	var kh := exp(-step / HEAL_TAU)
	var kr := exp(-step / SOURCE_TAU)
	for m in Economy.MARKETS:
		disruption[m] *= kh
	for g in HOT:
		source[g] = 1.0 + (source[g] - 1.0) * kr
		for m in Economy.MARKETS:
			var target: float = source[g] * (1.0 - 0.6 * disruption[m])
			supply[g][m] = target + (supply[g][m] - target) * ks
			var want := 1.0
			for e in _demand_events:
				if (e.good == g or e.good == "*") and (e.market == m or e.market == "*"):
					want *= e.mult
			demand[g][m] = want + (demand[g][m] - want) * kd
	if ground != null:
		_fighting(ground, step)
	# the street's own news, now and then (about one every 25 minutes)
	if _demand_events.size() < 2 and rng.random() < step / 1500.0:
		var n: Array = STREET_NEWS[rng.randint(0, STREET_NEWS.size() - 1)]
		demand_shock(n[0], n[1], n[2], n[3], n[4])


## A fight on a market's streets: corners closed while it lasts, and every
## man arrested or down is a dealer or a runner off the street.
func _fighting(ground, step: float) -> void:
	var live := {}
	for f in ground.fights:
		live[f.id] = true
		var m: String = GroundWar.market_at(f.x, f.y)
		if not f.over:
			disruption[m] = clampf(disruption[m] + 0.004 * step, 0.0, 1.0)
		var cas := 0
		for k in f.cas:
			cas += int(f.cas[k])
		var seen: Array = _fights.get(f.id, [0, 0])
		var arrested: int = f.arrests - seen[0]
		var down: int = cas - seen[1]
		if arrested > 0 or down > 0:
			disrupt(m, 0.05 * arrested + 0.025 * down, "a gunfight: %d arrested, %d down" % [arrested, down])
			flow("*", m, -0.02 * (arrested + down))
			if arrested >= 3:
				_headline("fight-" + m, "Police round up %d after a gunfight in the %s: the corners are dry" % [arrested, _name(m)])
		_fights[f.id] = [f.arrests, cas]
	for id in _fights.keys():
		if not live.has(id):
			_fights.erase(id)


static func _name(m: String) -> String:
	return {"town": "town", "west": "west side", "north": "north end", "sea": "docks"}.get(m, m)


# ------------------------------------------------------------------ the event bus
## Subscribe to the session's events: arrests, raids, seizures, the factions.
func hook(sess) -> void:
	var b: EventBus = sess.bus
	b.subscribe("busted", func(_e): _org_hit(sess, 0.3, 0.1, "the pilot was busted",
		"The organisation's pilot is in custody: its corners are short this week"))
	b.subscribe("ai_busted", func(_e): _rival_hit(sess, 0.15, 0.08, "a Los Cuervos plane went down to the law",
		"Los Cuervos lose a plane to the task force: their buyers are looking elsewhere"))
	b.subscribe("worker_arrested", func(e): (_org_hit if e.data.get("outfit", "") == "org" else _rival_hit).call(sess, 0.1, 0.03,
		"one of their people was arrested", ""))
	b.subscribe("worker_flipped", func(e): (_org_hit if e.data.get("outfit", "") == "org" else _rival_hit).call(sess, 0.25, 0.05,
		"an informant rolled up corners", "An informant is talking: street dealers vanish overnight"))
	b.subscribe("cooperating", func(_e):
		_org_hit(sess, 0.35, 0.1, "a cooperation deal", "Word is somebody took a deal: the organisation's street crews go to ground")
		demand_shock("*", "town", 0.85, 40))
	b.subscribe("sentenced", func(e):
		if int(e.data.get("years", 0)) >= 10:
			demand_shock("*", "*", 0.85, 45, "A %d-year sentence in federal court: the street goes quiet" % int(e.data.years)))
	b.subscribe("stash_raided", func(e):
		var st = sess.stash_net.get_stash(e.data.get("stash", "")) if sess.stash_net != null else null
		var m: String = st.zone if st != null else "town"
		disrupt(m, 0.35, "a stash house raided", "Police raid a stash house in the %s: the product's gone off the street" % _name(m))
		flow("cocaine", m, -0.15))
	b.subscribe("truck_seized", func(e): _stash_flow(sess, e, "cocaine", -0.1, "a truck seized"))
	b.subscribe("truck_hijacked", func(e):
		_stash_flow(sess, e, "cocaine", -0.1, "a truck hijacked")
		flow("cocaine", _rival_market(sess), 0.1, "Los Cuervos are selling a hijacked load"))
	b.subscribe("hijacked", func(_e): flow("cocaine", _rival_market(sess), 0.1, "Los Cuervos are selling a hijacked load"))
	b.subscribe("boat_seized", func(_e): flow("marijuana", "sea", -0.2, "a go-fast seized"))
	b.subscribe("weapons_seized", func(_e): flow("guns", "town", -0.12, "guns seized"))
	b.subscribe("commission_trial", func(_e):
		disrupt("town", 0.4, "the Family is finished")
		source_shock("guns", -0.35, "The Commission trial ends the Family: the town's fence is gone and guns are hard to find"))
	b.subscribe("family_torch", func(_e): disrupt("town", 0.12, "the Family torched a truck"))
	b.subscribe("island_status", _island_status)
	b.subscribe("island_purge", func(_e): source_shock("cocaine", -0.15))  # the history's purge (the island's own is above)
	b.subscribe("airport_crackdown", func(_e):
		flow("cocaine", "town", -0.08, "customs crack down at the airport")
		_headline("crackdown", "Customs crack down at the airport: fewer mules get through, the town runs short"))
	b.subscribe("island_intercept", func(_e): source_shock("cocaine", -0.05))
	b.subscribe("island_shipment", func(_e): flow("cocaine", "sea", 0.08, "our shipment came in"))
	b.subscribe("rival_shipment", func(e): flow("cocaine", str(e.data.get("market", _rival_market(sess))), 0.12,
		"a Los Cuervos container came in"))
	b.subscribe("agency_hangout", func(_e): source_shock("cocaine", -0.2, "The Company closes its pipeline while it covers itself"))


func _island_status(e) -> void:
	var st := str(e.data.get("status", ""))
	if st == "hurricane":
		source_shock("cocaine", -0.35, "Hurricane on Isla Soberana: nothing's leaving the island")
	elif st == "purge":
		source_shock("cocaine", -0.4, "The General purges his port: the island's pipeline is shut")
	elif st == "glut":
		# (the island prices its own shortages and gluts; this is what reaches the street)
		flow("cocaine", "sea", 0.15, "a glut on the island")


## Where the organisation sells: its stash houses' zones (the town if none).
func _org_markets(sess) -> Array:
	var ms := {}
	if sess.stash_net != null:
		for st in sess.stash_net.live():
			ms[st.zone] = true
	return ms.keys() if not ms.is_empty() else ["town"]


## Where Los Cuervos are strongest.
func _rival_market(sess) -> String:
	var best := "west"
	var share := -1.0
	if sess.ground != null:
		var turf: Dictionary = sess.ground.turf({})
		for m in turf:
			if float(turf[m]) > share:
				share = float(turf[m])
				best = m
	return best


func _org_hit(sess, dis: float, cut: float, reason: String, headline: String) -> void:
	for m in _org_markets(sess):
		disrupt(m, dis, reason)
		flow("*", m, -cut)
	if headline != "":
		_headline("org", headline)


func _rival_hit(sess, dis: float, cut: float, reason: String, headline: String) -> void:
	var m := _rival_market(sess)
	disrupt(m, dis, reason)
	flow("*", m, -cut)
	if headline != "":
		_headline("rival", headline)


func _stash_flow(sess, e, g: String, amount: float, reason: String) -> void:
	var st = sess.stash_net.get_stash(e.data.get("stash", "")) if sess.stash_net != null else null
	flow(g, st.zone if st != null else "town", amount, reason)


## For the desk and the market page.
func view() -> Dictionary:
	var goods := {}
	for g in HOT:
		var rows := {}
		for m in Economy.MARKETS:
			rows[m] = {"supply": snappedf(supply[g][m], 0.01), "demand": snappedf(demand[g][m], 0.01), "factor": snappedf(factor(g, m), 0.01)}
		goods[g] = {"markets": rows, "source": snappedf(source[g], 0.01), "wholesale": snappedf(wholesale(g), 0.01)}
	var dis := {}
	for m in Economy.MARKETS:
		dis[m] = snappedf(disruption[m], 0.01)
	return {"goods": goods, "disruption": dis, "why": why.duplicate()}
