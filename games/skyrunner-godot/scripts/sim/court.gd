class_name Court
extends RefCounted
## What happens after the handcuffs: the pilot's case in federal court, from
## the bail hearing to the verdict, the sentence and the appeal. Fiction
## modelled on how 1980s federal drug cases in South Florida ran (the charges,
## bail and flight risk, suppression motions, plea deals, cooperation
## agreements, the 1986 mandatory minimums, asset forfeiture; and the
## judges who took bribes, as Operation Court Broom found in Miami in 1991).
## No real person appears.
##
## The stages (game time runs compressed: a case takes about twenty minutes):
##   bail      the hearing: post the whole bail (back at trial if you show),
##             buy a bond (10% to the bondsman, gone), or sit in custody. The
##             prosecutor can ask for no bail when you're a flight risk (rich,
##             or with friends on Isla Soberana), and the judge decides
##   pretrial  out on bail you fly (a new bust while out revokes it); in
##             custody the aircraft sits. Your lawyer - the public defender,
##             a local attorney, a Miami drug lawyer, or the Family's man -
##             can move to suppress an illegal search, get discovery (the
##             evidence, the witnesses, whether there's an informant), ask for
##             a continuance. The Family can lean on a witness; a judge who
##             takes money can be paid; both can go badly wrong. The
##             prosecutor offers pleas, and a deal if you'll name names
##   trial     the jury: guilty, not guilty, or hung (a retrial). Skip it -
##             stay on the island past the date - and you're a fugitive
##   sentence  years (mandatory minimums once the 1986 act is law), a fine,
##             the aircraft and part of the cash forfeited; the years pass as
##             game minutes in custody (fast-forward with court_wait), and one
##             appeal can end them early
##
## The task force's side: ask for no bail, grant a witness immunity, subpoena
## the bank records (a civil forfeiture), add a conspiracy count, offer a plea.
## When no human sits the prosecutor's chair, the AI prosecutor does it.
##
## Off for the Python replays (Court.ENABLED = false); built for sessions that
## ask (live play: court: true). Without it a bust is the old fine and impound.

static var ENABLED := true

const BAIL_DECIDE_S := 90.0
const PRETRIAL_S := 1200.0
const CONTINUANCE_S := 600.0
const RETRIAL_S := 600.0
const PLEA_AT := [300.0, 780.0]
const MIN_PER_YEAR := 2.0  ## game minutes inside per year of the sentence
const MAX_PRISON_MIN := 60.0

## id -> [name, years, weight]
const CHARGES := {
	"possession": ["Possession with intent to distribute", 3, 1],
	"trafficking": ["Importation and trafficking", 8, 2],
	"firearms": ["Firearm in a drug-trafficking crime", 5, 1],
	"conspiracy": ["Conspiracy to import", 12, 3],
	"obstruction": ["Obstruction of justice", 5, 1],
	"bail_jumping": ["Failure to appear", 3, 1],
}
## id -> {name, skill 0..1, cost, blurb}
const LAWYERS := {
	"public": {"name": "the public defender", "skill": 0.15, "cost": 0, "blurb": "forty cases this week and yours is one of them"},
	"local": {"name": "Arturo Vega", "skill": 0.4, "cost": 6000, "blurb": "a storefront practice on Calle Ocho; knows every clerk"},
	"miami": {"name": "Roy Kessler", "skill": 0.65, "cost": 25000, "blurb": "a Brickell Avenue drug lawyer; his clients pay in duffel bags"},
	"family": {"name": "Leonard Castellano", "skill": 0.7, "cost": 0, "blurb": "the Family's lawyer: got an underboss off in '81"},
}
const JUDGES := [
	{"id": "pike", "name": "Judge Harlan Pike", "bias": 0.35, "bail": 1.6, "sentence": 1.3, "bribable": false, "known": "a hanging judge; hates smugglers"},
	{"id": "ruiz", "name": "Judge Elena Ruiz", "bias": 0.0, "bail": 1.0, "sentence": 1.0, "bribable": false, "known": "by the book"},
	{"id": "dunne", "name": "Judge Walter Dunne", "bias": -0.1, "bail": 0.8, "sentence": 0.9, "bribable": true, "known": "lives well for a judge"},
]

