class_name HQ
extends RefCounted
## The strategic layer: the Organisation vs the Task Force over a season.
##
## A season is a run of nights. Each night has three phases:
##   planning   both HQs spend money and a few action points, in secret
##   operation  the runs happen - flown in 3D, by bots, or rolled by resolve_abstract
##   debrief    results feed back: dirty money, seizures, evidence, heat, budget
##
## The same rules object runs the live game and the balance simulator.
## Design notes: asymmetric goals in one race (launder enough to retire vs build
## a case to indict), every tool has a counter, negative feedback on runaway
## success plus one comeback event per side, and hidden information (each HQ
## sees its own books exactly and the other only through rumours and sources).

# Every number the balance simulator is allowed to move lives here.
const RULES := {
	"nights": 10,
	"retire_target": 52000,  # clean $ to win (45000 -> 38000 cartel -> 48000 weather -> 52000 airdrop fix; docs/BALANCE.md)
	"indict_evidence": 100.0,
	"start_dirty": 16000,
	"start_budget_k": 15.0,
	"actions_per_night": 3,
	"overhead": 1500,  # per night: crew wages, hangar, "consulting" (1000 until the airdrop fix; BALANCE.md)
	"run_payout": 12000,  # base value of one run for the C172 (15000 until the airdrop fix; BALANCE.md)
	"crew_fee": 3000,  # contract crew (AI run)
	"crew_share": 0.6,  # organisation's share of a contract crew's load
	"decoy_fee": 1500,
	"heat_decay": 6.0,
	"lie_low_decay": 18.0,
	"support_base_k": 9.0,  # law budget = base + support term + heat term
	"support_k": 12.0,
	"heat_k": 0.10,
	"seizure_share": 0.8,  # fraction of seized value paid to the task force (1984: up to 80%)
	"evidence_bust": 6.0,
	"evidence_crew_bust": 2.0,
	"bust_fine": 3000,
	"evidence_flip": 10.0,
	"evidence_informant": 1.8,  # per informant per night
	"evidence_wiretap": 3.0,
	"evidence_audit_k": 8.0,  # per point of laundering exposure
	"evidence_bribe": 12.0,
	"evidence_decay": 1.5,
	"flip_base": 0.55,
	"tip_base": 0.20,  # chance an informant hears about tonight's route
	"comeback_gap": 0.25,
	"fed_bonus_k": 10.0,
	"cartel_bonus": 0.30,
	# the rival cartel (Los Cuervos): a third, AI-run outfit fighting you for turf
	"rivals": true,
	"rival_market": 0.3,  # payout lost in a zone at full rival control
	"rival_hijack_base": 0.2,  # hijack chance when you meet them on the same route
	"rival_hijack_k": 0.3,  # ... plus this much at full rival strength
	"hit_cost": 5000,
	"truce_share": 0.15,  # of your takings, per night of truce
	"truce_nights": 3,
	"gang_unit_k": 4.0,  # $k: the chief's squad for the cartel war
	# the realism layer (docs/BALANCE.md 14-18): its own random stream, like the cartel's
	"weather": true,  # nightly sky, wind and moon: cover, crash risk, grounded balloons and helicopters
	"pattern": true,  # the task force's analysts learn your routine: repeat a route and they expect you
	"pattern_k": 0.45,  # detection bonus when every recent sighting was on tonight's route
	"storm_heli": 0.4,  # helicopter effectiveness in a storm (most won't launch into a thunderstorm)
	"storm_sea": 0.5,  # cutters in heavy seas
	"storm_balloon": true,  # the aerostat is winched down for lightning
	"weather_vis": true,  # sky and moon change detection
	"weather_crash": true,  # sky changes crash risk
	"canary": true,  # the chief can feed the dispatch line a false patrol to smoke out a leak
	"rival_tempers": true,  # Los Cuervos are tit-for-tat, grudgers or opportunists; truces unravel near the end
}

## The Python game's rules (no cartel, the old retire target): parity tests run with these.
const PYTHON_RULES := {"rivals": false, "retire_target": 45000, "weather": false, "pattern": false,
	"canary": false, "rival_tempers": false, "run_payout": 15000, "overhead": 1000}
const REALISM := ["weather", "pattern", "canary", "rival_tempers"]

## Sky -> [chance, wind kt range, visibility factor on detection, crash factor].
## Both factors average ~1 over the season: weather moves risk between nights
## (a timing decision), it doesn't hand either side a flat bonus (BALANCE.md 14).
const SKIES := {
	"clear": [0.55, [4, 12], 1.1, 0.8],
	"cloud": [0.30, [8, 18], 0.9, 1.1],
	"storm": [0.15, [18, 30], 0.7, 2.2],
}
const AEROSTAT_MAX_WIND := 25  ## kt: above this, or with lightning about, the tethered balloon is winched down (TARS practice)
const MOON_DAYS := 29.53
const TEMPERS := ["tit_for_tat", "grudger", "opportunist"]

const ZONES := ["west", "north", "sea"]
static var ZONE_CENTRE := {"west": [-9000.0, 3000.0], "north": [2000.0, 8000.0], "sea": [13000.0, -11000.0]}  ## per map (World.use_layout)
static var ZONE_FIELDS := {"west": ["QRY", "FRM"], "north": ["EGL", "PNR", "ISL"], "sea": ["COV"]}
const ZONE_PAY := {"west": 1.0, "north": 1.15, "sea": 1.3}

const AIRCRAFT_TIERS := [  # [key, price, payout multiplier, heat on purchase]
	["c172p", 0, 1.0, 0],
	["c182", 25000, 1.4, 6],
	["c310", 70000, 2.2, 12],
]

const FRONTS := {  # name: [price, laundering capacity per night, fee]
	"laundromat": [6000, 4000, 0.10],
	"car_lot": [18000, 9000, 0.15],
	"marina": [40000, 20000, 0.20],
}

const BRIBES := {  # name: [cost per night, what it does]
	"harbor": [2000, "harbor master: cutters sail late, one fewer at sea"],
	"tower": [1500, "tower chief: no customs checks at police fields"],
	"dispatcher": [3000, "police dispatcher: you hear the patrol plan and every radio call"],
}

const LAW_COSTS_K := {  # $k per night unless noted
	"heli": 4.0, "interceptor": 7.0, "cutter": 4.0, "aerostat": 6.0,
	"informant": 5.0, "informant_upkeep": 1.0, "wiretap": 7.0, "audit": 3.0,
	"ia_sweep": 4.0, "encryption": 5.0,  # one-off
	"canary": 1.5,
}
const INFORMANT_CAP := 2  ## was 3: stacked tip+intercept+evidence made it the dominant lever (docs/BALANCE.md)

const RUNNER_ACTIONS := ["launder", "buy_front", "bribe", "drop_bribe", "loyalty", "lawyer", "opsec",
	"counterintel", "crews", "decoys", "route", "lie_low", "upgrade", "gear", "hit_rival", "truce", "tip_off", "ready"]
