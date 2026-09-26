class_name Chronicle
extends RefCounted
## The news, and what happens to the three outfits between the runs: good
## breaks and bad luck for the organisation, Los Cuervos and the task force.
##
## Two kinds of event:
##   random     about one every EVERY_S (a Poisson clock on its own RNG
##              stream), the outfit and the luck drawn at random, the event
##              weighted by what can happen now (no arms deal for a gang with
##              no guns to lose)
##   milestones fire once, when the story reaches them: the first delivery,
##              ten deliveries, the first bust, a burned stash, officers down
##              in a firefight, a big armoury, a fortune made too fast...
##
## Every event does something real (money, the task force's funds, the case's
## suspicion, a stash's heat or police intel, an arsenal, the markets, squads'
## morale and men, Los Cuervos' turf) and makes the news: public stories are
## headlines for both sides, some are only heard by the side they happen to
## (a cop on the payroll, an informant turned). Headlines carry an outlet's
## name, as the island's papers and radio would run them.
##
## Off for the Python replays (Chronicle.ENABLED = false); built for sessions
## that ask (live play: chronicle: true).

static var ENABLED := true

const EVERY_S := 480.0
const OUTLETS := ["San Telmo Herald", "Radio Costa 88", "El Nuevo Dia", "Channel 4 Eyewitness News", "The Coastal Courier",
	"Radio Rebelde (pirate)", "the word on the street"]

## id -> [side, good, public, text]. Texts may use {n}, {cash}, {stash}, {zone}.
const EVENTS := {
	# the organisation
	"windfall": ["org", true, false, "A Miami connection pays an old debt: +${cash}"],
	"surplus_rifles": ["org", true, false, "A crate of army-surplus rifles fell off a truck: +{n} rifles in the armoury"],
	"cop_payroll": ["org", true, false, "A patrolman took the envelope: the case against us cools"],
	"crew_loyal": ["org", true, false, "Paydays on time: the soldiers' nerve is up"],
	"stash_cools": ["org", true, false, "The farmer at {stash} swears he's never seen us: the heat there cools"],
	"snitch": ["org", false, false, "Somebody in the crew is talking: the police are asking about {stash}"],
	"courier_robbed": ["org", false, true, "Courier robbed at gunpoint downtown: -${cash}"],
	"tax_audit": ["org", false, true, "The IRS is auditing the club's books: -${cash}, and questions asked"],
	"bad_ammo": ["org", false, false, "A bad lot of ammunition: a third of it duds"],
	"defection": ["org", false, true, "One of our soldiers walked over to Los Cuervos"],
	# Los Cuervos
	"rival_shipment": ["rival", true, true, "Los Cuervos land a big load: cheap cocaine in the {zone}"],
	"rival_recruits": ["rival", true, true, "Los Cuervos are hiring in the barrio: a new crew on the street"],
	"rival_arms": ["rival", true, true, "Los Cuervos bought heavy weapons across the water"],
	"rival_boss_arrested": ["rival", false, true, "A Los Cuervos lieutenant arrested at the airport: their hold on the {zone} slips"],
	"rival_infighting": ["rival", false, true, "Los Cuervos crews shoot it out over a debt"],
	"rival_plane": ["rival", false, true, "A Los Cuervos plane seized at a farm strip, loaded"],
	# the task force
	"federal_grant": ["law", true, true, "Washington sends money for the drug war: +${cash} for the task force"],
	"informant_turned": ["law", true, false, "An informant came in with a name: {stash}"],
	"guard_rifles": ["law", true, true, "The National Guard lends the task force rifles: +{n}"],
	"public_outcry": ["law", true, true, "Editorial: 'Take back our streets' - the pressure is on the organisation"],
	"corruption_scandal": ["law", false, true, "Scandal: officers on a smuggler's payroll - -${cash} and morale on the floor"],
	"budget_cut": ["law", false, true, "The county cuts the task force's budget: -${cash}"],
	"evidence_theft": ["law", false, true, "Weapons missing from the police evidence room - sold on the street"],
	"lawsuit": ["law", false, true, "A raid on the wrong house: the lawsuit makes the task force careful"],
}

