class_name Economy
extends RefCounted
## The island's markets: what a load is worth, where, right now.
##
## Every good has a price index in each market (the town around the hub, and
## the three HQ zones), a mean-reverting random walk (Ornstein-Uhlenbeck) moved
## by what's happening:
##
##   rival gangs   where Los Cuervos own the market they undercut you on drugs;
##                 guns go the other way (the rivals are the customers)
##   police        units near the market, recent busts and the task force's
##                 kit add a risk premium to hot goods: the street pays for danger
##   scarcity      seizures anywhere (busts, boats, trucks, raids) push the price
##                 of that good up island-wide for a while
##   glut          your own deliveries flood the market you deliver to
##   fuel          a fuel price of its own (a walk, storms, strikes) passes
##                 through to fares, legal freight and fuel drums
##   weather       storms mean short supply: hot goods and food cost more
##   news          events: a crackdown on the mainland, a bumper harvest, a gun
##                 war, a fuel strike, tourist season
##
## Contraband is paid at the street price on delivery (the price can move
## while you fly); legal work at the price agreed on the board. Off (every
## multiplier 1) for the Python replays: Economy.REALISM = false.

static var REALISM := true

const MARKETS := ["town", "west", "north", "sea"]
const TICK_S := 10.0
const REVERT_S := 1800.0  ## the walk's pull back to 1.0 (time constant)
const RANGE_M := 9000.0  ## police or rival units this close are "in" a market

## vol: the walk's size per sqrt(minute); police/rival: sensitivity; fuel: fuel pass-through; storm: storm premium
const GOODS := {
	"cocaine": {"name": "Cocaine", "hot": true, "vol": 0.05, "police": 0.9, "rival": 1.0, "fuel": 0.0, "storm": 0.12},
	"marijuana": {"name": "Marijuana", "hot": true, "vol": 0.035, "police": 0.6, "rival": 0.8, "fuel": 0.1, "storm": 0.12},
	"guns": {"name": "Guns", "hot": true, "vol": 0.04, "police": 1.1, "rival": -0.6, "fuel": 0.0, "storm": 0.05},
	"fugitive": {"name": "Passage, no questions", "hot": true, "vol": 0.03, "police": 1.4, "rival": 0.0, "fuel": 0.2, "storm": 0.1},
	"general": {"name": "General freight", "hot": false, "vol": 0.012, "police": 0.0, "rival": 0.0, "fuel": 0.5, "storm": 0.05},
	"perishable": {"name": "Food", "hot": false, "vol": 0.025, "police": 0.0, "rival": 0.0, "fuel": 0.4, "storm": 0.18},
	"fragile": {"name": "Fragile goods", "hot": false, "vol": 0.012, "police": 0.0, "rival": 0.0, "fuel": 0.4, "storm": 0.05},
	"medical": {"name": "Medical supplies", "hot": false, "vol": 0.01, "police": 0.0, "rival": 0.0, "fuel": 0.3, "storm": 0.1},
	"fuel_drums": {"name": "Fuel drums", "hot": false, "vol": 0.0, "police": 0.0, "rival": 0.0, "fuel": 1.0, "storm": 0.0},
	"passengers": {"name": "Charter fares", "hot": false, "vol": 0.015, "police": 0.0, "rival": 0.0, "fuel": 0.6, "storm": -0.1},
}
## item label -> good (anything else: general freight; passengers by kind)
const LABELS := {"Sealed case": "cocaine", "Kilo brick crate": "cocaine", "'Coffee' sacks": "marijuana", "Bale": "marijuana",
	"Unmarked crate": "guns", "Weapons crate": "guns", "Nervous man": "fugitive", "Duffel bag": "fugitive", "Food supplies": "perishable",
	"Glass panels": "fragile", "Lab samples": "fragile", "Fuel drum": "fuel_drums", "Medical kit": "medical"}
## [good, multiplier, minutes, headline]
const EVENTS := [
	["cocaine", 1.35, 90, "Crackdown in Florida: the mainland pipeline is choked - cocaine up"],
	["cocaine", 0.75, 60, "A big shipment got through at Nassau: cocaine is cheap this week"],
	["marijuana", 0.72, 120, "Bumper harvest in the hills: marijuana prices slump"],
	["marijuana", 1.3, 80, "Paraquat scare on the mainland: island grass is in demand"],
	["guns", 1.4, 90, "Gun war across the water: every crate is spoken for"],
	["fuel", 1.45, 90, "Refinery strike: avgas is short"],
	["fuel", 0.8, 90, "A tanker in port: fuel is cheap"],
	["passengers", 1.3, 120, "Tourist season: charter fares up"],
	["perishable", 1.3, 60, "Storm damage on the farms: food prices up"],
	["medical", 1.4, 60, "Fever outbreak up-country: medical supplies wanted"],
]

var rng: PyRandom
var walk := {}  ## good -> market -> index
var fuel_walk := 1.0
var scarcity := {}  ## good -> extra (decays)
var glut := {}  ## good -> market -> discount (decays)
var busts := {}  ## market -> recent-bust weight (decays)
var heat := {}  ## market -> police presence 0..1.5 (computed each tick)
var rival := {}  ## market -> rival presence 0..1 (computed each tick)
var events: Array = []  ## {good, mult, until, text}
var news: Array = []  ## [time, text]
var storm := false
var law_kit := 0  ## the task force's upgrades bought (a little more risk everywhere)
var _t := 0.0
var _now := 0.0


