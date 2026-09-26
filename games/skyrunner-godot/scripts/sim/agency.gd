class_name Agency
extends RefCounted
## "The Company": a covert intelligence agency running guns south to the
## Contra rebels through the island's strips, and the task force's awkward
## opponent. Fiction inspired by the documented history of the period: the
## Boland Amendments (1982, 1984) cut off U.S. funding for the Contras, the
## supply effort went private and covert, a supply plane was shot down over
## Nicaragua in October 1986 and its surviving crewman talked, the Iran-Contra
## affair broke in November 1986, and a Senate subcommittee (the Kerry
## Committee, reporting in 1989) found that people involved in Contra supply
## networks were also involved in drug trafficking, and that U.S. agencies had
## at times known about it. Nobody here is a real person; the mechanics are
## the game's.
##
## What it does:
##   - "southern front" arms flights on the shady strips' boards: weapons crates
##     flown to a strip where a contact flies them on; well paid, and they build
##     the Agency's trust in you
##   - protection: carrying its cargo, or for a while after a run, a bust is
##     quashed - a call from Washington, "national security" - and the police's
##     checkpoints are told to wave your trucks through. Every quash leaves a
##     trail (exposure)
##   - trust brings gifts: crates of rifles left at the strip for the
##     organisation's soldiers; the Agency protects its assets (it burns an
##     informant, cooling a stash)
##   - the task force can dig (investigate_agency: subpoenas, a friendly
##     congressman's staffer); exposure also grows with every flight and every
##     quash, and with the history. At 100 it is exposed: the hearings. The
##     protection is gone for good, the task force gets the budget and the
##     names, and the organisation's pilots are in the papers
##
## And its double game (its own RNG stream, so none of the above shifts):
##   - the limited hangout: past HANGOUT_AT exposure the Company may cut its
##     losses and feed your name to the task force itself - protection over
##   - a stung flight: the Agency let the DEA have this one, and the strip is a
##     trap; its notes may say the contact changed at the last minute (a read,
##     right about three times in four, like the Family's)
##   - "the check's in the mail": part of a flight's pay withheld, likelier
##     once the money has gone private
##   - both sides: it waves Los Cuervos' planes through too
##   - disinformation both ways: a warning that sends the task force after a
##     ghost (the intel on your hottest stash drops), or, once it needs a
##     scapegoat, an anonymous tip about one of yours
##   - a favour: the Company's cash washed through the Family's casinos, with
##     you as the go-between (a fee, and both of them like you better)
##
## Off for the Python replays (Agency.ENABLED = false); built for sessions that
## ask (live play: agency: true).

static var ENABLED := true

const PROTECT_S := 1800.0  ## the window after a run when the Agency still covers you
const QUASH_EXPOSURE := 20.0
const FLIGHT_EXPOSURE := 4.0
const INVESTIGATE_COST := 3000
const DESTS := ["Ilopango", "the Honduran border strips", "an airstrip in Costa Rica"]
const HANGOUT_AT := 70.0
const STING_HINT := "The contact changed at the last minute."

var sess
var rng: PyRandom
var trust := 20.0  ## 0..100: how much the Agency relies on the organisation
var exposure := 0.0  ## 0..100: how close the task force is to proving it
var protected_until := -1.0
var quashed := 0
var flights := 0
var burned := false  ## exposed: the hearings happened
var pay_mult := 1.0  ## the Boland squeeze: private money pays more
var offer_chance := 0.35
var _gift_t := 0.0
var _t := 0.0
var drng: PyRandom = null  ## the double game's stream (null: no double game)
var stings := {}  ## job id -> true: flights the Company let the DEA have
var hung_out := false  ## it cut us loose to save itself
var withheld := 0
var last_read := ""
var _game_t := 0.0


func _init(sess_, rng_: PyRandom, drng_: PyRandom = null) -> void:
	sess = sess_
	rng = rng_
	drng = drng_


func active() -> bool:
	return not burned


