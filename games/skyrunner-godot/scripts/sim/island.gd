class_name Island
extends RefCounted
## Isla Soberana: an island republic over the southern horizon, about 23 km
## off San Telmo, with its own military, its own shortages, and officers who
## sell safe passage through its waters. Fiction inspired by the record (the
## 1989 Ochoa affair: Cuban officers arranged cocaine drops in Cuban waters,
## handed on to speedboats for Florida, until Havana tried and shot them),
## not a portrait of any real state or person.
##
## What it does:
##   - product is cheap there: the island's board sells loads (a job with a
##     price paid up front) that are worth the street price on the mainland
##   - three ways home: fly it (the usual game: radar, interceptors); send it
##     by sea in a freighter's container into the port; or put mules on the
##     airliner into the international airport. Ships and mules are timed
##     shipments, resolved against the odds of customs finding them - odds
##     that the organisation's perks (bought baggage handlers, forged papers,
##     false-bottomed containers, the Family's docks deal) push down and the
##     task force's (sniffer dogs, passenger profiling, container X-ray, a
##     crackdown, the heat from the last catch) push up
##   - its airspace is sovereign: the task force's aircraft break off at the
##     territorial line (TERRITORY_Y), the island's own MiGs may intercept a
##     plane that hasn't bought passage, and the General's price and mood
##     move with the island's politics: a purge (the route closed, the
##     General's friends arrested), a hurricane, a fuel shortage, a boatlift
##     that ties up the Coast Guard, a defector who wants a ride north
##
## Off for the Python replays (Island.ENABLED = false); built for sessions on
## the city coast that ask (live play: island: true).

static var ENABLED := true

const CODE := "SOB"
const NAME := "Isla Soberana"
const C := Vector2(2500.0, -36000.0)  ## the island's centre
const R := Vector2(4800.0, 2600.0)
const PORT := Vector2(4800.0, -34000.0)  ## Puerto Rojo, on the north shore facing the mainland
const TERRITORY_Y := -25000.0  ## south of this line the task force has no writ
const AIRSPACE_R := 11000.0  ## the MiGs' patch around the island
const PRICE_PER_LB := 18.0  ## the island's price for a pound of product
const STREET_PER_LB := 55.0  ## what a pound fetches on the mainland (before the market)
const MULE_KG := 1.0
const MULE_FEE := 1500
const MULE_ETA_S := 900.0
const SHIP_ETA_S := 1500.0
const PASSAGE_S := 2400.0
const RUNNER_NODES := ["baggage_handlers", "forged_papers", "mule_school", "false_bottoms"]
const LAW_NODES := ["sniffer_dogs", "passenger_profiling", "container_xray"]

var sess
var rng: PyRandom
var relations := 50.0  ## 0..100: the General's regard for the organisation
var passage_until := -1.0  ## safe passage bought: the MiGs look the other way
var status := "calm"  ## calm | purge | hurricane | shortage | boatlift
var status_until := -1.0
var price_mult := 1.0
var airport_heat := 0.0  ## 0..100: customs at the international airport, after a catch
var port_heat := 0.0
var crackdown_until := -1.0  ## the task force's passenger profiling at the airport
var inspections_until := -1.0  ## the task force's container inspections at the port
var shipments: Array = []  ## {id, method, lb, n, cost, value, eta, p}
var delivered := 0
var caught := 0
var intercepts := 0
var last := ""
var _serial := 0
var _t := 0.0
var _event_t := 0.0
var _mig_t := 0.0


func _init(sess_, rng_: PyRandom) -> void:
	sess = sess_
	rng = rng_
	sess.bus.subscribe("airport_crackdown", func(_e): airport_heat = minf(100.0, airport_heat + 40.0))
	sess.bus.subscribe("island_purge", func(_e): purge())


## The island's strip (not in the mainland's list: its own board, its own rules).
static func airfield() -> Airfield:
	return Airfield.new(CODE, "Aeropuerto Soberano", C.x - 1200.0, C.y + 700.0, 80.0, 1400.0, 35.0, 4.0, "asphalt", "foreign",
		{"shop": true})