func _init(rng_: PyRandom) -> void:
	rng = rng_
	for g in GOODS:
		walk[g] = {}
		glut[g] = {}
		scarcity[g] = 0.0
		for m in MARKETS:
			walk[g][m] = 1.0 + rng.uniform(-0.08, 0.08) * GOODS[g].vol / 0.05
			glut[g][m] = 0.0
	for m in MARKETS:
		busts[m] = 0.0
		heat[m] = 0.0
		rival[m] = 0.0


# ------------------------------------------------------------------ where and what
static func market_of(code: String) -> String:
	if code == "SEA":
		return "sea"
	for z in HQ.ZONE_FIELDS:
		if code in HQ.ZONE_FIELDS[z]:
			return z
	return "town"


static func centre(m: String) -> Array:
	if m == "town":
		var hub = World.AIRFIELD_BY_CODE.get("HAR")
		return [hub.x, hub.y] if hub != null else [0.0, 0.0]
	return HQ.ZONE_CENTRE.get(m, [0.0, 0.0])


static func good_of(job: Jobs.Job) -> String:
	for i in job.items:
		if LABELS.has(i.label):
			return LABELS[i.label]
	if job.kind == "passenger":
		return "passengers"
	return "general"


static func job_market(job: Jobs.Job) -> String:
	return "sea" if job.is_airdrop() else market_of(job.dest)


# ------------------------------------------------------------------ prices
func fuel_mult() -> float:
	if not REALISM:
		return 1.0
	var m := fuel_walk * (1.12 if storm else 1.0)
	for e in events:
		if e.good == "fuel":
			m *= e.mult
	return clampf(m, 0.6, 2.2)


## The price multiplier for `good` in market `m` right now (1 = the board's base price).
func mult(good: String, m: String) -> float:
	if not REALISM:
		return 1.0
	var g: Dictionary = GOODS[good]
	var p: float = walk[good][m]
	if g.hot:
		p *= 1.0 - 0.35 * g.rival * rival[m]
		p *= 1.0 + 0.25 * g.police * heat[m]
		p *= 1.0 + scarcity[good]
		p *= 1.0 - glut[good][m]
	p *= 1.0 + g.fuel * (fuel_mult() - 1.0)
	if storm:
		p *= 1.0 + g.storm
	for e in events:
		if e.good == good:
			p *= e.mult
	return clampf(p, 0.4, 2.5)


func job_mult(job: Jobs.Job) -> float:
	return mult(good_of(job), job_market(job))


# ------------------------------------------------------------------ what moves them
func record_delivery(good: String, m: String) -> void:
	if GOODS.has(good) and GOODS[good].hot:
		glut[good][m] = minf(0.4, glut[good][m] + 0.06)


func record_seizure(good: String, m: String) -> void:
	if GOODS.has(good):
		scarcity[good] = minf(0.6, scarcity[good] + 0.12)
		busts[m] = minf(2.0, busts[m] + 0.5)


## Advance: `police` and `rivals` are [[x, y], ...]; `turf` the rival share per zone (or {}).
func update(dt: float, now: float, police: Array, rivals: Array, turf: Dictionary) -> void:
	_now = now
	_t += dt
	if _t < TICK_S:
		return
	var step := _t
	_t = 0.0
	var k := exp(-step / REVERT_S)
	var sq := sqrt(step / 60.0)
	for g in GOODS:
		for m in MARKETS:
			# Ornstein-Uhlenbeck: pulled back toward 1, kicked by noise
			walk[g][m] = 1.0 + (walk[g][m] - 1.0) * k + rng.gauss(0.0, GOODS[g].vol * sq)
			glut[g][m] *= exp(-step / 900.0)
		scarcity[g] *= exp(-step / 1200.0)
	fuel_walk = 1.0 + (fuel_walk - 1.0) * k + rng.gauss(0.0, 0.02 * sq)
	for m in MARKETS:
		busts[m] *= exp(-step / 600.0)
		var c := centre(m)
		var near_p := police.filter(func(p): return PyMath.hypot(p[0] - c[0], p[1] - c[1]) < RANGE_M).size()
		var near_r := rivals.filter(func(p): return PyMath.hypot(p[0] - c[0], p[1] - c[1]) < RANGE_M).size()
		heat[m] = clampf(0.15 * near_p + 0.3 * busts[m] + 0.02 * law_kit, 0.0, 1.5)
		rival[m] = clampf(float(turf.get(m, 0.15 if m == "town" else 0.3)) + 0.1 * near_r, 0.0, 1.0)
	events = events.filter(func(e): return e.until > now)
	if events.size() < 2 and rng.random() < step / 900.0:  # about one headline every 15 minutes
		var e: Array = EVENTS[rng.randint(0, EVENTS.size() - 1)]
		if not events.any(func(x): return x.good == e[0]):
			events.append({"good": e[0], "mult": e[1], "until": now + e[2] * 60.0, "text": e[3]})
			news.append([now, e[3]])
			Py.keep_last(news, 12)


## A board for the UI: [{good, name, hot, prices: {market: mult}, trend}], plus fuel.
func board() -> Dictionary:
	var rows := []
	for g in GOODS:
		var prices := {}
		for m in MARKETS:
			prices[m] = snappedf(mult(g, m), 0.01)
		rows.append({"good": g, "name": GOODS[g].name, "hot": GOODS[g].hot, "prices": prices})
	return {"goods": rows, "fuel": snappedf(fuel_mult(), 0.01), "heat": heat.duplicate(), "rival": rival.duplicate(),
		"events": events.map(func(e): return e.text), "news": news.slice(-5).map(func(n): return n[1])}