const GEAR_PRICES := {"scanner": 1800, "detector": 2500}
const LAW_ACTIONS := ["fund", "patrol", "aerostat", "recruit", "wiretap", "audit", "ia_sweep",
	"encryption", "press", "gang_unit", "canary", "ready"]
const FREE_ACTIONS := ["launder", "route", "ready", "drop_bribe"]  ## don't cost an action point


class Org:
	var dirty := 0
	var clean := 0
	var heat := 10.0
	var loyalty := 0.5
	var fronts: Array = ["laundromat"]
	var bribes := {}  ## set
	var lawyer := false
	var tier := 0  ## index into AIRCRAFT_TIERS
	var exposure := 0.0  ## laundering that looks wrong on paper
	var gear := {}  ## set: scanner, detector (tactical)
	# tonight
	var opsec := false
	var crews := 0
	var decoys := 0
	var route := "west"
	var lie_low := false
	var counterintel := false
	var laundered_tonight := 0
	var actions := 0
	var ready := false

	func capacity() -> int:
		var s := 0
		for f in fronts:
			s += FRONTS[f][1]
		return s

	func payout_mult() -> float:
		return AIRCRAFT_TIERS[tier][2]

	func to_dict() -> Dictionary:
		var b := bribes.keys()
		b.sort()
		var g := gear.keys()
		g.sort()
		return {"dirty": dirty, "clean": clean, "heat": heat, "loyalty": loyalty, "fronts": fronts.duplicate(),
			"bribes": b, "lawyer": lawyer, "tier": tier, "exposure": exposure, "gear": g, "opsec": opsec,
			"crews": crews, "decoys": decoys, "route": route, "lie_low": lie_low, "counterintel": counterintel,
			"laundered_tonight": laundered_tonight, "actions": actions, "ready": ready}


## The rival cartel. Runs its own loads each night (rolled by the resolver, or
## flown as AI traffic in the live game), grows or loses turf and strength, and
## hijacks your loads when you meet it on the same route without a truce.
class Rival:
	var name := "Los Cuervos"
	var strength := 50.0  ## 0..100
	var cash := 20000
	var turf := {"west": 0.35, "north": 0.25, "sea": 0.55}  ## rival share of each zone's market
	var truce_nights := 0
	var grudge := 0  ## nights of retaliation left (they know who sold them out, or who shot at them)
	var busts := 0
	var temper := ""  ## tit_for_tat | grudger | opportunist (hidden; rules.rival_tempers)
	var wronged := 0  ## times you hit them or sold them out
	var wronged_night := -99
	var kept := 0  ## truce nights they honoured
	var betrayals := 0
	var revealed := false  ## you've learned what kind of outfit they are
	# tonight
	var betrayed := false
	var zone = null
	var runs := 0
	var tipped := false  ## you sold their route to the police
	var hit := false

	func band() -> String:
		return ["broken", "weak", "steady", "strong", "dominant"][mini(4, int(strength / 20.5))]

	func to_dict() -> Dictionary:
		return {"name": name, "strength": Py.round_n(strength, 1), "cash": cash, "turf": turf.duplicate(),
			"truce_nights": truce_nights, "grudge": grudge, "busts": busts, "zone": zone, "runs": runs,
			"tipped": tipped, "hit": hit, "temper": temper, "wronged": wronged, "kept": kept,
			"betrayals": betrayals, "revealed": revealed, "betrayed": betrayed}

	## What the organisation has worked out about them.
	func reputation() -> String:
		if temper == "":
			return ""
		if not revealed:
			return "unknown: kept %d truce night(s), broke %d" % [kept, betrayals]
		return {"tit_for_tat": "tit for tat: they pay back what you do", "grudger": "grudge-holders: they never forget",
			"opportunist": "opportunists: a truce lasts while it pays"}[temper]


class TaskForce:
	var bank_k := 0.0
	var support := 50.0
	var evidence := 0.0
	var informants := 0
	var encryption := false
	var fed_arrived := false
	# tonight
	var budget_k := 0.0
	var funded := {"heli": 0, "interceptor": 0, "cutter": 0}
	var aerostat := false
	var patrol = null
	var wiretap := false
	var audit := false
	var ia_sweep := false
	var press := false
	var gang_unit := false
	var canary := false
	var canary_zone = null  ## the false patrol fed to the dispatch line
	var actions := 0
	var ready := false

	func to_dict() -> Dictionary:
		return {"gang_unit": gang_unit, "canary": canary, "canary_zone": canary_zone, "bank_k": bank_k, "support": support, "evidence": evidence, "informants": informants,
			"encryption": encryption, "fed_arrived": fed_arrived, "budget_k": budget_k, "funded": funded.duplicate(),
			"aerostat": aerostat, "patrol": patrol, "wiretap": wiretap, "audit": audit, "ia_sweep": ia_sweep,
			"press": press, "actions": actions, "ready": ready}


## One flight's outcome, from the 3D game, a bot or the abstract resolver.
class RunResult:
	var kind: String  ## main | crew | decoy
	var zone: String
	var detected := false
	var intercepted := false
	var busted := false
	var crashed := false
	var boat_seized := false
	var delivered_value := 0  ## dirty $ to the organisation
	var seized_value := 0  ## street value taken by the police
	var clean_stop := false  ## police forced down a clean aircraft (decoy)
	var hijacked := false  ## the rival cartel took the load

	func _init(kind_: String, zone_: String, opts := {}) -> void:
		kind = kind_
		zone = zone_
		for k in opts:
			set(k, opts[k])


class NightReport:
	var night: int
	var runs: Array
	var lines: Array = []  ## public news
	var runner_lines: Array = []
	var law_lines: Array = []

	func _init(night_: int, runs_: Array) -> void:
		night = night_
		runs = runs_