static var _strip: Airfield = null


## The island's ground: a low coral island, sand at the rim, hills inland, the
## runway's corridor graded flat (a little under the runway, which sits on it).
static func height(x: float, y: float) -> float:
	var d := Vector2((x - C.x) / R.x, (y - C.y) / R.y).length()
	if d >= 1.0:
		return -3.0 * minf(1.0, (d - 1.0) * 8.0) - 0.5
	var rim := smoothstep(1.0, 0.9, d)
	# a spine of hills along the island, the Sierra: highest in the east
	var ridge := smoothstep(0.55, 0.0, absf((y - C.y) / R.y + 0.1 * sin((x - C.x) * 0.0009)))
	var hills := smoothstep(0.85, 0.3, d) * (10.0 + 55.0 * ridge * smoothstep(-0.2, 0.6, (x - C.x) / R.x)) * (0.75 + 0.25 * sin(x * 0.0021) * cos(y * 0.0027))
	var z := (1.0 + 2.5 * smoothstep(0.93, 0.8, d)) * rim + maxf(0.0, hills)
	if _strip == null:
		_strip = airfield()
	var l: Array = _strip.to_local(x, y)
	var out := Vector2(maxf(0.0, absf(l[0]) - _strip.length / 2 - 300.0), maxf(0.0, absf(l[1]) - 120.0)).length()
	return lerpf(3.6, z, smoothstep(0.0, 250.0, out)) if z > 3.6 else z


static func in_airspace(x: float, y: float) -> bool:
	return Vector2(x, y).distance_to(C) < AIRSPACE_R


func open() -> bool:
	return status != "purge"


func runner_has(id: String) -> bool:
	return sess.upgrades["runner"].has(id)


func law_has(id: String) -> bool:
	return sess.upgrades["law"].has(id)


# ------------------------------------------------------------------ the odds
## A mule's chance of being caught at the international airport, and why.
func mule_odds() -> Array:
	var p := 0.10 * (1.0 + airport_heat / 100.0)
	var why := ["base 10%"]
	if airport_heat > 0.0:
		why.append("heat x%.2f" % (1.0 + airport_heat / 100.0))
	for f in [["sniffer_dogs", 1.6, "dogs"], ["passenger_profiling", 1.4, "profiling"]]:
		if law_has(f[0]):
			p *= f[1]
			why.append("%s x%.1f" % [f[2], f[1]])
	if crackdown_until > sess.time:
		p *= 1.8
		why.append("crackdown x1.8")
	for f in [["baggage_handlers", 2.2, "our baggage handlers"], ["forged_papers", 1.3, "forged papers"], ["mule_school", 1.25, "trained mules"]]:
		if runner_has(f[0]):
			p /= f[1]
			why.append("%s /%.2f" % [f[2], f[1]])
	return [clampf(p, 0.02, 0.9), why]


## A container's chance of being found at the port, and why.
func ship_odds() -> Array:
	var p := 0.08 * (1.0 + port_heat / 100.0)
	var why := ["base 8%"]
	if port_heat > 0.0:
		why.append("heat x%.2f" % (1.0 + port_heat / 100.0))
	if law_has("container_xray"):
		p *= 1.7
		why.append("X-ray x1.7")
	if inspections_until > sess.time:
		p *= 1.5
		why.append("inspections x1.5")
	if law_has("sniffer_dogs"):
		p *= 1.15
		why.append("dogs x1.15")
	if runner_has("false_bottoms"):
		p /= 2.0
		why.append("false bottoms /2")
	var fam = sess.family
	if fam != null and fam.docks_until > sess.time:
		var k := 0.5 if fam.docks_honest else 2.0
		p *= k
		why.append("the union x%.1f" % k)
	if status == "boatlift":
		p *= 0.7
		why.append("the boatlift x0.7")
	return [clampf(p, 0.02, 0.9), why]