var sess
var rng: PyRandom
var case_ = null  ## the open case (a Dictionary), or null
var history: Array = []  ## closed cases: {verdict, years, t}
var mandatory := false  ## the Anti-Drug Abuse Act (1986): mandatory minimums
var prosecutor_ai := true  ## no human in the prosecutor's chair
var _serial := 0


func _init(sess_, rng_: PyRandom) -> void:
	sess = sess_
	rng = rng_


func open() -> bool:
	return case_ != null


func stage() -> String:
	return "" if case_ == null else str(case_.stage)


## The pilot is held (in custody, or inside): no flying.
func holding() -> bool:
	return case_ != null and case_.stage in ["bail", "custody", "prison"]


## The police bring the pilot in. Replaces the old flat fine.
func arrest(how: String) -> void:
	var c = sess.police.case("runner")
	var hot_lb := 0.0
	var weapons := 0
	for j in sess.active_jobs:
		if j.hot():
			hot_lb += Py.sum_by(j.items, func(i): return i.weight_lb)
			sess.econ.record_seizure(Economy.good_of(j), Economy.job_market(j))
		for t in j.weapons:
			weapons += int(j.weapons[t])
		sess._seize_weapons(Arsenal.weapons_of(j), "the aircraft")
	for j in sess.active_jobs.duplicate():
		if j.hot():  # the load is evidence now
			sess.active_jobs.erase(j)
			sess.loadout.remove_job(j.id)
	var armed: bool = weapons > 0 or sess.upgrades["runner"].has("strip_guards")
	# a second arrest: bail revoked, the case reopens, heavier
	if case_ != null and case_.stage in ["pretrial", "fugitive"]:
		case_.evidence = minf(100.0, float(case_.evidence) + 15.0)
		if case_.stage == "fugitive":
			_charge("bail_jumping")
		case_.stage = "custody"
		case_.bail_posted = ""
		case_.trial_at = sess.time + 300.0
		_hot_charges(hot_lb, armed)
		_say("Arrested again while the case is open: bail revoked, back to custody. Trial in 5 min.",
			"The pilot is back in custody - bail revoked (%s)" % how)
		return
	_serial += 1
	var j: Dictionary = JUDGES[rng.randint(0, JUDGES.size() - 1)]
	var informants: bool = sess.upgrades["law"].has("informants")
	var witnesses := (1 if informants else 0) + (1 if sess.upgrades["law"].has("undercover") else 0)
	if sess.ground != null:
		witnesses += mini(2, int(sess.ground.arrests_total) / 3)  # arrested soldiers who might talk
	var ev := 20.0 + minf(35.0, hot_lb * 0.1) + float(c.suspicion) * 0.25 + (10.0 if informants else 0.0) \
		+ (10.0 if sess.upgrades["law"].has("undercover") else 0.0) + 5.0 * witnesses + (12.0 if c.wanted else 0.0)
	case_ = {"id": "US v. Pilot #%d" % _serial, "how": how, "stage": "bail", "t0": sess.time, "charges": [],
		"evidence": clampf(ev, 5.0, 100.0), "witnesses": witnesses, "informant": informants, "discovered": false,
		"no_warrant": how.begins_with("arrested on landing") and float(c.suspicion) < 40.0,
		"judge": j.duplicate(), "bought": false, "lawyer": "public", "lawyer_honest": true,
		"bail": 0, "bail_posted": "", "bail_by": sess.time + BAIL_DECIDE_S, "no_bail": false,
		"trial_at": sess.time + PRETRIAL_S, "continuances": 0, "motions": [], "plea": {}, "plea_n": 0,
		"cooperating": false, "tampered": false, "bribed": false, "immunity": false, "frozen": 0,
		"verdict": "", "years": 0.0, "release_at": -1.0, "appealed": false}
	_hot_charges(hot_lb, armed)
	if case_.charges.is_empty():
		_charge("possession" if hot_lb > 0.0 else "conspiracy")
	if float(c.suspicion) >= 60.0 or float(case_.evidence) >= 70.0:
		_charge("conspiracy")
	# the Family's lawyer, if he was on retainer
	var fam = sess.family
	if fam != null and fam.lawyer != "":
		case_.lawyer = "family"
		case_.lawyer_honest = fam.lawyer == "honest"
		fam.lawyer = ""
	case_.bail = _bail_amount()
	sess.police.score["busts"] += 1
	sess.law_funds += 3000.0  # the aircraft impounded, the cash on board
	sess.police.reset(false)
	_say("Arrested (%s). Charged: %s. Bail hearing before %s (%s): bail set at $%s." % [how, charge_names(), j.name, j.known,
		Py.money(int(case_.bail))], "ARREST: %s (%s). %s. Before %s." % [sess.squawk, how, charge_names(), j.name])
	sess.bus.emit("arrested", sess.time, how, ["runner", "law"], {"case": case_.id})
	if prosecutor_ai:
		_prosecutor_opening()


