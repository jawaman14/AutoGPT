class_name Payroll
extends RefCounted
## The people who work for the outfits: the organisation and Los Cuervos hire
## them, pay them every payday, and live with who they are.
##
##   soldiers     crew the ground war's squads: an outfit can only put men on
##                the street that it has on the payroll
##   drivers      take the stash trucks through the checkpoints (a good one
##                talks his way past); no driver on the payroll means a day
##                driver off the street - dearer, and he talks if caught
##   mules        fly the island's airliner run (trained ones sweat less);
##                short of mules, street mules at a premium
##   lookouts     posted at a stash house, they see a raid coming and the
##                product is gone before the door comes in
##   accountants  clean the books (the task force's case cools while the cash
##                piles up) - or skim them
##   pilots       contract pilots fly runs of their own: money in, or a bust
##
## A labour market of candidates (their skill shows; their loyalty only as a
## hint - who vouches for them); a payday every PAY_S where wages come out of
## the outfit's cash; loyalty that grows with pay and bonuses and collapses
## when the money doesn't come. The disloyal skim, walk, or call the task
## force. Workers lost in the ground war, at checkpoints, at customs or on a
## contract run are dead or arrested; the arrested get their own cases (a
## lawyer paid by the outfit keeps them quiet; the prosecutor can offer a
## deal), and one who flips gives up what he knows: the organisation's stash
## houses, or Los Cuervos' money and streets.
##
## When no human sits the boss's or the lieutenant's chair the organisation's
## AI runs its payroll; Los Cuervos' always does (with the cartel's cash).
##
## Off for the Python replays (Payroll.ENABLED = false); built for sessions
## that ask (live play: payroll: true).

static var ENABLED := true

const PAY_S := 600.0
const THINK_S := 60.0
const CANDIDATES := 6
const REFRESH_S := 600.0
const JAIL_S := 900.0
## role -> [wage per payday, what he knows (a flip's damage), label]
const ROLES := {
	"soldier": [80, 0.5, "soldier"],
	"driver": [100, 0.8, "driver"],
	"mule": [60, 0.3, "mule"],
	"lookout": [50, 0.6, "lookout"],
	"accountant": [250, 1.5, "accountant"],
	"pilot": [300, 1.2, "contract pilot"],
	"dealer": [70, 0.7, "street dealer"],  ## (Trade) sells the product corner by corner
}
const FIRST := ["Manny", "Tito", "Rafa", "Chucho", "Nestor", "Lalo", "Pepe", "Beto", "Ray", "Eddie", "Danny", "Luis", "Rosa",
	"Marisol", "Yolanda", "Carmen", "Joey", "Frankie", "Hector", "Oscar", "Ernesto", "Willie", "Tony", "Gil"]
const LAST := ["Delgado", "Varela", "Soto", "Pineda", "Ocampo", "Rivas", "Quintero", "Salas", "Mejia", "Fuentes", "Ibanez",
	"Cortes", "Navarro", "Duarte", "Olmos", "Ferrer", "Kowalski", "Brennan", "Russo", "Caruso"]
const GOOD_HINTS := ["a cousin of ours vouches for them", "did two years and never said a word", "came up from the old neighbourhood",
	"worked the Bahamas route in '81, clean", "the boss's godchild"]
const BAD_HINTS := ["nobody knows them", "was in a county lockup last month", "asked a lot of questions about the money",
	"their last crew all got busted", "drives a new car on no money"]

var sess
var rng: PyRandom
var workers: Array = []  ## {id, name, outfit, role, skill, loyalty, wage, status, assigned, heat, hired_at, street}
var candidates := {"org": [], "rival": []}
var jail: Array = []  ## {worker id, outfit, trial_at, lawyer, deal}
var ai := {"org": true, "rival": true}
var unpaid := {"org": 0, "rival": 0}  ## wages owed after the last payday
var paid_total := {"org": 0, "rival": 0}
var flips := {"org": 0, "rival": 0}
var lost := {"org": 0, "rival": 0}
var last := {"org": "", "rival": ""}
var squads := {}  ## squad id -> [worker ids]
var _serial := 0
var _pay_t := 0.0
var _think_t := 0.0
var _refresh_t := 0.0
var _run_t := {}  ## pilot id -> next run time
var _t := 0.0


func _init(sess_, rng_: PyRandom) -> void:
	sess = sess_
	rng = rng_
	for o in ["org", "rival"]:
		_refresh(o)