## A southern-front arms flight from `origin` (a shady or bush strip).
func job_from(origin: Airfield, airfields: Array):
	if burned:
		return null
	var dests := airfields.filter(func(a): return a.kind in ["shady", "bush"] and a.code != origin.code)
	if dests.is_empty():
		return null
	var dest: Airfield = dests[rng.randint(0, dests.size() - 1)]
	var jid := Jobs.new_id()
	var n := rng.randint(3, 6)
	var items := []
	for k in n:
		items.append(Jobs.item("Crate marked 'humanitarian aid'", "cargo", rng.uniform(30, 45), jid, {"hot": true}))
	var dist := PyMath.hypot(origin.x - dest.x, origin.y - dest.y) / 1000
	var pay := int((2400 + n * 500 + dist * 150) * pay_mult)
	var job := Jobs.Job.new(jid, "Southern front: %d crates -> %s" % [n, dest.name], "contraband", origin.code, dest.code, items, pay,
		{"notes": "Friends in Washington. A contact flies them on to %s. Nobody will stop you - probably." % DESTS[rng.randint(0, DESTS.size() - 1)]})
	job.weapons = {"rifle": n * 2}
	job.agency = true
	if drng != null:
		var sting := drng.random() < 0.06 + exposure / 300.0
		if sting:
			stings[jid] = true
		if drng.random() < (0.75 if sting else 0.12):
			job.notes += " " + STING_HINT
	return job


func carrying() -> bool:
	return sess.active_jobs.any(func(j): return j.agency)


func protecting() -> bool:
	return active() and not hung_out and not _stung_aboard() and (carrying() or sess.time < protected_until)


func _stung_aboard() -> bool:
	return sess.active_jobs.any(func(j): return j.agency and stings.has(j.id))


## The task force forced us down: if the Agency covers us, the case goes away.
func quash(how: String) -> bool:
	if not protecting():
		return false
	quashed += 1
	exposure = minf(100.0, exposure + QUASH_EXPOSURE)
	sess.police.reset(false)
	sess.say("A phone call from Washington: they let you go. National security. (%s)" % how)
	sess.law_say("The case is closed on orders from Washington - 'national security'. Someone is protecting that pilot.")
	sess.bus.emit("quashed", sess.time, "", ["runner", "law"], {"how": how})
	_check_exposed()
	return true


## Checkpoints are told to wave the organisation's trucks through (mostly).
func waves_through(r: PyRandom) -> bool:
	return protecting() and r.random() < 0.7


## A flight landed. Returns true when it was a sting (the session busts us).
func flight_done(job) -> bool:
	if stings.has(job.id):
		stings.erase(job.id)
		protected_until = -1.0  # no call from Washington for this one
		exposure = minf(100.0, exposure + FLIGHT_EXPOSURE)
		last_read = "The Company gave that flight to the DEA"
		sess.law_say("DEA sting at the strip: an arms flight walks into it. A tip from 'a friendly agency'")
		return true
	flights += 1
	trust = minf(100.0, trust + 12.0)
	protected_until = sess.time + PROTECT_S
	exposure = minf(100.0, exposure + FLIGHT_EXPOSURE)
	sess.say("The crates are on their way south. The Company remembers its friends (protected for %d min)." % int(PROTECT_S / 60))
	# the pipeline's other cargo: a plane goes down, a crewman talks
	if flights >= 3 and rng.random() < 0.08:
		exposure = minf(100.0, exposure + 30.0)
		sess.say("NEWS - A cargo plane carrying arms for the Contras was shot down; the surviving crewman is talking.")
		sess.law_say("NEWS - A Contra supply plane went down; the survivor names an airline and a strip network.")
	# the check's in the mail
	if drng != null and drng.random() < 0.12 + (0.12 if pay_mult > 1.0 else 0.0):
		var k := mini(maxi(0, sess.money), int(job.payout * 0.4))
		sess.money -= k
		withheld += k
		last_read = "$%s of the last flight's pay is 'in the mail'" % Py.money(k)
		sess.say("The Company: $%s of that pay is 'in the mail'. It won't come." % Py.money(k))
	_check_exposed()
	return false


## The task force digs: subpoenas, bank records, a congressional staffer.
func investigate() -> String:
	if burned:
		return "It's already all over the papers."
	if sess.law_funds < INVESTIGATE_COST:
		return "Need $%d in funds." % INVESTIGATE_COST
	sess.law_funds -= INVESTIGATE_COST
	var gain := 8.0 + 4.0 * quashed + rng.uniform(0.0, 8.0)
	exposure = minf(100.0, exposure + gain)
	sess.law_say("Investigators follow the money from the quashed cases: exposure %d%%" % int(exposure))
	_check_exposed()
	return ""


func _check_exposed() -> void:
	if burned or exposure < 100.0:
		return
	burned = true
	protected_until = -1.0
	trust = 0.0
	sess.law_funds += 15000.0
	var c = sess.police.case("runner")
	c.suspicion = minf(100.0, c.suspicion + 25.0)
	var text := "The hearings: the Agency's southern supply network is exposed - the arms flights, the protected pilots, the quashed cases."
	sess.say("NEWS - " + text + " Your name is in the testimony.")
	sess.law_say("NEWS - " + text + " Congress gives the task force the budget to finish it (+$15,000).")
	sess.bus.emit("agency_exposed", sess.time, text, ["runner", "law"], {})