func _hot_charges(hot_lb: float, armed: bool) -> void:
	if hot_lb > 0.0:
		_charge("possession")
	if hot_lb > 150.0:
		_charge("trafficking")
	if armed:
		_charge("firearms")


func _charge(id: String) -> void:
	if case_ != null and not case_.charges.has(id):
		case_.charges.append(id)


func charge_names() -> String:
	return ", ".join(case_.charges.map(func(c): return CHARGES[c][0])) if case_ != null else ""


func _weight() -> int:
	var w := 0
	for c in case_.charges:
		w += int(CHARGES[c][2])
	return w


func flight_risk() -> bool:
	var isl = sess.island
	return sess.money > 100000 or (isl != null and isl.relations >= 60.0)


func _bail_amount() -> int:
	var b := 10000.0 * _weight() * float(case_.judge.bail) * (1.5 if flight_risk() else 1.0)
	return int(b / 1000.0) * 1000


func lawyer() -> Dictionary:
	return LAWYERS[case_.lawyer]


func _say(runner: String, law: String) -> void:
	if runner != "":
		sess.say("COURT - " + runner)
	if law != "":
		sess.law_say("COURT - " + law)


# ------------------------------------------------------------------ the defence
## The bail hearing: "cash" (all of it, back at trial), "bond" (10%, gone) or "custody".
func post_bail(how: String) -> String:
	if case_ == null or case_.stage != "bail":
		return "No bail hearing now."
	if case_.no_bail and how != "custody":
		return "The judge denied bail: you're held until trial."
	var amt: int = int(case_.bail) if how == "cash" else int(case_.bail * 0.1)
	if how in ["cash", "bond"]:
		if sess.money < amt:
			return "Need $%s." % Py.money(amt)
		sess.money -= amt
		case_.bail_posted = how
		case_.stage = "pretrial"
		_say("Bail posted (%s, $%s). You're out - don't miss the trial in %d min." % [
			"cash" if how == "cash" else "a bondsman's bond", Py.money(amt), int(ceil((case_.trial_at - sess.time) / 60.0))], "The pilot made bail")
		sess.bus.emit("bailed", sess.time, "", ["runner", "law"], {})
		return ""
	if how == "custody":
		case_.stage = "custody"
		_say("You stay in custody until the trial.", "The pilot is held until trial")
		return ""
	return "Cash, a bond, or custody?"


## Retain a lawyer ("local" or "miami"; the Family's comes by the Family).
func hire(tier: String) -> String:
	if case_ == null or case_.stage in ["prison"]:
		return "No case to defend."
	if not LAWYERS.has(tier) or tier == "family" or tier == "public":
		return "Hire whom?"
	var l: Dictionary = LAWYERS[tier]
	if float(l.skill) <= float(lawyer().skill):
		return "You already have someone as good."
	if sess.money < int(l.cost):
		return "%s wants $%s up front." % [l.name, Py.money(int(l.cost))]
	sess.money -= int(l.cost)
	case_.lawyer = tier
	case_.lawyer_honest = true
	_say("%s takes the case (%s)." % [l.name, l.blurb], "The pilot has retained %s" % l.name)
	return ""


const MOTION_COST := {"suppress": 3000, "discovery": 1500, "continuance": 2000}