# ------------------------------------------------------------------ shipments
## Buy product on the island and send it home by `method` ("mules" | "ship").
## `n` mules or `lb` pounds in a container. Returns "" or why not.
func ship(method: String, amount: int) -> String:
	if not open():
		return "The island is closed: a purge. Nobody will touch our product."
	if method == "mules":
		var n := clampi(amount, 1, 8)
		var lb := n * MULE_KG * 2.2046
		var cost := int(lb * PRICE_PER_LB * price_mult) + n * MULE_FEE
		if sess.money < cost:
			return "Need $%s." % Py.money(cost)
		sess.money -= cost
		_serial += 1
		shipments.append({"id": "M%d" % _serial, "method": "mules", "n": n, "lb": lb, "cost": cost,
			"value": int(lb * STREET_PER_LB * 3.0), "eta": sess.time + MULE_ETA_S, "p": mule_odds()[0]})
		last = "%d mules on the airliner to San Telmo Intl ($%s)" % [n, Py.money(cost)]
		sess.say("THE ISLAND - " + last)
		return ""
	if method == "ship":
		var lb := clampi(amount, 100, 1200)
		var cost := int(lb * PRICE_PER_LB * price_mult) + 3000
		if sess.money < cost:
			return "Need $%s." % Py.money(cost)
		sess.money -= cost
		_serial += 1
		shipments.append({"id": "S%d" % _serial, "method": "ship", "n": 1, "lb": float(lb), "cost": cost,
			"value": int(lb * STREET_PER_LB), "eta": sess.time + SHIP_ETA_S, "p": ship_odds()[0]})
		last = "%d lb in a container of frozen shrimp, on the freighter to San Telmo ($%s)" % [lb, Py.money(cost)]
		sess.say("THE ISLAND - " + last)
		return ""
	return "Mules or a ship?"


func _resolve(sh: Dictionary) -> void:
	var c = sess.police.case("runner")
	if sh.method == "mules":
		# the odds when they land, not when they left (a crackdown in between counts)
		var p: float = mule_odds()[0]
		var got := 0
		var lost := 0
		for i in int(sh.n):
			if rng.random() < p:
				lost += 1
			else:
				got += 1
		var pay := int(sh.value * got / maxf(1.0, float(sh.n)))
		sess.money += pay
		if lost > 0:
			caught += lost
			airport_heat = minf(100.0, airport_heat + 12.0 * lost)
			sess.law_funds += 800.0 * lost
			sess.econ.record_seizure("cocaine", "sea")
			sess.law_say("Customs at San Telmo Intl: %d swallowers caught off the island flight" % lost)
			# a mule who talks
			if rng.random() < 0.35 * lost and not runner_has("forged_papers"):
				c.suspicion = minf(100.0, c.suspicion + 10.0)
				sess.law_say("One of the mules talks: she was paid by a nightclub downtown")
		if got > 0:
			delivered += got
			sess.econ.record_delivery("cocaine", "sea")
		last = "Mules: %d through, %d caught (+$%s)" % [got, lost, Py.money(pay)]
	else:
		var p: float = ship_odds()[0]
		if rng.random() < p:
			caught += 1
			port_heat = minf(100.0, port_heat + 30.0)
			sess.law_funds += 5000.0
			c.suspicion = minf(100.0, c.suspicion + 12.0)
			sess.econ.record_seizure("cocaine", "sea")
			sess.law_say("Port of San Telmo: %d lb found under frozen shrimp in a container from Isla Soberana" % int(sh.lb))
			last = "The container was opened at the port: %d lb gone" % int(sh.lb)
		else:
			delivered += 1
			sess.money += int(sh.value)
			sess.econ.record_delivery("cocaine", "sea")
			last = "The container cleared customs: +$%s" % Py.money(int(sh.value))
	sess.say("THE ISLAND - " + last)
	sess.bus.emit("island_shipment", sess.time, last, ["runner"], {"method": sh.method})