func update(dt: float) -> void:
	if burned:
		return
	_t += dt
	if _t < 10.0:
		return
	var step := _t
	_t = 0.0
	if drng != null:
		_double_game(step)
	trust = maxf(0.0, trust - 0.5 * step / 60.0)
	_gift_t += step
	# trust brings favours: guns for the soldiers, a burned informant
	if _gift_t >= 900.0:
		_gift_t = 0.0
		if trust >= 50.0 and sess.arsenals.has("org") and rng.random() < 0.5:
			var n := rng.randint(2, 4)
			sess.arsenals.org.add("rifle", n)
			sess.say("A crate of rifles left at the strip, no note. Our friends from the Company.")
		elif trust >= 35.0 and sess.stash_net != null and rng.random() < 0.4:
			var hot = Py.max_by(sess.stash_net.live(), func(s): return StashNet.suspicion(s)) if not sess.stash_net.live().is_empty() else null
			if hot != null and hot.intel > 0.0:
				hot.intel = maxf(0.0, hot.intel - 25.0)
				sess.say("The Company protects its assets: the informant watching %s has been 'reassigned'." % hot.name)
				sess.law_say("Our informant on %s has gone quiet. Someone warned him off." % hot.name)


## The Company's double game (its own stream): a hangout, both sides, disinformation, a favour.
func _double_game(step: float) -> void:
	if not hung_out and exposure >= HANGOUT_AT and drng.random() < 0.012 * step / 10.0:
		hung_out = true
		protected_until = -1.0
		trust = 0.0
		exposure = maxf(0.0, exposure - 25.0)  # it bought itself time
		var c = sess.police.case("runner")
		c.suspicion = minf(100.0, c.suspicion + 30.0)
		last_read = "The Company cut us loose and gave the task force our name"
		sess.say("A man from the Company won't return calls. Then the task force knows things only the Company knew. We've been hung out to dry.")
		sess.law_say("An anonymous package from a 'government source': the smuggling organisation's pilots, strips and dates")
		sess.bus.emit("agency_hangout", sess.time, "", ["runner", "law"], {})
	_game_t += step
	if _game_t < 600.0:
		return
	_game_t = 0.0
	var r := drng.random()
	var live: Array = sess.stash_net.live() if sess.stash_net != null else []
	if r < 0.25 and sess.ground != null:
		sess.ground.commanders.rival.cash += 4000.0
		last_read = "Los Cuervos' planes get waved through too: the Company plays both sides"
		sess.say("Word from the strips: Los Cuervos' planes are getting waved through too.")
	elif r < 0.45 and trust >= 40.0 and not hung_out and not live.is_empty():
		var st = Py.max_by(live, func(s): return StashNet.suspicion(s))
		st.intel = maxf(0.0, st.intel - 20.0)
		last_read = "The Company sent the task force after a ghost: %s is cooler" % st.name
		sess.say("The Company fed the task force a false lead. %s can breathe." % st.name)
		sess.law_say("A hot lead from a 'federal source' goes nowhere: a week wasted")
	elif r < 0.6 and (exposure >= 50.0 or hung_out) and not live.is_empty():
		var st: Dictionary = live[drng.randint(0, live.size() - 1)]
		st.intel += 20.0
		last_read = "Someone with a government accent tipped the task force about %s" % st.name
		sess.law_say("An anonymous caller with a government accent names %s" % st.name)
	elif r < 0.7 and trust >= 50.0 and not hung_out and sess.family != null and sess.family.active():
		sess.money += 3000
		trust = minf(100.0, trust + 5.0)
		sess.family.respect = minf(100.0, sess.family.respect + 5.0)
		last_read = "We brokered the Company's cash through the Family's casinos (+$3,000)"
		sess.say("The Company needs its cash cleaned; the Morettis' casinos oblige, and we take a fee (+$3,000).")


func view(side: String) -> Dictionary:
	if side == "law":
		return {"exposure": int(exposure), "quashed": quashed, "burned": burned}
	return {"trust": int(trust), "protected": maxi(0, int(protected_until - sess.time)) if protecting() else 0, "burned": burned,
		"flights": flights, "hung_out": hung_out, "last": last_read}