## A pretrial motion: "suppress", "discovery" or "continuance".
func motion(kind: String) -> String:
	if case_ == null or not case_.stage in ["pretrial", "custody"]:
		return "No case in pretrial."
	if not MOTION_COST.has(kind):
		return "What motion?"
	if kind != "continuance" and case_.motions.has(kind):
		return "Already filed."
	if kind == "continuance" and int(case_.continuances) >= 2:
		return "The judge won't grant another continuance."
	var cost: int = MOTION_COST[kind]
	if sess.money < cost:
		return "Need $%s for the filing." % Py.money(cost)
	sess.money -= cost
	case_.motions.append(kind)
	var l := lawyer()
	match kind:
		"suppress":
			var p := 0.1 + 0.5 * float(l.skill) + (0.25 if case_.no_warrant else 0.0)
			if rng.random() < p:
				case_.evidence = maxf(0.0, float(case_.evidence) - 30.0)
				_say("Motion to suppress GRANTED: the search was unlawful, the cargo is out of evidence.",
					"The judge suppressed the search of the pilot's aircraft - no probable cause")
			else:
				_say("Motion to suppress denied.", "")
		"discovery":
			case_.discovered = true
			_say("Discovery: the evidence is %s (%d%%), %d witness%s%s." % [strength(), int(case_.evidence), int(case_.witnesses),
				"" if int(case_.witnesses) == 1 else "es", ", and one of them is an informant" if case_.informant else ""], "")
		"continuance":
			case_.continuances = int(case_.continuances) + 1
			case_.trial_at = float(case_.trial_at) + CONTINUANCE_S
			case_.evidence = float(case_.evidence) * 0.95  # memories fade, witnesses move away
			_say("Continuance granted: the trial moves back 10 minutes.", "")
	return ""


func strength() -> String:
	var e := float(case_.evidence)
	return "overwhelming" if e >= 75.0 else ("strong" if e >= 55.0 else ("moderate" if e >= 35.0 else "weak"))


## The Family leans on a witness. It may work, or become an obstruction case.
func tamper() -> String:
	if case_ == null or not case_.stage in ["pretrial", "custody"]:
		return "No case in pretrial."
	var fam = sess.family
	if fam == null or not fam.active():
		return "Nobody to ask."
	if case_.tampered:
		return "They've already done what they can."
	if int(case_.witnesses) <= 0:
		return "There's no witness to lean on."
	if sess.money < 5000:
		return "The Family wants $5,000 for the favour."
	sess.money -= 5000
	case_.tampered = true
	if rng.random() < 0.35:
		_charge("obstruction")
		case_.evidence = minf(100.0, float(case_.evidence) + 20.0)
		if case_.stage == "pretrial":
			case_.stage = "custody"
			case_.bail_posted = ""
		_say("The witness went to the FBI instead: obstruction of justice added, bail revoked.",
			"A witness in the pilot's case reports being threatened: obstruction charged, bail revoked")
	else:
		case_.witnesses = int(case_.witnesses) - 1
		case_.evidence = maxf(0.0, float(case_.evidence) - 12.0)
		_say("A witness has suddenly remembered nothing.", "One of our witnesses has stopped returning calls")
	return ""


## Pay the judge. Only one kind of judge takes it.
func bribe_judge() -> String:
	if case_ == null or not case_.stage in ["pretrial", "custody"]:
		return "No case in pretrial."
	if case_.bribed:
		return "Once was enough."
	if not case_.judge.bribable:
		return "%s isn't that kind of judge." % case_.judge.name
	if sess.money < 20000:
		return "It takes $20,000, in cash."
	sess.money -= 20000
	case_.bribed = true
	var p := 0.3 + (0.15 if sess.upgrades["law"].has("undercover") else 0.0)
	if rng.random() < p:
		_charge("obstruction")
		case_.evidence = minf(100.0, float(case_.evidence) + 25.0)
		case_.judge = JUDGES[0].duplicate()
		_say("The bagman was an FBI agent: bribery on tape. %s has the case now." % case_.judge.name,
			"A sting catches a bribe for Judge Dunne in the pilot's case: the case goes to Judge Pike")
	else:
		case_.bought = true
		_say("%s has been taken care of." % case_.judge.name, "")
	return ""