# ------------------------------------------------------------------ the General
## Buy safe passage through the island's airspace and waters.
func buy_passage() -> String:
	if not open():
		return "The General's friends are under arrest. Nobody is selling passage."
	var cost := passage_cost()
	if sess.money < cost:
		return "Need $%s." % Py.money(cost)
	sess.money -= cost
	passage_until = sess.time + PASSAGE_S
	relations = minf(100.0, relations + 8.0)
	last = "Safe passage bought from the General's aide: the MiGs look the other way for %d min" % int(PASSAGE_S / 60)
	sess.say("THE ISLAND - " + last)
	return ""


func passage_cost() -> int:
	return int((6000.0 - 30.0 * relations) / 500.0) * 500


func has_passage() -> bool:
	return passage_until > sess.time


## Landing at the island: the General's men meet the aircraft.
func on_arrive() -> void:
	if not open():
		# the purge: whoever lands is part of the plot
		var k := mini(maxi(0, sess.money), 8000)
		sess.money -= k
		relations = maxf(0.0, relations - 10.0)
		sess.say("THE ISLAND - Soldiers on the ramp: the purge. They 'confiscate' $%s and the cargo, and let you go." % Py.money(k))
		for j in sess.active_jobs.duplicate():
			if j.hot():
				sess.active_jobs.erase(j)
				sess.loadout.remove_job(j.id)
		return
	relations = minf(100.0, relations + 1.0)


## A task-force aircraft following us: at the line, it breaks off.
func sovereign(y: float) -> bool:
	return y < TERRITORY_Y


# ------------------------------------------------------------------ the board
## The island's board: loads for sale at the island's price, and other work.
func board(af: Airfield) -> Array:
	var jobs := []
	if not open() or status == "hurricane":
		return jobs
	var dests: Array = sess.world.airfields.filter(func(a): return a.kind in ["shady", "bush"])
	for k in 4:
		var dest: Airfield = dests[rng.randint(0, dests.size() - 1)]
		var jid := Jobs.new_id()
		var n := rng.randint(3, 8)
		var items := []
		for i in n:
			items.append(Jobs.item("'Sugar' sack", "cargo", rng.uniform(20, 32), jid, {"hot": true}))
		var lb := Py.sum_by(items, func(i): return i.weight_lb)
		var cost := int(lb * PRICE_PER_LB * price_mult)
		var j := Jobs.Job.new(jid, "Island product: %d sacks -> %s" % [n, dest.name], "contraband", af.code, dest.code, items,
			int(lb * STREET_PER_LB), {"notes": "Costs $%s here, paid up front; worth the street price on the mainland." % Py.money(cost)})
		j.cost = cost
		jobs.append(j)
	if rng.random() < 0.35:
		# a defector wants a ride north: pays well, and the General won't like it
		var dest: Airfield = sess.world.airfields.filter(func(a): return a.kind in ["hub", "regional"])[0]
		var jid := Jobs.new_id()
		var j := Jobs.Job.new(jid, "A defector: an army doctor and her son -> %s" % dest.name, "fugitive", af.code, dest.code,
			[Jobs.item("Passenger", "passenger", 150, jid), Jobs.item("Passenger", "passenger", 90, jid)], 9000,
			{"notes": "They'll pay anything. If the General finds out, the island's doors close for a while."})
		j.defector = true
		jobs.append(j)
	return jobs


func defected(job) -> void:
	relations = maxf(0.0, relations - 20.0)
	last = "The General knows who flew the defectors out"
	sess.say("THE ISLAND - " + last)


# ------------------------------------------------------------------ the island's politics
func purge() -> void:
	status = "purge"
	status_until = sess.time + 1800.0
	relations = maxf(0.0, relations - 30.0)
	passage_until = -1.0
	last = "A purge on the island: the General's friends arrested for 'trafficking'. The route is closed."
	sess.say("NEWS - " + last)
	sess.law_say("NEWS - Isla Soberana arrests its own officers for drug running: the island route is closed for now")
	sess.bus.emit("island_status", sess.time, last, ["runner", "law"], {"status": status})