func has_outfit(o: String) -> bool:
	return o == "org" or (o == "rival" and sess.ground != null)


func cash(o: String) -> float:
	return float(sess.money) if o == "org" else float(sess.ground.commanders.rival.cash)


func spend(o: String, k: float) -> void:
	if o == "org":
		sess.money -= int(k)
	else:
		sess.ground.commanders.rival.cash -= k


func earn(o: String, k: float) -> void:
	spend(o, -k)


func say(o: String, text: String) -> void:
	last[o] = text
	if o == "org":
		sess.say("CREW - " + text)


# ------------------------------------------------------------------ the labour market
func _person(o: String, role: String, street := false) -> Dictionary:
	_serial += 1
	var skill := clampf(rng.uniform(0.15, 0.95) - (0.2 if street else 0.0), 0.05, 1.0)
	var loyal := clampf(rng.uniform(0.2, 0.95) - (0.3 if street else 0.0), 0.05, 1.0)
	var wage: int = int(ROLES[role][0] * (0.7 + 0.6 * skill) * (1.5 if street else 1.0))
	var hint_good := rng.random() < (0.8 if loyal >= 0.5 else 0.2)  # a hint, not a guarantee
	return {"id": "W%d" % _serial, "name": "%s %s" % [FIRST[rng.randint(0, FIRST.size() - 1)], LAST[rng.randint(0, LAST.size() - 1)]],
		"outfit": o, "role": role, "skill": snappedf(skill, 0.01), "loyalty": snappedf(loyal, 0.01), "wage": wage,
		"hint": (GOOD_HINTS if hint_good else BAD_HINTS)[rng.randint(0, 4)], "status": "candidate", "assigned": "",
		"heat": 0.0, "hired_at": -1.0, "street": street}


func _refresh(o: String) -> void:
	var roles := ROLES.keys().filter(func(r): return (r != "dealer" or sess.trade != null) and sess.unlocked("role_" + r))
	var c := []
	for i in CANDIDATES:
		c.append(_person(o, roles[rng.randint(0, roles.size() - 1)]))
	candidates[o] = c


func hire(o: String, id: String) -> String:
	if not has_outfit(o):
		return "No such outfit here."
	var w = Py.first(candidates[o], func(x): return x.id == id)
	if w == null:
		return "No such candidate."
	var fee: int = int(w.wage) * 2
	if cash(o) < fee:
		return "Need $%s to take %s on." % [Py.money(fee), w.name]
	spend(o, fee)
	candidates[o].erase(w)
	w.status = "free"
	w.hired_at = sess.time
	workers.append(w)
	say(o, "Hired %s, %s (%s)." % [w.name, ROLES[w.role][2], w.hint])
	return ""


func fire(o: String, id: String) -> String:
	var w = get_worker(id)
	if w == null or w.outfit != o or not w.status in ["free"]:
		return "Can't let them go now."
	w.status = "gone"
	workers.erase(w)
	say(o, "Let %s go." % w.name)
	# a man let go knows things: a grudge is a risk
	if float(w.loyalty) < 0.4 and rng.random() < 0.3:  # a grudge talks
		_tip(o, w, "a fired %s with a grudge" % ROLES[w.role][2])
	return ""


func get_worker(id: String):
	return Py.first(workers, func(w): return w.id == id)


func of(o: String, role := "", status := "") -> Array:
	return workers.filter(func(w): return w.outfit == o and (role == "" or w.role == role) and (status == "" or w.status == status))


func wage_bill(o: String) -> int:
	var t := 0
	for w in workers:
		if w.outfit == o and w.status in ["free", "assigned"]:
			t += int(w.wage)
	return t


func loyalty(o: String) -> float:
	var ws := workers.filter(func(w): return w.outfit == o and w.status in ["free", "assigned"])
	if ws.is_empty():
		return 0.0
	return Py.sum_by(ws, func(w): return float(w.loyalty)) / ws.size()


## A bonus to everyone: a wage each, +0.1 loyalty.
func bonus(o: String) -> String:
	var bill := wage_bill(o)
	if bill <= 0:
		return "Nobody to pay."
	if cash(o) < bill:
		return "Need $%s." % Py.money(bill)
	spend(o, bill)
	for w in of(o):
		if w.status in ["free", "assigned"]:
			w.loyalty = minf(1.0, float(w.loyalty) + 0.1)
	say(o, "A bonus all round ($%s): the crew is happy." % Py.money(bill))
	return ""