## Take the plea on the table.
func plead() -> String:
	if case_ == null or case_.plea.is_empty():
		return "No plea offer on the table."
	var p: Dictionary = case_.plea
	case_.charges = [p.charge]
	_sentence("pleaded guilty", float(p.years), int(p.fine))
	return ""


## Name names: a cooperation agreement. The sentence collapses, and the
## organisation pays for it.
func cooperate() -> String:
	if case_ == null or not case_.stage in ["pretrial", "custody", "bail"]:
		return "Too late for a deal."
	if case_.cooperating:
		return "You're already cooperating."
	case_.cooperating = true
	var n := 0
	if sess.stash_net != null:
		for st in sess.stash_net.live():
			st.intel += 35.0
			n += 1
	var fam = sess.family
	if fam != null and fam.active():
		fam.respect = 0.0
		fam.rico = minf(100.0, fam.rico + 20.0)
	if sess.ground != null:
		for q in sess.ground.of("org"):
			q.morale = maxf(0.2, q.morale - 0.2)
	sess.law_funds += 5000.0
	_say("You signed a cooperation agreement. The task force has the stash houses, the strips, the names. The Family knows.",
		"The pilot is cooperating: %d stash houses, the organisation's strips and names (+$5,000)" % n)
	sess.bus.emit("cooperating", sess.time, "", ["runner", "law"], {"stashes": n})
	_sentence("cooperated", _expected_years() * 0.1, 0)
	return ""


## One appeal from inside.
func appeal() -> String:
	if case_ == null or case_.stage != "prison":
		return "Nothing to appeal."
	if case_.appealed:
		return "The appeal was heard."
	if sess.money < 8000:
		return "An appeal costs $8,000."
	sess.money -= 8000
	case_.appealed = true
	if rng.random() < 0.15 + 0.4 * float(lawyer().skill):
		_say("The appeals court REVERSED: the conviction is thrown out. You're free.", "The pilot's conviction was reversed on appeal")
		_close("reversed on appeal")
	else:
		_say("Appeal denied.", "")
	return ""


# ------------------------------------------------------------------ the prosecution
func no_bail() -> String:
	if case_ == null or case_.stage != "bail":
		return "No bail hearing now."
	if case_.no_bail:
		return "Already denied."
	var p := 0.3 + (0.35 if flight_risk() else 0.0) + float(case_.judge.bias)
	if rng.random() < p:
		case_.no_bail = true
		_say("The prosecutor argued flight risk: bail DENIED.", "Bail denied: the pilot is held until trial")
	else:
		_say("", "The judge refused to deny bail")
	return ""


func immunity() -> String:
	if case_ == null or not case_.stage in ["bail", "pretrial", "custody"]:
		return "No case."
	if case_.immunity:
		return "Already done."
	if sess.law_funds < 4000.0:
		return "Need $4,000."
	sess.law_funds -= 4000.0
	case_.immunity = true
	case_.witnesses = int(case_.witnesses) + 1
	case_.evidence = minf(100.0, float(case_.evidence) + 10.0)
	_say("", "A crewman takes immunity and will testify (+1 witness)")
	return ""


func forfeiture() -> String:
	if case_ == null or not case_.stage in ["bail", "pretrial", "custody"]:
		return "No case."
	if int(case_.frozen) > 0:
		return "The accounts are already frozen."
	if sess.law_funds < 3000.0:
		return "Need $3,000."
	sess.law_funds -= 3000.0
	var k := int(maxi(0, sess.money) * 0.2)
	sess.money -= k
	case_.frozen = k
	sess.law_funds += float(k) * 0.8  # equitable sharing
	_say("The bank records were subpoenaed: $%s seized in a civil forfeiture." % Py.money(k),
		"Civil forfeiture: $%s of the pilot's money seized (80%% to the task force)" % Py.money(k))
	return ""


func add_conspiracy() -> String:
	if case_ == null or not case_.stage in ["bail", "pretrial", "custody"]:
		return "No case."
	if case_.charges.has("conspiracy"):
		return "Already charged."
	if float(case_.evidence) < 50.0:
		return "Not enough evidence for conspiracy yet (%d%%)." % int(case_.evidence)
	if sess.law_funds < 3000.0:
		return "Need $3,000."
	sess.law_funds -= 3000.0
	_charge("conspiracy")
	_say("A superseding indictment: conspiracy to import added.", "Conspiracy added to the pilot's indictment")
	return ""