class Season:
	var rng: PyRandom
	var rules: Dictionary
	var org: Org
	var law: TaskForce
	var night := 1
	var phase := "planning"  ## planning | operation | debrief | over
	var winner = null
	var reason := ""
	var history: Array = []
	var reports: Array = []
	var runner_log: Array = []
	var law_log: Array = []
	var cartel_bonus := false
	var plan := {}
	var plan_hist: Array = []
	var rival: Rival = null  ## null when rules.rivals is off (and for Python-parity runs)
	var rrng: PyRandom  ## the rivals' own random stream: switching them off leaves every other roll unchanged
	var disabled := {}  ## ablations: orders that just answer "disabled" (Python monkeypatches them)
	var xrng: PyRandom = null  ## the realism layer's stream (rules.weather/pattern/canary/rival_tempers)
	var forecast := {}  ## tonight's forecast, known to both HQs while planning
	var weather := {}  ## what actually blew in (the forecast is right 75% of the time)
	var moon0 := 0.0  ## moon phase on night 1 (0 = new)
	var sightings: Array = []  ## per night: the zone where the law saw your own run, or ""

	func _init(rng_: PyRandom = null, rules_ := {}) -> void:
		if rng_ == null:
			rng_ = PyRandom.new()
			rng_.seed(randi())
		rng = rng_
		rules = HQ.RULES.duplicate()
		rules.merge(rules_, true)
		org = Org.new()
		org.dirty = int(rules["start_dirty"])
		law = TaskForce.new()
		if Py.truthy(rules.get("rivals", false)):
			rival = Rival.new()
			rrng = PyRandom.new()
			rrng.seed(int(rng.random() * 2147483647.0))
		if REALISM.any(func(k): return Py.truthy(rules.get(k, false))):
			xrng = PyRandom.new()
			xrng.seed(int(rng.random() * 2147483647.0))
			moon0 = xrng.random()
			if rival != null and Py.truthy(rules.get("rival_tempers", false)):
				rival.temper = TEMPERS[xrng.randint(0, 2)]
		_begin_planning()

	func on(rule: String) -> bool:
		return Py.truthy(rules.get(rule, false))

	## Moon illumination tonight, 0 (new) .. 1 (full).
	func moon(n := -1) -> float:
		var ph := moon0 + float(night if n < 0 else n) / MOON_DAYS
		return 0.5 - 0.5 * cos(TAU * ph)

	func _draw_weather() -> Dictionary:
		var r := xrng.random()
		var sky := "storm"
		for k in ["clear", "cloud"]:
			r -= SKIES[k][0]
			if r < 0:
				sky = k
				break
		var w: Array = SKIES[sky][1]
		return {"sky": sky, "wind_kt": xrng.randint(w[0], w[1]), "wind_dir": xrng.randint(0, 35) * 10, "moon": Py.round_n(moon(), 2)}

	## How much the law's analysts expect you on each route: the share of the last
	## four nights' sightings that fell there, times pattern_k.
	func pattern_exposure() -> Dictionary:
		var out := {}
		var recent := sightings.slice(-4)
		for z in ZONES:
			var n := recent.count(z)
			out[z] = rules["pattern_k"] * n / 4.0 if on("pattern") else 0.0
		return out

	## What the dispatcher tells the organisation about tonight's patrol.
	func leak_zone():
		return law.canary_zone if law.canary else law.patrol

	# ============================================================ planning
	func _begin_planning() -> void:
		var o := org
		var L := law
		var R := rules
		phase = "planning"
		o.opsec = false
		o.lie_low = false
		o.counterintel = false
		o.crews = 0
		o.decoys = 0
		o.laundered_tonight = 0
		o.actions = int(R["actions_per_night"])
		o.ready = false
		L.funded = {"heli": 0, "interceptor": 0, "cutter": 0}
		L.aerostat = false
		L.wiretap = false
		L.audit = false
		L.ia_sweep = false
		L.press = false
		L.gang_unit = false
		L.canary = false
		L.canary_zone = null
		L.patrol = null
		if rival != null:
			rival.tipped = false
			rival.hit = false
			rival.zone = null
			rival.runs = 0
			rival.betrayed = false
		if on("weather"):
			forecast = _draw_weather()
			weather = {}
		L.actions = int(R["actions_per_night"])
		L.ready = false
		L.budget_k = (R["support_base_k"] + R["support_k"] * L.support / 100.0 + R["heat_k"] * o.heat
			+ L.bank_k - LAW_COSTS_K["informant_upkeep"] * L.informants)
		if night == 1:
			L.budget_k += R["start_budget_k"] - R["support_base_k"]
		L.bank_k = 0.0
		# standing costs come off the organisation's books up front
		var standing: float = R["overhead"] + (3000 if o.lawyer else 0)
		var bribe_total := 0
		for b in o.bribes:
			bribe_total += BRIBES[b][0]
		standing = R["overhead"] + bribe_total + (3000 if o.lawyer else 0)
		o.dirty -= int(standing)

	## Returns an error string, or null if done.
	func runner_cmd(name: String, a := {}):
		if phase != "planning":
			return "HQ decisions happen between runs."
		if not RUNNER_ACTIONS.has(name):
			return "Unknown order %s." % name
		var o := org
		if not FREE_ACTIONS.has(name) and o.actions <= 0:
			return "No more moves tonight."
		var err = "disabled" if disabled.has("_r_" + name) else call("_r_" + name, a)
		if err == null and not FREE_ACTIONS.has(name):
			o.actions -= 1
		return err

	func law_cmd(name: String, a := {}):
		if phase != "planning":
			return "Plans are set between operations."
		if not LAW_ACTIONS.has(name):
			return "Unknown order %s." % name
		var L := law
		var free: bool = name in ["ready", "fund", "patrol"]
		if not free and L.actions <= 0:
			return "No more moves tonight."
		var err = "disabled" if disabled.has("_l_" + name) else call("_l_" + name, a)
		if err == null and not free:
			L.actions -= 1
		return err

	# ---- organisation orders
	func _r_launder(a: Dictionary):
		var o := org
		var room := o.capacity() - o.laundered_tonight
		var amount: int = room if a.get("amount") == null else mini(int(a.amount), room)
		amount = mini(amount, maxi(0, o.dirty))
		if amount <= 0:
			return "Nothing to wash (or the fronts are full tonight)."
		var num := 0.0
		for f in o.fronts:
			num += FRONTS[f][2] * FRONTS[f][1]
		var fee := num / maxi(1, o.capacity())
		o.dirty -= amount
		o.clean += int(amount * (1 - fee))
		o.laundered_tonight += amount
		return null

	func _r_buy_front(a: Dictionary):
		var o := org
		var kind := str(a.get("kind", ""))
		if not FRONTS.has(kind):
			return "Unknown front."
		var price: int = FRONTS[kind][0]
		if o.dirty < price:
			return "Need $%s in cash." % Py.money(price)
		o.dirty -= price
		o.fronts.append(kind)
		o.heat += 3
		runner_log.append("Bought a %s (+$%s/night laundering)" % [kind.replace("_", " "), Py.money(FRONTS[kind][1])])
		return null

	func _r_bribe(a: Dictionary):
		var o := org
		var who := str(a.get("who", ""))
		if not BRIBES.has(who) or o.bribes.has(who):
			return "Can't bribe that."
		if o.dirty < BRIBES[who][0]:
			return "Not enough cash."
		o.bribes[who] = true
		o.dirty -= BRIBES[who][0]  # first night paid now; then standing cost
		runner_log.append("On the payroll: " + BRIBES[who][1])
		return null

	func _r_drop_bribe(a: Dictionary):
		org.bribes.erase(str(a.get("who", "")))
		return null

	func _r_loyalty(a: Dictionary):
		var o := org
		if o.dirty < 2500:
			return "Not enough cash."
		o.dirty -= 2500
		o.loyalty = minf(1.0, o.loyalty + 0.2)
		return null

	func _r_lawyer(a: Dictionary):
		org.lawyer = Py.truthy(a.get("on", true))
		return null

	func _r_opsec(a: Dictionary):
		var o := org
		if o.dirty < 1000:
			return "Not enough cash."
		o.dirty -= 1000
		o.opsec = true
		return null

	func _r_counterintel(a: Dictionary):
		var o := org
		if o.dirty < 4000:
			return "Not enough cash."
		o.dirty -= 4000
		o.counterintel = true
		return null

	func _r_crews(a: Dictionary):
		var o := org
		var n := maxi(0, mini(2, int(a.get("n", 1))))
		var cost := int(rules["crew_fee"]) * n
		if o.dirty < cost:
			return "Not enough cash."
		o.dirty -= cost
		o.crews = n
		return null

	func _r_decoys(a: Dictionary):
		var o := org
		var n := maxi(0, mini(2, int(a.get("n", 1))))
		var cost := int(rules["decoy_fee"]) * n
		if o.dirty < cost:
			return "Not enough cash."
		o.dirty -= cost
		o.decoys = n
		return null

	func _r_route(a: Dictionary):
		var zone = a.get("zone")
		if not ZONES.has(zone):
			return "Unknown zone."
		org.route = zone
		return null

	func _r_lie_low(a: Dictionary):
		org.lie_low = true
		return null

	func _r_upgrade(a: Dictionary):
		var o := org
		if o.tier + 1 >= AIRCRAFT_TIERS.size():
			return "Already flying the best."
		var t: Array = AIRCRAFT_TIERS[o.tier + 1]
		if o.dirty < t[1]:
			return "Need $%s." % Py.money(t[1])
		o.dirty -= t[1]
		o.tier += 1
		o.heat += t[3]
		runner_log.append("New aircraft: " + AIRCRAFT_TIERS[o.tier][0])
		return null

	func _r_gear(a: Dictionary):
		var o := org
		var name := str(a.get("name", ""))
		if not GEAR_PRICES.has(name) or o.gear.has(name):
			return "Can't buy that."
		if o.dirty < GEAR_PRICES[name]:
			return "Not enough cash."
		o.dirty -= GEAR_PRICES[name]
		o.gear[name] = true
		return null

	func _r_ready(a: Dictionary):
		org.ready = true
		return null

	# ---- the cartel war (rules.rivals)
	## Send the muscle: they lose strength and turf on your route, you get heat and
	## the task force gets a violence file. Halves tonight's hijack risk; ends any truce.
	func _r_hit_rival(a: Dictionary):
		var o := org
		if rival == null:
			return "No rival outfit on the island."
		var cost := int(rules["hit_cost"])
		if o.dirty < cost:
			return "Not enough cash."
		o.dirty -= cost
		rival.strength = maxf(0.0, rival.strength - 20.0)
		rival.turf[o.route] = maxf(0.05, rival.turf[o.route] - 0.15)
		rival.truce_nights = 0
		rival.grudge = maxi(rival.grudge, 2)
		rival.hit = true
		rival.wronged += 1
		rival.wronged_night = night
		o.heat += 12
		law.evidence += 3.0
		runner_log.append("Your people hit a Cuervos stash in the %s." % o.route)
		return null

	## Offer a truce: three nights of peace for a share of your takings. The
	## stronger they are, the less they need it.
	func _r_truce(a: Dictionary):
		if rival == null:
			return "No rival outfit on the island."
		if rival.truce_nights > 0:
			return "The truce already holds."
		if rival.grudge > 0:
			return "They want blood, not talk."
		if on("rival_tempers"):
			if rival.temper == "grudger" and rival.wronged > 0:
				rival.revealed = true
				return "%s never forget: no truce with you, ever." % rival.name
			if rival.temper == "tit_for_tat" and rival.wronged_night >= night - 1:
				return "Too soon: %s answer what you did last, not what you say." % rival.name
		var p := clampf(0.85 - rival.strength / 200.0, 0.2, 0.9)
		if rrng.random() < p:
			rival.truce_nights = int(rules["truce_nights"])
			runner_log.append("Truce with %s: %d nights, %d%% of the takings." % [rival.name, rival.truce_nights, int(rules["truce_share"] * 100)])
		else:
			runner_log.append("%s laughed at the offer." % rival.name)
		return null

	## Sell their route to the task force: their run tonight is as good as flagged,
	## and a friend in the task force loses some of your paperwork. If they get
	## busted they may work out who talked.
	func _r_tip_off(a: Dictionary):
		if rival == null:
			return "No rival outfit on the island."
		if rival.truce_nights > 0:
			rival.truce_nights = 0
			rival.grudge = maxi(rival.grudge, 2)
			runner_log.append("You broke the truce.")
		rival.tipped = true
		rival.wronged += 1
		rival.wronged_night = night
		law.support += 2.0
		law.evidence = maxf(0.0, law.evidence - 4.0)
		return null

	# ---- task force orders
	func _spend(k: float):
		if law.budget_k + 1e-9 < k:
			return "Over budget ($%sk left)." % Py.f(law.budget_k, 0)
		law.budget_k -= k
		return null

	func _l_fund(a: Dictionary):
		var unit := str(a.get("unit", ""))
		if not law.funded.has(unit):
			return "Unknown unit."
		var n := maxi(0, mini(3, int(a.get("n", 1))))
		var diff: int = n - law.funded[unit]
		var err = _spend(diff * LAW_COSTS_K[unit]) if diff > 0 else null
		if err:
			return err
		if diff < 0:
			law.budget_k += -diff * LAW_COSTS_K[unit]
		law.funded[unit] = n
		return null

	func _l_patrol(a: Dictionary):
		var zone = a.get("zone")
		if zone != null and not ZONES.has(zone):
			return "Unknown zone."
		law.patrol = zone
		if law.canary and zone == law.canary_zone:  # keep the lie a lie
			law.canary_zone = ZONES.filter(func(z): return z != zone)[0]
		return null

	func _l_aerostat(a: Dictionary):
		var err = _spend(LAW_COSTS_K["aerostat"])
		if not err:
			law.aerostat = true
		return err

	func _l_recruit(a: Dictionary):
		var n := law.informants
		if n >= INFORMANT_CAP:
			return "Enough informants to handle."
		# the first informant is a free-standing tip; each one after that needs its own
		# approach into a smaller, more guarded circle - dearer and less likely to land
		var err = _spend(LAW_COSTS_K["informant"] * (1 + n))
		if not err:
			# recruiting works better when the crews are unhappy
			if rng.random() < (0.85 - 0.5 * org.loyalty) * (0.6 ** n):
				law.informants += 1
				law_log.append("New informant inside the organisation.")
			else:
				law_log.append("Approach failed - they wouldn't talk.")
		return err

	func _l_wiretap(a: Dictionary):
		if law.evidence < 20:
			return "No judge will sign a warrant yet (need 20 evidence)."
		var err = _spend(LAW_COSTS_K["wiretap"])
		if not err:
			law.wiretap = true
		return err

	func _l_audit(a: Dictionary):
		var err = _spend(LAW_COSTS_K["audit"])
		if not err:
			law.audit = true
		return err

	func _l_ia_sweep(a: Dictionary):
		var err = _spend(LAW_COSTS_K["ia_sweep"])
		if not err:
			law.ia_sweep = true
		return err

	func _l_encryption(a: Dictionary):
		if law.encryption:
			return "Already encrypted."
		var err = _spend(LAW_COSTS_K["encryption"])
		if not err:
			law.encryption = true
		return err

	func _l_press(a: Dictionary):
		var busts := 0
		if not reports.is_empty():
			for r in reports.back().runs:
				if r.busted or r.boat_seized:
					busts += 1
		if not busts:
			return "Nothing to show the cameras."
		law.press = true
		return null

	## A squad for the cartel war: the rivals' runs are far likelier to be caught
	## tonight (and each rival bust is good press), at the cost of focus on the organisation.
	func _l_gang_unit(a: Dictionary):
		if rival == null:
			return "No cartel war to fight."
		if law.gang_unit:
			return "The gang unit is already out."
		var err = _spend(rules["gang_unit_k"])
		if err:
			return err
		law.gang_unit = true
		return null

	## A canary trap: tell the dispatch line the patrol is somewhere it isn't. If
	## the organisation's plan swerves around the fake, the leak is found.
	func _l_canary(a: Dictionary):
		if not on("canary"):
			return "No canary traps in these rules."
		if law.patrol == null:
			return "Set the patrol first: the canary needs a real plan to lie about."
		if law.canary:
			return "The canary is already singing."
		var err = _spend(LAW_COSTS_K["canary"])
		if err:
			return err
		law.canary = true
		var fakes := ZONES.filter(func(z): return z != law.patrol)
		law.canary_zone = fakes[xrng.randint(0, fakes.size() - 1)]
		law_log.append("Canary: dispatch hears the patrol goes %s (it goes %s)." % [law.canary_zone, law.patrol])
		return null

	func _l_ready(a: Dictionary):
		law.ready = true
		return null

	# ============================================================ operation
	## Lock the plans; returns what the tactical layer needs to set up the night.
	func start_operation() -> Dictionary:
		var o := org
		var L := law
		phase = "operation"
		var tip := informant_tip()
		var wire: bool = L.wiretap and not o.opsec
		var leak_patrol: bool = o.bribes.has("dispatcher")
		if on("weather"):
			weather = forecast.duplicate()
			if xrng.random() < 0.25:  # the forecast was wrong: one step better or worse
				var order := ["clear", "cloud", "storm"]
				var i := clampi(order.find(forecast["sky"]) + (1 if xrng.random() < 0.5 else -1), 0, 2)
				weather["sky"] = order[i]
				var w: Array = SKIES[order[i]][1]
				weather["wind_kt"] = xrng.randint(w[0], w[1])
		plan = {
			"night": night,
			"route": o.route,
			"runs": 0 if o.lie_low else 1,
			"crews": 0 if o.lie_low else o.crews,
			"decoys": o.decoys,
			"tier": o.tier,
			"funded": L.funded.duplicate(),
			"cutters": maxi(0, L.funded["cutter"] - (1 if o.bribes.has("harbor") else 0)),
			"aerostat": L.aerostat,
			"patrol": L.patrol,
			"encryption": L.encryption and not o.bribes.has("dispatcher"),
			"tip": tip or wire,
			"tip_zone": o.route if (tip or wire) else null,
			"leak_patrol": leak_zone() if leak_patrol else null,
			"leak_aerostat": L.aerostat if leak_patrol else false,
			"no_customs": o.bribes.has("tower"),
		}
		if on("weather"):
			plan["weather"] = weather.duplicate()
			if L.aerostat and ((weather["sky"] == "storm" and Py.truthy(rules["storm_balloon"])) or int(weather["wind_kt"]) > AEROSTAT_MAX_WIND):
				plan["aerostat"] = false
				plan["leak_aerostat"] = false
				law_log.append("Aerostat winched down: %s, %d kt." % ["lightning" if weather["sky"] == "storm" else "wind", int(weather["wind_kt"])])
		if on("pattern"):
			plan["pattern"] = pattern_exposure()
		if L.canary:
			plan["canary"] = L.canary_zone
		if rival != null:
			_plan_rival()
		plan_hist.append(plan)
		return plan

	## Where Los Cuervos fly tonight, and how dangerous meeting them would be.
	func _plan_rival() -> void:
		var o := org
		var rv := rival
		var weights := []
		for z in ZONES:
			var w: float = (0.25 + rv.turf[z]) * ZONE_PAY[z]
			if law.patrol == z and rrng.random() < 0.5:  # their own sources
				w *= 0.3
			if rv.truce_nights > 0 and z == o.route:
				w *= 0.05
			weights.append(w)
		var total := 0.0
		for w in weights:
			total += w
		var pick := rrng.random() * total
		var zone: String = ZONES[ZONES.size() - 1]
		for i in ZONES.size():
			pick -= weights[i]
			if pick < 0:
				zone = ZONES[i]
				break
		rv.zone = zone
		rv.runs = 0 if rv.strength < 10 else (2 if rv.strength > 70 else 1)
		var hijack := 0.0
		if rv.truce_nights == 0 and rv.runs > 0 and not o.lie_low:
			if zone == o.route:
				hijack = rules["rival_hijack_base"] + rules["rival_hijack_k"] * rv.strength / 100.0 + (0.15 if rv.grudge > 0 else 0.0)
			elif rv.grudge > 0:
				hijack = 0.1  # they come looking for you
			if rv.hit:
				hijack *= 0.5
		plan["rival_zone"] = zone
		plan["rival_runs"] = rv.runs
		plan["rival_tipped"] = rv.tipped
		plan["gang_unit"] = law.gang_unit
		plan["truce"] = rv.truce_nights > 0
		plan["hijack_p"] = hijack
		# a truce is an iterated prisoner's dilemma: it holds while the future is worth
		# more than one betrayal. Opportunists defect as the season runs out.
		if on("rival_tempers") and rv.truce_nights > 0 and not o.lie_low:
			var left := int(rules["nights"]) - night
			var p: float = {"tit_for_tat": 0.02, "grudger": 0.0,
				"opportunist": 0.08 + (0.6 if left <= 1 else (0.3 if left == 2 else 0.0))}[rv.temper]
			if rv.temper == "tit_for_tat" and rv.wronged_night >= night - 1:
				p = 0.6  # you hit them last night: they hit back
			if xrng.random() < p:
				rv.betrayed = true
				rv.betrayals += 1
				rv.revealed = true
				rv.truce_nights = 0
				plan["truce"] = false
				plan["tip"] = true  # they sell your route to the task force
				plan["tip_zone"] = o.route
				plan["rival_betrayed"] = true
				law_log.append("Anonymous caller with an accent: the organisation flies the %s tonight." % o.route)

	func informant_tip() -> bool:
		var L := law
		var o := org
		if L.informants <= 0 or o.lie_low:
			return false
		var p: float = 1 - (1 - rules["tip_base"] * (1.0 - 0.6 * o.loyalty)) ** L.informants
		return rng.random() < p

	# ============================================================ debrief
	## live=true: the main run was flown in the Session, which already paid the
	## pilot, charged the fines and the repairs.
	func finish_night(runs: Array, live := false) -> NightReport:
		var o := org
		var L := law
		var R := rules
		var rep := NightReport.new(night, runs)
		var takings := 0
		# --- the organisation's takings
		for r in runs:
			if r.kind == "rival":
				_rival_run(r, rep)
				continue
			if r.hijacked:
				o.heat += 6
				rep.lines.append("Shots fired at a remote strip: a load changes hands.")
				rep.runner_lines.append("%s hijacked tonight's load in the %s." % [rival.name, r.zone])
			if r.delivered_value and rival != null:
				# Cuervos undercut you where they own the market; you take turf by delivering
				var lost := int(r.delivered_value * R["rival_market"] * rival.turf[r.zone] * (R["crew_share"] if r.kind == "crew" else 1.0))
				o.dirty -= lost
				takings -= lost
				rival.turf[r.zone] = maxf(0.05, rival.turf[r.zone] - 0.06)
			if r.delivered_value and not (live and r.kind == "main"):
				var share: float = R["crew_share"] if r.kind == "crew" else 1.0
				o.dirty += int(r.delivered_value * share * (1 + (R["cartel_bonus"] if cartel_bonus else 0.0)))
			if r.delivered_value:
				takings += int(r.delivered_value * (R["crew_share"] if r.kind == "crew" else 1.0))
			if r.detected and r.kind != "decoy":
				o.heat += 4
			if r.delivered_value:
				o.heat += 2
			if r.crashed and r.kind == "main" and not live:
				o.dirty -= 3000
				rep.lines.append("Wreck found in the hills. No pilot at the scene.")
			if r.clean_stop:
				L.support -= 4
				rep.lines.append("Police force down a private plane - nothing aboard. Complaints filed.")
			if r.busted:
				o.heat += 10
				L.support += 7
				L.bank_k += r.seized_value / 1000.0 * R["seizure_share"]
				# a contract crew doesn't know who they work for; your own pilot does
				var ev: float = (R["evidence_bust"] if r.kind == "main" else R["evidence_crew_bust"]) * (0.5 if o.lawyer else 1.0)
				L.evidence += ev
				rep.lines.append("Pilot arrested with $%s of contraband." % Py.money(r.seized_value))
				if r.kind == "main" and not live:
					o.dirty -= int(R["bust_fine"])
				var flip: float = R["flip_base"] * (1 - o.loyalty) * (0.35 if o.lawyer else 1.0) if r.kind == "main" else 0.0
				if rng.random() < flip:
					L.informants = mini(INFORMANT_CAP, L.informants + 1)
					L.evidence += R["evidence_flip"]
					rep.law_lines.append("The arrested pilot is talking.")
			if r.boat_seized:
				L.support += 3
				L.evidence += 5
				L.bank_k += r.seized_value / 1000.0 * R["seizure_share"]
				rep.lines.append("Coast Guard seizes a go-fast boat.")
		# --- the realism layer
		if on("pattern"):
			var seen := ""
			for r in runs:
				if r.kind == "main" and r.detected:
					seen = r.zone
			sightings.append(seen)
		var fake = plan.get("canary")
		if fake != null:
			var main_zone = null
			for r in runs:
				if r.kind == "main":
					main_zone = r.zone
			var planned: String = plan.get("planned_route", plan.get("route", ""))
			if planned == fake and main_zone != null and main_zone != fake and o.bribes.has("dispatcher"):
				o.bribes.erase("dispatcher")
				L.evidence += R["evidence_bribe"]
				L.support += 2
				rep.law_lines.append("The canary sang: they swerved around a patrol that never flew. The dispatcher is arrested.")
				rep.runner_lines.append("Our man in dispatch fed us a fake patrol - and got arrested for it. It was a trap.")
			else:
				rep.law_lines.append("The canary stayed quiet.")
		if rival != null and on("rival_tempers"):
			if rival.betrayed:
				rep.runner_lines.append("%s sold your route to the task force. The truce is dead." % rival.name)
			elif rival.truce_nights > 0:
				rival.kept += 1
				if rival.kept >= 4 and rival.temper != "opportunist":
					rival.revealed = true
		# --- investigations
		if L.informants:
			L.evidence += R["evidence_informant"] * L.informants * (1.0 - 0.5 * o.loyalty)
		if L.wiretap:
			if o.opsec:
				rep.law_lines.append("Wiretap: nothing but pay-phone silence.")
			else:
				L.evidence += R["evidence_wiretap"]
				rep.law_lines.append("Wiretap: names, dates, routes.")
		var cap := o.capacity()
		o.exposure += o.laundered_tonight / maxf(1.0, cap) * (1.0 if o.laundered_tonight > 0.6 * cap else 0.4)
		if L.audit:
			var gain: float = R["evidence_audit_k"] * o.exposure
			L.evidence += gain
			o.exposure = 0.0
			rep.law_lines.append("Audit of the fronts: +%s evidence." % Py.f(gain, 0))
			rep.runner_lines.append("IRS agents went through the books at the fronts.")
		var found := []
		var bribe_names := o.bribes.keys()
		bribe_names.sort()
		for b in bribe_names:
			var p := 0.5 if L.ia_sweep else 0.03
			if rng.random() < p:
				found.append(b)
		for b in found:
			o.bribes.erase(b)
			L.evidence += R["evidence_bribe"]
			L.support += 2
			rep.lines.append("Corrupt %s official arrested." % b)
		if o.counterintel and L.informants:
			var burned := 0
			for i in L.informants:
				if rng.random() < 0.75:
					burned += 1
			L.informants -= burned
			if burned:
				rep.runner_lines.append("Counter-intel found %d rat(s). Handled." % burned)
				rep.law_lines.append("%d informant(s) went silent." % burned)
		if L.press:
			L.support += 6
			rep.lines.append("Task force parades seized cocaine for the cameras.")
		if rival != null:
			_rival_drift(takings, rep)
		# --- drift
		o.heat = maxf(0.0, o.heat - R["heat_decay"] - (R["lie_low_decay"] if o.lie_low else 0.0))
		o.loyalty = maxf(0.0, o.loyalty - 0.05)
		L.evidence = maxf(0.0, L.evidence - R["evidence_decay"] - (1.5 if o.lawyer else 0.0))
		L.support += (50.0 - L.support) * 0.1 + o.heat * 0.05
		L.support = maxf(0.0, minf(100.0, L.support))
		L.bank_k += maxf(0.0, L.budget_k) * 0.5  # half of unspent money rolls over
		o.heat = minf(100.0, o.heat)
		reports.append(rep)
		history.append(snapshot_numbers())
		phase = "debrief"
		_check_end()
		return rep

	## A rival run's outcome, from the resolver or the live game's AI traffic.
	func _rival_run(r: RunResult, rep: NightReport) -> void:
		var rv := rival
		var L := law
		if r.busted:
			rv.busts += 1
			rv.strength = maxf(0.0, rv.strength - 12.0)
			rv.turf[r.zone] = maxf(0.05, rv.turf[r.zone] - 0.1)
			L.support += 5.0 + (3.0 if L.gang_unit else 0.0)
			L.bank_k += r.seized_value / 1000.0 * rules["seizure_share"]
			rep.lines.append("Police bust a %s plane in the %s." % [rv.name, r.zone])
			if rv.tipped and rrng.random() < 0.3:
				rv.grudge = 3
				rep.runner_lines.append("%s know who sold them out." % rv.name)
		elif r.delivered_value:
			rv.strength = minf(100.0, rv.strength + 5.0)
			rv.turf[r.zone] = minf(0.9, rv.turf[r.zone] + 0.08)
			rv.cash += r.delivered_value
		if r.boat_seized:
			L.support += 2.0
			rv.strength = maxf(0.0, rv.strength - 5.0)

	func _rival_drift(takings: int, rep: NightReport) -> void:
		var rv := rival
		if rv.truce_nights > 0:
			var share := int(maxi(0, takings) * rules["truce_share"])
			org.dirty -= share
			rv.cash += share
			if share:
				rep.runner_lines.append("Truce payment to %s: $%s." % [rv.name, Py.money(share)])
			rv.truce_nights -= 1
		rv.grudge = maxi(0, rv.grudge - 1)
		rv.strength += (50.0 - rv.strength) * 0.05  # new pilots, new buyers: they regroup
		rv.strength = clampf(rv.strength, 0.0, 100.0)
		if rv.strength < 5.0:
			rep.lines.append("%s are finished on the island - for now." % rv.name)

	func snapshot_numbers() -> Dictionary:
		var o := org
		var L := law
		return {"night": night, "dirty": o.dirty, "clean": o.clean, "heat": Py.round_n(o.heat, 1),
			"evidence": Py.round_n(L.evidence, 1), "support": Py.round_n(L.support, 1),
			"runner_progress": Py.round_n(runner_progress(), 3), "law_progress": Py.round_n(law_progress(), 3)}

	func runner_progress() -> float:
		return org.clean / float(rules["retire_target"])

	func law_progress() -> float:
		return law.evidence / float(rules["indict_evidence"])

	func _check_end() -> void:
		var o := org
		var L := law
		var R := rules
		if o.clean >= R["retire_target"]:
			_end("runner", "retired rich")
			return
		if L.evidence >= R["indict_evidence"]:
			_end("law", "boss indicted")
			return
		if o.dirty + o.clean < -10000:
			_end("law", "organisation broke")
			return
		if night >= R["nights"]:
			var rp := runner_progress()
			var lp := law_progress()
			_end("runner" if rp >= lp else "law", "season over: " + ("walked free" if rp >= lp else "convicted at trial"))
			return
		# comeback events (once each)
		var gap := runner_progress() - law_progress()
		if not L.fed_arrived and night >= 3 and gap > R["comeback_gap"]:
			L.fed_arrived = true
			L.bank_k += R["fed_bonus_k"]
			L.support = minf(100.0, L.support + 10)
			reports.back().lines.append("Washington sends a federal task force to the island.")
		if not cartel_bonus and night >= 3 and -gap > R["comeback_gap"]:
			cartel_bonus = true
			reports.back().lines.append("The cartel raises its price for pilots who'll still fly.")

	func _end(who: String, why: String) -> void:
		phase = "over"
		winner = who
		reason = why

	func next_night() -> void:
		if phase == "over":
			return
		night += 1
		_begin_planning()

	# ============================================================ views
	## What one HQ is allowed to see.
	func view(side: String) -> Dictionary:
		var o := org
		var L := law
		var news: Array = reports.back().lines if not reports.is_empty() else []
		var base := {"night": night, "nights": int(rules["nights"]), "phase": phase, "winner": winner,
			"reason": reason, "news": news.duplicate(),
			"public": {"heat": Py.round_int(o.heat), "support": Py.round_int(L.support)}}
		if on("weather"):
			base["forecast"] = forecast.duplicate()
			base["weather"] = weather.duplicate()
		if on("pattern"):
			base["pattern"] = pattern_exposure()
			base["sightings"] = sightings.slice(-4)
		if side == "runner":
			var rumor = L.evidence if (o.bribes.has("dispatcher") or o.lawyer) else null
			var band: String = ["thin", "building", "serious", "closing in"][mini(3, int(L.evidence / 25))]
			var od := o.to_dict()
			od.erase("exposure")
			var lg: Array = runner_log.slice(-8) + (reports.back().runner_lines if not reports.is_empty() else [])
			base.merge({"org": od, "capacity": o.capacity(), "retire_target": int(rules["retire_target"]),
				"evidence": Py.round_n(rumor, 1) if rumor != null else null, "evidence_rumor": band,
				"patrol_leak": leak_zone() if o.bribes.has("dispatcher") else null, "log": lg})
			if rival != null:
				var rv := rival
				var tf := {}
				for z in ZONES:
					tf[z] = Py.round_n(rv.turf[z], 2)
				base["rival"] = {"name": rv.name, "band": rv.band(), "turf": tf, "truce_nights": rv.truce_nights,
					"grudge": rv.grudge > 0, "zone": rv.zone if phase != "planning" else null}
				if on("rival_tempers"):
					base["rival"]["reputation"] = rv.reputation()
					base["rival"]["nights_left"] = int(rules["nights"]) - night
		else:
			var est = o.clean * rng.uniform(0.7, 1.3) if L.audit or L.wiretap else null
			var lg: Array = law_log.slice(-8) + (reports.back().law_lines if not reports.is_empty() else [])
			base.merge({"law": L.to_dict(), "indict_evidence": rules["indict_evidence"],
				"clean_estimate": int(est) if est else null, "known_fronts": o.fronts.size(),
				"wiretap_ok": L.evidence >= 20, "log": lg, "canary_ok": on("canary")})
			if rival != null:
				base["rival"] = {"name": rival.name, "band": rival.band(), "busts": rival.busts}
		return base