func _event() -> void:
	if status != "calm":
		return
	var r := rng.random()
	var text := ""
	if r < 0.2:
		status = "hurricane"
		status_until = sess.time + 1200.0
		text = "A hurricane over Isla Soberana: the strip is closed, the freighters stay in port"
	elif r < 0.4:
		status = "shortage"
		status_until = sess.time + 1800.0
		price_mult = 1.4
		text = "Fuel and food shortages on the island: prices up, the General's men hungrier"
	elif r < 0.55:
		status = "boatlift"
		status_until = sess.time + 1800.0
		text = "The island lets anyone who wants to leave go: boats everywhere, the Coast Guard swamped"
	elif r < 0.65 and relations < 40.0:
		purge()
		return
	elif r < 0.85:
		price_mult = 0.75
		status_until = sess.time + 1200.0
		status = "glut"
		text = "A glut on the island: a Colombian shipment came in heavy, prices down"
	else:
		relations = minf(100.0, relations + 10.0)
		text = "The General's birthday: the organisation's gift is noticed"
	last = text
	sess.say("NEWS - " + text)
	sess.law_say("NEWS - " + text)
	sess.bus.emit("island_status", sess.time, text, ["runner", "law"], {"status": status})


## The island's MiGs, when a plane with no passage flies into its airspace.
func _patrol(step: float) -> void:
	if not sess.runner_active() or sess.state == null or sess.parked:
		return
	var s = sess.state
	if not in_airspace(s.x, s.y) or has_passage() or s.alt < 1.0:
		_mig_t = 0.0
		return
	_mig_t += step
	var p := 0.04 * step / 10.0 * (1.5 if status == "purge" else 1.0) * (1.0 - relations / 200.0)
	if _mig_t > 60.0 and rng.random() < p:
		_mig_t = 0.0
		intercepts += 1
		var fine := mini(maxi(0, sess.money), 3000 + int(relations < 30.0) * 5000)
		sess.money -= fine
		relations = maxf(0.0, relations - 5.0)
		last = "A MiG-21 on the wing, rocking: the island's air force. A 'landing fee' of $%s wired to an account on the island" % Py.money(fine)
		sess.say("THE ISLAND - " + last)
		sess.bus.emit("island_intercept", sess.time, last, ["runner"], {})


func update(dt: float) -> void:
	_t += dt
	if _t < 10.0:
		return
	var step := _t
	_t = 0.0
	var now: float = sess.time
	for sh in shipments.duplicate():
		if status == "hurricane" and sh.method == "ship":
			sh.eta = float(sh.eta) + step  # the freighters stay in port
		elif now >= float(sh.eta):
			shipments.erase(sh)
			_resolve(sh)
	airport_heat = maxf(0.0, airport_heat - 0.5 * step / 60.0)
	port_heat = maxf(0.0, port_heat - 0.3 * step / 60.0)
	if status != "calm" and now >= status_until:
		if status == "purge":
			relations = maxf(relations, 30.0)
			sess.say("NEWS - After the purge, new men in the old jobs on Isla Soberana. They're open for business.")
		status = "calm"
		price_mult = 1.0
	_event_t += step
	if _event_t >= 900.0:
		_event_t = 0.0
		if rng.random() < 0.5:
			_event()
	_patrol(step)


func view(side: String) -> Dictionary:
	var m := mule_odds()
	var sh := ship_odds()
	if side == "law":
		return {"airport_heat": int(airport_heat), "port_heat": int(port_heat), "caught": caught, "status": status,
			"crackdown_s": maxi(0, int(crackdown_until - sess.time)), "inspections_s": maxi(0, int(inspections_until - sess.time)),
			"mule_p": snappedf(m[0], 0.01), "ship_p": snappedf(sh[0], 0.01)}
	return {"relations": int(relations), "status": status, "passage_s": maxi(0, int(passage_until - sess.time)),
		"passage_cost": passage_cost(), "price": snappedf(PRICE_PER_LB * price_mult, 0.1), "mule_p": snappedf(m[0], 0.01),
		"mule_why": m[1], "ship_p": snappedf(sh[0], 0.01), "ship_why": sh[1], "last": last,
		"shipments": shipments.map(func(x): return {"id": x.id, "method": x.method, "lb": int(x.lb), "eta_s": int(float(x.eta) - sess.time)})}