## The prosecutor's plea: plead to the top charge for fewer years.
func offer_plea(lenient := false) -> String:
	if case_ == null or not case_.stage in ["pretrial", "custody"]:
		return "No case in pretrial."
	var top: String = Py.max_by(case_.charges, func(c): return CHARGES[c][1])
	var frac := (0.3 if lenient else 0.45) + float(case_.evidence) / 400.0
	if case_.lawyer == "family" and not case_.lawyer_honest:
		frac += 0.15  # the prosecutor knows your hand
	case_.plea = {"charge": top, "years": snappedf(_expected_years() * frac, 0.5), "fine": 3000 * _weight()}
	case_.plea_n = int(case_.plea_n) + 1
	_say("PLEA OFFER: plead guilty to %s, %s years. Your lawyer can walk you through it." % [CHARGES[top][0], Py.f(case_.plea.years, 1)],
		"Plea offered to the pilot: %s, %s years" % [CHARGES[top][0], Py.f(case_.plea.years, 1)])
	return ""


func _prosecutor_opening() -> void:
	if flight_risk() and rng.random() < 0.7:
		no_bail()
	if sess.law_funds > 8000.0 and int(case_.witnesses) < 2:
		immunity()
	if sess.money > 50000 and sess.law_funds > 6000.0:
		forfeiture()
	if float(case_.evidence) >= 55.0 and sess.law_funds > 6000.0:
		add_conspiracy()


# ------------------------------------------------------------------ trial and sentence
func _expected_years() -> float:
	var y := 0.0
	for c in case_.charges:
		var base: float = CHARGES[c][1]
		if mandatory and c == "trafficking":
			base = maxf(base, 10.0)  # the 1986 act's mandatory minimum
		y += base
	return y * float(case_.judge.sentence)


## The odds a jury convicts, now (the defence's view after discovery).
func conviction_odds() -> float:
	var x := _trial_x(0.0)
	return 1.0 / (1.0 + exp(-x))


func _trial_x(noise: float) -> float:
	var bias: float = float(case_.judge.bias) - (0.5 if case_.bought else 0.0)
	var x := (float(case_.evidence) - 50.0) / 12.0 + bias * 3.0 - float(lawyer().skill) * 2.2 + int(case_.witnesses) * 0.25 + noise
	if case_.lawyer == "family" and not case_.lawyer_honest:
		x += 1.5  # he was the prosecutor's man
	return x


func _trial() -> void:
	# a no-show: on the island, or anywhere the marshals can't reach
	var s = sess.state
	var away: bool = sess.location == Island.CODE or (s != null and Island.in_airspace(s.x, s.y))
	if case_.stage == "pretrial" and away:
		case_.stage = "fugitive"
		_charge("bail_jumping")
		sess.police.case("runner").wanted = true
		_say("You missed the trial. A warrant is out; the bail is forfeit. Stay out of their reach.",
			"The pilot failed to appear: fugitive warrant issued, bail forfeited")
		if case_.bail_posted == "cash":
			sess.law_funds += float(case_.bail) * 0.5
		return
	var x := _trial_x(rng.gauss(0.0, 0.8))
	if absf(x) < 0.4 and rng.random() < 0.35:
		case_.trial_at = sess.time + RETRIAL_S
		case_.evidence = maxf(0.0, float(case_.evidence) - 10.0)
		case_.stage = "custody" if case_.bail_posted == "" else "pretrial"
		_say("HUNG JURY. A mistrial - the government will try again in 10 minutes.", "Hung jury in the pilot's case: retrial set")
		return
	if case_.bail_posted == "cash":
		sess.money += int(case_.bail)  # you showed up: the court returns it
	if x > 0.0 and rng.random() < 1.0 / (1.0 + exp(-x * 2.0)):
		_sentence("convicted", _expected_years(), 5000 * _weight())
	else:
		_say("NOT GUILTY on all counts. You walk out of the courthouse a free pilot.", "The jury acquitted the pilot")
		sess.bus.emit("acquitted", sess.time, "", ["runner", "law"], {})
		_close("acquitted")