## id -> [side, text]; checked each tick, fire once.
const MILESTONES := {
	"first_delivery": ["org", "A new name on the street: somebody is flying loads in"],
	"ten_deliveries": ["law", "Ten loads through and counting: Washington wants a task force that works (+$5,000)"],
	"rich_50k": ["org", "The boss bought a white Testarossa: flash money gets noticed (heat up)"],
	"rich_150k": ["org", "The club's owner is on the society pages: the organisation is the biggest outfit on the coast"],
	"first_bust": ["law", "First bust makes the front page: the task force gets its budget (+$2,000)"],
	"three_busts": ["law", "Third bust: the pilots are scared, loads cost more to fly"],
	"stash_burned": ["law", "Raid on {stash} on the evening news: every house is watched harder"],
	"armoury_20": ["org", "Word is the organisation has an army: the Feds send an ATF team (+$3,000 for the task force)"],
	"guns_seized_20": ["law", "The task force shows off a table of seized guns to the cameras"],
	"officers_down": ["law", "Three officers shot: the county buys the task force a SWAT truck (+$8,000), and the heat is on"],
	"ten_arrests": ["law", "Gang sweep: ten soldiers in custody; the organisation's crews are nervous"],
	"cuervos_own": ["rival", "Los Cuervos own the {zone}: nobody else's product moves there"],
}

var sess  ## Session
var rng: PyRandom
var fired := {}  ## milestone id -> time
var entries: Array = []  ## [t, side, good, public, text]
var counts := {}  ## event kind -> count (from the session's bus)
var _next := 0.0
var _t := 0.0


func _init(sess_, rng_: PyRandom) -> void:
	sess = sess_
	rng = rng_
	_next = _interval()
	sess.bus.subscribe("*", func(ev): counts[ev.kind] = counts.get(ev.kind, 0) + 1)


func _interval() -> float:
	return -log(maxf(1e-6, 1.0 - rng.random())) * EVERY_S


func update(dt: float) -> void:
	_t += dt
	if _t < 1.0:
		return
	var step := _t
	_t = 0.0
	_milestones()
	_next -= step
	if _next <= 0.0:
		_next = _interval()
		random_event()


# ------------------------------------------------------------------ random events
## Draw one: the outfit, then good or bad, then an event that can happen now.
func random_event() -> String:
	var side: String = ["org", "rival", "law"][rng.randint(0, 2)]
	var good := rng.random() < 0.5
	var pool := []
	for id in EVENTS:
		var e: Array = EVENTS[id]
		if e[0] == side and e[1] == good and _can(id):
			pool.append(id)
	if pool.is_empty():
		return ""
	var id: String = pool[rng.randint(0, pool.size() - 1)]
	fire(id)
	return id


func _live_stash():
	if sess.stash_net == null:
		return null
	var live: Array = sess.stash_net.live()
	return null if live.is_empty() else live[rng.randint(0, live.size() - 1)]


func _hottest_stash():
	if sess.stash_net == null:
		return null
	return Py.max_by(sess.stash_net.live(), func(s): return StashNet.suspicion(s)) if not sess.stash_net.live().is_empty() else null


func _squads(f: String) -> Array:
	return sess.ground.of(f) if sess.ground != null else []


func _can(id: String) -> bool:
	match id:
		"surplus_rifles", "bad_ammo":
			return sess.arsenals.has("org")
		"stash_cools", "snitch", "informant_turned":
			return sess.stash_net != null and not sess.stash_net.live().is_empty()
		"crew_loyal", "defection":
			return not _squads("org").is_empty()
		"rival_recruits", "rival_infighting":
			return sess.ground != null
		"rival_arms", "guard_rifles", "evidence_theft":
			return sess.arsenals.has("law")
	return true