# ================================================================ abstract night
## Per-zone probabilities for the abstract resolver. Defaults are the rates the
## pilot bot flew against the AI task force (189 flights; docs/BALANCE.md).
class Calibration:
	var detect := {"west": 0.222, "north": 0.667, "sea": 0.222}
	var aerostat_detect := {"west": 0.444, "north": 0.0, "sea": 0.778}
	var intercept_per_unit := {"heli": 0.7, "interceptor": 1.0}  ## unit weights
	var intercept_k := 2.025  ## hazard = k * ln(1 + weighted units) * patrol match: extra units add less
	var bust_given_intercept := 0.888
	var crash := {"west": 0.06, "north": 0.01, "sea": 0.01}
	var cutter_seize := 0.35
	var boat_catch_if_spotted := 0.5

	static func from_dict(d: Dictionary) -> Calibration:
		var c := Calibration.new()
		for k in d:
			c.set(k, d[k])
		return c

	func to_dict() -> Dictionary:
		return {"detect": detect, "aerostat_detect": aerostat_detect, "intercept_per_unit": intercept_per_unit,
			"intercept_k": intercept_k, "bust_given_intercept": bust_given_intercept, "crash": crash,
			"cutter_seize": cutter_seize, "boat_catch_if_spotted": boat_catch_if_spotted}