# ------------------------------------------------------------------ taking people for jobs
## Take `n` free workers of `role` for a job; short of hands, street hires fill in
## (dearer, less loyal) when `street` allows. Returns the ids (empty: couldn't).
func take(o: String, role: String, n: int, job: String, street := true) -> Array:
	var free := of(o, role, "free")
	free.sort_custom(func(a, b): return a.skill > b.skill)
	var got := []
	for w in free.slice(0, n):
		w.status = "assigned"
		w.assigned = job
		got.append(w.id)
	while got.size() < n and street:
		var s := _person(o, role, true)
		var fee: int = int(s.wage) * 3
		if cash(o) < fee:
			break
		spend(o, fee)
		s.status = "assigned"
		s.assigned = job
		s.hired_at = sess.time
		workers.append(s)
		got.append(s.id)
	if got.size() < n:
		release(got)
		return []
	return got


func release(ids: Array) -> void:
	for id in ids:
		var w = get_worker(id)
		if w == null:
			continue
		if w.street:
			w.status = "gone"  # a day's work, paid, gone
			workers.erase(w)
		else:
			w.status = "free"
			w.assigned = ""


func mean_skill(ids: Array) -> float:
	var ws := ids.map(func(id): return get_worker(id)).filter(func(w): return w != null)
	return 0.0 if ws.is_empty() else Py.sum_by(ws, func(w): return float(w.skill)) / ws.size()


## A worker is lost on the job: arrested (a case) or killed.
func lose(id: String, how: String) -> void:
	var w = get_worker(id)
	if w == null:
		return
	lost[w.outfit] += 1
	if how == "arrested":
		w.status = "arrested"
		jail.append({"id": id, "outfit": w.outfit, "trial_at": sess.time + JAIL_S, "lawyer": false, "deal": false})
		say(w.outfit, "%s (%s) was arrested." % [w.name, ROLES[w.role][2]])
		sess.law_say("In custody: %s, a %s for %s" % [w.name, ROLES[w.role][2], "the organisation" if w.outfit == "org" else "Los Cuervos"])
		sess.bus.emit("worker_arrested", sess.time, w.name, ["law"], {"outfit": w.outfit, "role": w.role})
	else:
		w.status = "dead"
		workers.erase(w)
		say(w.outfit, "%s (%s) was killed." % [w.name, ROLES[w.role][2]])


# ------------------------------------------------------------------ hooks from the other systems
## The ground war raises a squad of `men` for outfit `o`: the soldiers must be on the payroll.
func enlist(o: String, men: int, squad_id: String) -> String:
	var got := take(o, "soldier", men, squad_id, false)
	if got.is_empty():
		return "Not enough soldiers on the payroll (%d free, %d needed)." % [of(o, "soldier", "free").size(), men]
	squads[squad_id] = got
	return ""


## Each tick: squads that lost men lost workers; squads that are gone hand their men back.
func _reconcile_squads() -> void:
	var g = sess.ground
	if g == null:
		return
	for sid in squads.keys():
		var ids: Array = squads[sid]
		var q = g.get_squad(sid)
		var men: int = int(q.men) if q != null and q.state != "gone" else -1
		if men >= 0:
			while ids.size() > men:
				var id: String = ids.pop_back()
				lose(id, "arrested" if rng.random() < 0.4 else "dead")
			continue
		# disbanded or wiped out: the survivors (as last counted) come home
		release(ids)
		squads.erase(sid)


## A stash truck needs a driver. Returns [driver id, waved through by his talk].
func driver_for(job_id: String) -> Array:
	var d := take("org", "driver", 1, "truck-%s" % job_id)
	if d.is_empty():
		return ["", false]
	var w = get_worker(d[0])
	return [d[0], rng.random() < float(w.skill) * 0.4]


## The island's mules: `n` of them for a run. Returns their ids (empty: couldn't).
func mules_for(o: String, n: int, run_id: String) -> Array:
	return take(o, "mule", n, run_id)


## A lookout at stash `id` sees a raid coming?
func lookout_warns(stash_id: String) -> bool:
	var l = Py.first(workers, func(w): return w.outfit == "org" and w.role == "lookout" and w.assigned == "stash-" + stash_id)
	if l == null:
		return false
	if float(l.loyalty) < 0.3:
		return false  # he was paid to look the other way
	return rng.random() < 0.35 + 0.45 * float(l.skill)