## Apply event `id` and make the news. Returns the headline.
func fire(id: String) -> String:
	var e: Array = EVENTS[id]
	var vars := {"n": 0, "cash": "0", "stash": "a stash house", "zone": ["west", "north", "sea"][rng.randint(0, 2)]}
	var c = sess.police.case("runner")
	match id:
		"windfall":
			var k := rng.randint(20, 50) * 100
			sess.money += k
			vars.cash = Py.money(k)
		"surplus_rifles":
			var k := rng.randint(3, 6)
			sess.arsenals.org.add("rifle", k)
			vars.n = k
		"cop_payroll":
			c.suspicion = maxf(0.0, c.suspicion - 15.0)
		"crew_loyal":
			for q in _squads("org"):
				q.morale = minf(1.0, q.morale + 0.15)
		"stash_cools":
			var st = _hottest_stash()
			st.heat = maxf(0.0, st.heat - 20.0)
			st.intel = maxf(0.0, st.intel - 20.0)
			vars.stash = st.name
		"snitch":
			var st = _hottest_stash()
			st.intel += 25.0
			vars.stash = st.name
		"courier_robbed":
			var k := mini(maxi(0, sess.money), rng.randint(15, 40) * 100)
			sess.money -= k
			vars.cash = Py.money(k)
		"tax_audit":
			var k := mini(maxi(0, sess.money), 2000)
			sess.money -= k
			c.suspicion = minf(100.0, c.suspicion + 10.0)
			vars.cash = Py.money(k)
		"bad_ammo":
			sess.arsenals.org.ammo = int(sess.arsenals.org.ammo * 0.67)
			for q in _squads("org"):
				q.ammo = int(q.ammo * 0.67)
		"defection":
			var q = Py.max_by(_squads("org"), func(q): return q.men)
			q.men = maxi(1, q.men - 1)
		"rival_shipment":
			var z: String = vars.zone
			sess.econ.record_delivery("cocaine", z)
			sess.econ.record_delivery("cocaine", z)
			if sess.ground != null:
				sess.ground.commanders.rival.cash += 8000.0
		"rival_recruits":
			sess.ground.recruit("rival", "foot", null, false)
		"rival_arms":
			sess.arsenals.rival.add("mg", 1)
			sess.arsenals.rival.add("rifle", 4)
		"rival_boss_arrested":
			_rival_turf(vars.zone, -0.08)
			if sess.ground != null:
				sess.ground.commanders.rival.cash = maxf(0.0, sess.ground.commanders.rival.cash - 5000.0)
		"rival_infighting":
			for q in _squads("rival"):
				q.men = maxi(1, q.men - 1)
				q.morale = maxf(0.2, q.morale - 0.2)
		"rival_plane":
			sess.econ.record_seizure("cocaine", vars.zone)
			sess.law_funds += 1500.0
		"federal_grant":
			var k := rng.randint(40, 80) * 100
			sess.law_funds += k
			vars.cash = Py.money(k)
		"informant_turned":
			var st = _live_stash()
			st.intel += 30.0
			vars.stash = st.name
		"guard_rifles":
			var k := rng.randint(4, 8)
			sess.arsenals.law.add("rifle", k)
			vars.n = k
		"public_outcry":
			c.suspicion = minf(100.0, c.suspicion + 10.0)
		"corruption_scandal":
			var k := int(minf(sess.law_funds, 4000.0))
			sess.law_funds -= k
			vars.cash = Py.money(k)
			for q in _squads("police"):
				q.morale = maxf(0.3, q.morale - 0.15)
		"budget_cut":
			var k := int(minf(sess.law_funds, 3000.0))
			sess.law_funds -= k
			vars.cash = Py.money(k)
		"evidence_theft":
			var k: int = sess.arsenals.law.take("rifle", 4)
			sess.arsenals.rival.add("rifle", k)
		"lawsuit":
			c.suspicion = maxf(0.0, c.suspicion - 10.0)
	var text := str(e[3]).format(vars)
	_news(e[0], e[1], e[2], text)
	return text