## Roll the night's runs without flying them.
static func resolve_abstract(season: Season, plan: Dictionary, rng: PyRandom, cal: Calibration = null) -> Array:
	if cal == null:
		cal = Calibration.new()
	var o := season.org
	var R := season.rules
	var runs := []
	var kinds := []
	for i in plan["runs"]:
		kinds.append("main")
	for i in plan["crews"]:
		kinds.append("crew")
	for i in plan["decoys"]:
		kinds.append("decoy")
	var rival_runs: int = plan.get("rival_runs", 0)
	var n_tracks := kinds.size() + rival_runs  # the cartel's flights split the police too
	var units: Dictionary = plan["funded"]
	var main_zone: String = plan["route"]
	if plan.get("leak_patrol") != null or plan.get("leak_aerostat"):
		# the man in dispatch called: go where the patrol and the balloon aren't
		var avoid := {plan.get("leak_patrol"): true}
		if plan.get("leak_aerostat"):
			avoid["west"] = true
			avoid["sea"] = true
		if avoid.has(main_zone):
			for z in ["north", "west", "sea"]:
				if not avoid.has(z):
					main_zone = z
					break
	# weather and moon (rules.weather): cloud, rain and a dark moon hide you; storms
	# ground helicopters and the balloon and make every landing a gamble
	var wx: Dictionary = plan.get("weather", {})
	var vis := 1.0
	var crash_k := 1.0
	var heli_k := 1.0
	var sea_k := 1.0
	if not wx.is_empty():
		if Py.truthy(R.get("weather_vis", true)):
			vis = SKIES[wx["sky"]][2] * (0.8 + 0.4 * float(wx["moon"]))
		if Py.truthy(R.get("weather_crash", true)):
			crash_k = SKIES[wx["sky"]][3]
		if wx["sky"] == "storm":
			heli_k = float(R.get("storm_heli", 0.4))
			sea_k = float(R.get("storm_sea", 0.5))
	var pattern: Dictionary = plan.get("pattern", {})
	for kind in kinds:
		var zone: String = main_zone if kind == "main" else rng.choice(ZONES)
		var r := RunResult.new(kind, zone)
		var p_det: float = cal.detect[zone] + (cal.aerostat_detect[zone] if plan["aerostat"] else 0.0)
		if kind == "main" and plan["tip"]:
			p_det += 0.30
		if kind == "main":
			p_det += pattern.get(zone, 0.0)  # the analysts expected you here
		p_det *= vis
		if kind == "decoy":
			p_det += 0.25  # decoys want to be seen
		p_det = minf(0.97, p_det)
		r.detected = rng.random() < p_det
		if r.detected:
			var match_: float = 1.6 if plan["patrol"] == zone else (1.1 if kind == "main" and plan["tip"] else 0.8)
			var weighted: float = (units["heli"] * cal.intercept_per_unit["heli"] * heli_k
				+ units["interceptor"] * cal.intercept_per_unit["interceptor"])
			var haz: float = cal.intercept_k * PyMath.log1p(weighted) * match_
			haz /= 1.0 + 0.6 * maxi(0, n_tracks - 1) / float(maxi(1, units["heli"] + units["interceptor"]))  # spread thin
			if o.gear.has("scanner") and not plan["encryption"]:
				haz *= 0.75
			if o.gear.has("detector"):
				haz *= 0.85
			if plan.get("gang_unit", false):
				haz *= 0.85  # half the squad is chasing Cuervos tonight
			r.intercepted = rng.random() < 1 - exp(-haz)
			if r.intercepted:
				var speed_edge := 0.12 * o.tier if kind == "main" else 0.0
				if rng.random() < cal.bust_given_intercept - speed_edge:
					if kind == "decoy":
						r.clean_stop = true
					else:
						r.busted = true
		if kind != "decoy" and not r.busted:
			r.crashed = rng.random() < cal.crash[zone] * (1.0 if kind == "main" else 0.7) * crash_k
		var value := int(R["run_payout"] * ZONE_PAY[zone] * (o.payout_mult() if kind == "main" else 1.0))
		if r.busted:
			r.seized_value = value * 3  # street value
		elif kind != "decoy" and not r.crashed:
			if zone == "sea" and plan["cutters"]:
				var p: float = cal.cutter_seize * plan["cutters"] * (1.6 if r.detected else 0.7) * sea_k
				if rng.random() < minf(0.9, p):
					r.boat_seized = true
					r.seized_value = value * 3
			if not r.boat_seized:
				r.delivered_value = value
		runs.append(r)
	if season.rival != null and plan.has("rival_zone"):  # hand-built plans (tests) have no cartel
		_resolve_rivals(season, plan, runs, cal)
	return runs