func post_lookout(id: String, stash_id: String) -> String:
	var w = get_worker(id)
	if w == null or w.outfit != "org" or w.role != "lookout" or w.status != "free":
		return "No free lookout by that name."
	if sess.stash_net == null or sess.stash_net.get_stash(stash_id) == null:
		return "No such stash house."
	w.status = "assigned"
	w.assigned = "stash-" + stash_id
	say("org", "%s is watching %s." % [w.name, sess.stash_net.get_stash(stash_id).name])
	return ""


# ------------------------------------------------------------------ payday and loyalty
func _payday() -> void:
	for o in ["org", "rival"]:
		if not has_outfit(o):
			continue
		var ws := workers.filter(func(w): return w.outfit == o and w.status in ["free", "assigned"])
		ws.sort_custom(func(a, b): return a.loyalty > b.loyalty)  # the loyal get paid first
		var short := 0
		for w in ws:
			if cash(o) >= int(w.wage):
				spend(o, int(w.wage))
				paid_total[o] += int(w.wage)
				w.loyalty = minf(1.0, float(w.loyalty) + 0.02)
			else:
				short += int(w.wage)
				w.loyalty = maxf(0.0, float(w.loyalty) - 0.25)
		unpaid[o] = short
		if short > 0:
			say(o, "Payday came up $%s short: the crew is angry." % Py.money(short))
		_accountant(o)
		for w in ws:
			if w.status in ["free", "assigned"] and float(w.loyalty) < 0.35 and rng.random() < 0.15:
				_disloyal(o, w)


func _accountant(o: String) -> void:
	for a in of(o, "accountant"):
		if not a.status in ["free", "assigned"]:
			continue
		if float(a.loyalty) < 0.4 and rng.random() < 0.3:
			var k := int(maxf(0.0, cash(o)) * 0.05)
			spend(o, k)
			say(o, "The books are $%s light. %s says it's a rounding error." % [Py.money(k), a.name])
		elif o == "org":
			var c = sess.police.case("runner")
			c.suspicion = maxf(0.0, c.suspicion - 4.0 * float(a.skill))  # clean books


func _disloyal(o: String, w: Dictionary) -> void:
	var r := rng.random()
	if r < 0.4:
		var k := mini(int(maxf(0.0, cash(o))), rng.randint(5, 20) * 100)
		spend(o, k)
		say(o, "%s dipped into the cash: $%s gone." % [w.name, Py.money(k)])
	elif r < 0.75:
		w.status = "gone"
		workers.erase(w)
		say(o, "%s walked off the job." % w.name)
	else:
		_tip(o, w, "an unhappy %s" % ROLES[w.role][2])


## Someone who works for outfit `o` talks to the task force.
func _tip(o: String, w: Dictionary, who: String) -> void:
	var weight: float = ROLES[w.role][1]
	if o == "org":
		if sess.stash_net != null and not sess.stash_net.live().is_empty():
			var st: Dictionary = sess.stash_net.live()[rng.randint(0, sess.stash_net.live().size() - 1)]
			st.intel += 15.0 * weight
			sess.law_say("A tip from %s in the organisation: %s" % [who, st.name])
		var c = sess.police.case("runner")
		c.suspicion = minf(100.0, c.suspicion + 5.0 * weight)
	else:
		_rival_hit(weight, "a tip from %s in Los Cuervos" % who)


func _rival_hit(weight: float, why: String) -> void:
	var g = sess.ground
	if g == null:
		return
	g.commanders.rival.cash = maxf(0.0, g.commanders.rival.cash - 2500.0 * weight)
	for m in g.control:
		g.control[m]["rival"] *= 1.0 - 0.15 * weight
	sess.law_funds += 1500.0 * weight
	sess.law_say("Los Cuervos hit on %s: cash seized, their corners raided" % why)