func _rival_turf(zone: String, d: float) -> void:
	var ss = sess.nights.season if sess.nights != null else null
	if ss != null and ss.rival != null and ss.rival.turf.has(zone):
		ss.rival.turf[zone] = clampf(ss.rival.turf[zone] + d, 0.05, 0.9)
	if sess.ground != null and sess.ground.control.has(zone):
		sess.ground.control[zone]["rival"] *= 0.5 if d < 0 else 1.5


func _news(side: String, good: bool, public: bool, text: String) -> void:
	var outlet: String = OUTLETS[rng.randint(0, OUTLETS.size() - 1)] if public else ""
	var line := ("%s: %s" % [outlet, text]) if public else text
	entries.append([sess.time, side, good, public, line])
	Py.keep_last(entries, 40)
	var runner_hears: bool = public or side == "org"
	var law_hears: bool = public or side == "law"
	if runner_hears:
		sess.say(("NEWS - " if public else "") + line)
	if law_hears:
		sess.law_say(("NEWS - " if public else "") + line)
	sess.bus.emit("news", sess.time, line, (["runner", "law"] if public else (["runner"] if side != "law" else ["law"])),
		{"side": side, "good": good})


# ------------------------------------------------------------------ milestones
func _milestones() -> void:
	var delivered: int = counts.get("job_delivered", 0) + counts.get("bales_delivered", 0)
	var busts: int = sess.police.score.get("busts", 0)
	_check("first_delivery", delivered >= 1)
	_check("ten_deliveries", delivered >= 10)
	_check("rich_50k", sess.money >= 50000)
	_check("rich_150k", sess.money >= 150000)
	_check("first_bust", busts >= 1)
	_check("three_busts", busts >= 3)
	if sess.stash_net != null:
		var burned = Py.first(sess.stash_net.stashes, func(s): return s.burned)
		_check("stash_burned", burned != null, {"stash": burned.name if burned != null else ""})
	if sess.arsenals.has("org"):
		_check("armoury_20", sess.arsenals.org.count() >= 20)
		_check("guns_seized_20", sess.arsenals.law.seized_total >= 20)
	if sess.ground != null:
		_check("officers_down", sess.ground.officers_down >= 3)
		_check("ten_arrests", sess.ground.arrests_total >= 10)
		for z in HQ.ZONES:
			if sess.ground.rival_share(z) > 0.8 and not fired.has("cuervos_own"):
				_check("cuervos_own", true, {"zone": z})


func _check(id: String, cond: bool, vars := {}) -> void:
	if not cond or fired.has(id):
		return
	fired[id] = sess.time
	var m: Array = MILESTONES[id]
	var c = sess.police.case("runner")
	match id:
		"ten_deliveries":
			sess.law_funds += 5000.0
		"rich_50k":
			c.suspicion = minf(100.0, c.suspicion + 10.0)
		"first_bust":
			sess.law_funds += 2000.0
		"stash_burned":
			for st in sess.stash_net.live():
				st.intel += 5.0
		"armoury_20":
			sess.law_funds += 3000.0
		"officers_down":
			sess.law_funds += 8000.0
			c.suspicion = minf(100.0, c.suspicion + 20.0)
		"ten_arrests":
			for q in _squads("org"):
				q.morale = maxf(0.3, q.morale - 0.1)
		"three_busts":
			sess.econ.scarcity["cocaine"] = minf(0.6, sess.econ.scarcity["cocaine"] + 0.15)
	# news that's good for its side (a milestone the other side won't enjoy)
	_news(m[0], true, true, str(m[1]).format(vars))


## What `side` ("runner" | "law") has heard: the headlines, and its own private news.
func view(side: String) -> Dictionary:
	var mine := "law" if side == "law" else "org"
	var heard := entries.filter(func(l): return l[3] or l[1] == mine)
	return {"news": heard.slice(-8).map(func(l): return {"t": snappedf(l[0], 0.1), "side": l[1], "good": l[2], "text": l[4]}),
		"milestones": fired.keys()}