## Rival runs and hijacks, on the rivals' own random stream.
static func _resolve_rivals(season: Season, plan: Dictionary, runs: Array, cal: Calibration) -> void:
	var rr := season.rrng
	var R := season.rules
	for r in runs:
		if r.kind == "main" and r.delivered_value and rr.random() < plan.get("hijack_p", 0.0):
			r.hijacked = true
			r.delivered_value = 0
	var units: Dictionary = plan["funded"]
	var zone: String = plan["rival_zone"]
	var wx: Dictionary = plan.get("weather", {})
	var vis: float = SKIES[wx["sky"]][2] * (0.8 + 0.4 * float(wx["moon"])) if not wx.is_empty() and Py.truthy(R.get("weather_vis", true)) else 1.0
	var crash_k: float = SKIES[wx["sky"]][3] if not wx.is_empty() and Py.truthy(R.get("weather_crash", true)) else 1.0
	for i in plan.get("rival_runs", 0):
		var r := RunResult.new("rival", zone)
		var p_det: float = cal.detect[zone] + (cal.aerostat_detect[zone] if plan["aerostat"] else 0.0)
		if plan.get("rival_tipped", false):
			p_det += 0.5
		r.detected = rr.random() < minf(0.97, p_det * vis)
		if r.detected:
			var match_: float = 1.6 if (plan["patrol"] == zone or plan.get("rival_tipped", false)) else 0.8
			var weighted: float = units["heli"] * cal.intercept_per_unit["heli"] + units["interceptor"] * cal.intercept_per_unit["interceptor"]
			var haz: float = cal.intercept_k * PyMath.log1p(weighted) * match_ * (1.6 if plan.get("gang_unit", false) else 1.0)
			r.intercepted = rr.random() < 1 - exp(-haz)
			r.busted = r.intercepted and rr.random() < cal.bust_given_intercept
		var value := int(R["run_payout"] * ZONE_PAY[zone])
		if r.busted:
			r.seized_value = value * 3
		elif rr.random() < cal.crash[zone] * crash_k:
			r.crashed = true
		elif zone == "sea" and plan["cutters"] and rr.random() < minf(0.9, cal.cutter_seize * plan["cutters"] * 0.7):
			r.boat_seized = true
			r.seized_value = value * 3
		else:
			r.delivered_value = value
		runs.append(r)