# ------------------------------------------------------------------ the jail
## The outfit pays for a jailed worker's lawyer: he's likelier to keep quiet.
func pay_lawyer(o: String, id: String) -> String:
	var j = Py.first(jail, func(x): return x.id == id and x.outfit == o)
	if j == null:
		return "Nobody by that name in jail."
	if j.lawyer:
		return "That one has a lawyer."
	if cash(o) < 2000:
		return "A lawyer costs $2,000."
	spend(o, 2000)
	j.lawyer = true
	var w = get_worker(id)
	if w != null:
		w.loyalty = minf(1.0, float(w.loyalty) + 0.15)
	for x in of(o):
		if x.status in ["free", "assigned"]:
			x.loyalty = minf(1.0, float(x.loyalty) + 0.02)  # the crew sees you look after your own
	say(o, "A lawyer for %s." % (w.name if w != null else id))
	return ""


## The prosecutor offers a jailed worker a deal (the task force's funds).
func offer_deal(id := "") -> String:
	var cands := jail.filter(func(x): return not x.deal and (id == "" or x.id == id))
	if cands.is_empty():
		return "Nobody in custody to deal with."
	if sess.law_funds < 2000.0:
		return "Need $2,000."
	var j = Py.max_by(cands, func(x): return ROLES[get_worker(x.id).role][1] if get_worker(x.id) != null else 0.0)
	sess.law_funds -= 2000.0
	j.deal = true
	var w = get_worker(j.id)
	sess.law_say("A deal offered to %s" % (w.name if w != null else j.id))
	return ""


func flip_chance(j: Dictionary) -> float:
	var w = get_worker(j.id)
	if w == null:
		return 0.0
	return clampf(0.35 * (1.0 - float(w.loyalty)) * (0.5 if j.lawyer else 1.0) * (2.0 if j.deal else 1.0) * (1.5 if w.street else 1.0), 0.0, 0.95)


func _trials() -> void:
	for j in jail.duplicate():
		if sess.time < float(j.trial_at):
			continue
		jail.erase(j)
		var w = get_worker(j.id)
		if w == null:
			continue
		if rng.random() < flip_chance(j):
			flips[w.outfit] += 1
			workers.erase(w)
			_tip(w.outfit, w, "%s, who took a deal" % w.name)
			if w.outfit == "org":
				say("org", "%s took the government's deal." % w.name)
			sess.bus.emit("worker_flipped", sess.time, w.name, ["law"], {"outfit": w.outfit, "role": w.role})
		elif rng.random() < 0.6:
			workers.erase(w)
			say(w.outfit, "%s got %d years." % [w.name, rng.randint(3, 12)])
		else:
			w.status = "free"
			w.assigned = ""
			w.loyalty = minf(1.0, float(w.loyalty) + (0.1 if j.lawyer else 0.0))
			say(w.outfit, "%s is out and back at work." % w.name)


# ------------------------------------------------------------------ contract pilots
func _pilot_runs() -> void:
	for o in ["org", "rival"]:
		if not has_outfit(o):
			continue
		for p in of(o, "pilot", "free"):
			if sess.time < float(_run_t.get(p.id, 0.0)):
				continue
			_run_t[p.id] = sess.time + 1200.0
			var heat := float(sess.police.case("runner").suspicion) / 100.0 if o == "org" else 0.2
			var ok := 0.55 + 0.35 * float(p.skill) - 0.25 * heat
			if rng.random() < ok:
				var pay := int(3000 * (0.8 + 0.4 * float(p.skill)))
				earn(o, pay)
				sess.econ.record_delivery("cocaine", ["west", "north", "sea"][rng.randint(0, 2)])
				say(o, "%s flew a run: +$%s." % [p.name, Py.money(pay)])
			elif rng.random() < 0.85:
				sess.law_funds += 2500.0
				sess.econ.record_seizure("cocaine", "west")
				lose(p.id, "arrested")
			else:
				lose(p.id, "dead")


# ------------------------------------------------------------------ the AI's hiring
## What an outfit wants on its payroll now.
func needs(o: String) -> Dictionary:
	var n := {}
	if sess.ground != null:
		# the organisation keeps the men its squads need and one squad's worth in
		# reserve (balance entry 29: a flat eight paid for an army it didn't field)
		n["soldier"] = mini(8, GroundWar.MEN.foot * (sess.ground.of("org").size() + 1)) if o == "org" else 10
	if o == "org":
		if sess.stash_net != null:
			n["driver"] = 2
			n["lookout"] = mini(3, sess.stash_net.live().size())
		if sess.island != null:
			n["mule"] = 4
		if cash(o) > 40000:
			n["accountant"] = 1
	if cash(o) > 30000:
		n["pilot"] = 1
	if sess.trade != null:
		n["dealer"] = sess.trade.dealers_wanted(o)
	return n