func _sentence(how: String, years: float, fine: int) -> void:
	case_.verdict = how
	case_.years = years
	var mins := clampf(years * MIN_PER_YEAR, 0.0, MAX_PRISON_MIN)
	var k := mini(maxi(0, sess.money), fine + int(maxi(0, sess.money) * (0.3 if how == "convicted" else 0.1)))
	sess.money -= k
	sess.law_funds += float(k) * 0.8
	if how == "convicted" and sess.aircraft_key != "c172p":
		sess._switch_aircraft("c172p", 0.5)  # forfeited; a used Skyhawk waits when you get out
	sess.police.score["convictions"] = int(sess.police.score.get("convictions", 0)) + 1
	if mins < 1.0:
		_say("%s: %s years, served as time already done. -$%s." % [how.capitalize(), Py.f(years, 1), Py.money(k)], "The pilot %s: %s years" % [how, Py.f(years, 1)])
		_close(how)
		return
	case_.stage = "prison"
	case_.release_at = sess.time + mins * 60.0
	_say("%s: %s years (%d min inside). Fines and forfeiture -$%s%s." % [how.capitalize(), Py.f(years, 1), int(mins), Py.money(k),
		"; the aircraft is forfeited" if how == "convicted" else ""],
		"The pilot %s: %s years" % [how, Py.f(years, 1)])
	sess.bus.emit("sentenced", sess.time, how, ["runner", "law"], {"years": years})


func _close(verdict: String) -> void:
	history.append({"verdict": verdict, "years": float(case_.years), "t": sess.time, "charges": case_.charges.duplicate()})
	case_ = null
	if sess.phase in ["busted", "custody"]:
		sess.phase = "busted"
		sess.respawn()


# ------------------------------------------------------------------ the clock
func update(dt: float) -> void:
	if case_ == null:
		return
	var now: float = sess.time
	match str(case_.stage):
		"bail":
			if now >= float(case_.bail_by):
				# nobody decided: the AI (or the default) - a bond if affordable, else custody
				if not case_.no_bail and sess.money >= int(case_.bail * 0.1):
					post_bail("bond")
				else:
					post_bail("custody")
		"pretrial", "custody":
			if prosecutor_ai and int(case_.plea_n) < PLEA_AT.size() and now - float(case_.t0) >= PLEA_AT[int(case_.plea_n)]:
				offer_plea(int(case_.plea_n) == 1)
			if now >= float(case_.trial_at):
				_trial()
		"prison":
			if now >= float(case_.release_at):
				_say("Released. The organisation sends a car.", "The pilot has been released")
				_close(str(case_.verdict))
	if case_ != null:
		sess.phase = "custody" if holding() and case_.stage != "bail" else sess.phase


func view(side: String) -> Dictionary:
	if case_ == null:
		return {"open": false, "history": history.size()}
	var c: Dictionary = case_
	var now: float = sess.time
	var v := {"open": true, "id": c.id, "stage": c.stage, "charges": c.charges.map(func(x): return CHARGES[x][0]),
		"judge": c.judge.name, "judge_known": c.judge.known, "lawyer": lawyer().name, "lawyer_tier": c.lawyer,
		"trial_s": maxi(0, int(float(c.trial_at) - now)), "bail": int(c.bail), "bail_posted": c.bail_posted,
		"no_bail": c.no_bail, "bail_s": maxi(0, int(float(c.bail_by) - now)), "plea": c.plea.duplicate(),
		"release_s": maxi(0, int(float(c.release_at) - now)) if c.stage == "prison" else 0, "verdict": c.verdict,
		"years": float(c.years), "cooperating": c.cooperating, "motions": c.motions.duplicate(),
		"continuances": int(c.continuances), "appealed": c.appealed}
	if side == "law" or c.discovered:
		v["evidence"] = int(c.evidence)
		v["witnesses"] = int(c.witnesses)
		v["informant"] = c.informant
		v["odds"] = snappedf(conviction_odds(), 0.01)
	v["strength"] = strength()
	if side == "law":
		v["immunity"] = c.immunity
		v["frozen"] = int(c.frozen)
	else:
		v["bribable"] = c.judge.bribable
		v["tampered"] = c.tampered
		v["bribed"] = c.bribed
	return v