func _think(o: String) -> void:
	if not has_outfit(o):
		return
	var n := needs(o)
	for role in n:
		var have := of(o, role).filter(func(w): return w.status in ["free", "assigned"]).size()
		if have >= int(n[role]):
			continue
		var best = Py.max_by(candidates[o].filter(func(w): return w.role == role),
			func(w): return float(w.skill) + (0.3 if GOOD_HINTS.has(w.hint) else -0.3))
		if best != null and cash(o) > float(best.wage) * 6 + wage_bill(o):
			hire(o, best.id)
	# post lookouts at the hottest stash houses
	if o == "org" and sess.stash_net != null:
		for l in of("org", "lookout", "free"):
			var watched := of("org", "lookout", "assigned").map(func(w): return str(w.assigned))
			var open: Array = sess.stash_net.live().filter(func(s): return not watched.has("stash-" + s.id))
			if open.is_empty():
				break
			post_lookout(l.id, Py.max_by(open, func(s): return StashNet.suspicion(s)).id)
	# look after the jailed who know things (the accountant, the pilots) - not
	# every corner boy the street war puts in a cell (balance entry 29)
	for j in jail.filter(func(x): return x.outfit == o and not x.lawyer):
		var w = get_worker(j.id)
		if w != null and float(ROLES[w.role][1]) >= 1.0 and cash(o) > 8000:
			pay_lawyer(o, j.id)
	# a bonus when the crew is sour and the money's there
	if loyalty(o) < 0.45 and cash(o) > wage_bill(o) * 8:
		bonus(o)
	# lay people off when the money's gone
	if cash(o) < wage_bill(o) and not of(o, "", "free").is_empty():
		var w = Py.min_by(of(o, "", "free"), func(x): return float(x.skill) + float(x.loyalty))
		fire(o, w.id)


func update(dt: float) -> void:
	_t += dt
	if _t < 1.0:
		return
	var step := _t
	_t = 0.0
	_reconcile_squads()
	_pay_t += step
	if _pay_t >= PAY_S:
		_pay_t = 0.0
		_payday()
	_trials()
	_pilot_runs()
	_refresh_t += step
	if _refresh_t >= REFRESH_S:
		_refresh_t = 0.0
		for o in ["org", "rival"]:
			_refresh(o)
	_think_t += step
	if _think_t >= THINK_S:
		_think_t = 0.0
		for o in ["org", "rival"]:
			if ai[o]:
				_think(o)


func view(side: String) -> Dictionary:
	if side == "law":
		return {"jail": jail.map(func(j):
			var w = get_worker(j.id)
			return {"id": j.id, "name": w.name if w != null else "?", "outfit": j.outfit, "role": w.role if w != null else "?",
				"trial_s": maxi(0, int(float(j.trial_at) - sess.time)), "deal": j.deal, "lawyer": j.lawyer}),
			"flips": flips.duplicate(), "lost": lost.duplicate()}
	var counts := {}
	for role in ROLES:
		counts[role] = of("org", role).filter(func(w): return w.status in ["free", "assigned"]).size()
	return {"counts": counts, "wage_bill": wage_bill("org"), "loyalty": snappedf(loyalty("org"), 0.01),
		"payday_s": maxi(0, int(PAY_S - _pay_t)), "unpaid": int(unpaid.org), "last": last.org, "ai": ai.org,
		"candidates": candidates.org.map(func(w): return {"id": w.id, "name": w.name, "role": w.role, "skill": w.skill,
			"wage": w.wage, "hint": w.hint}),
		"crew": of("org").filter(func(w): return w.status in ["free", "assigned"]).map(func(w): return {"id": w.id, "name": w.name,
			"role": w.role, "skill": w.skill, "wage": w.wage, "status": w.status, "assigned": w.assigned}),
		"jail": jail.filter(func(j): return j.outfit == "org").map(func(j):
			var w = get_worker(j.id)
			return {"id": j.id, "name": w.name if w != null else "?", "role": w.role if w != null else "?",
				"trial_s": maxi(0, int(float(j.trial_at) - sess.time)), "lawyer": j.lawyer}),
		"rival": {"crew": of("rival").filter(func(w): return w.status in ["free", "assigned"]).size(), "loyalty": snappedf(loyalty("rival"), 0.01)}}
