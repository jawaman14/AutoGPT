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
## Off for the Python replays (Agency.ENABLED = false); built for sessions that
## ask (live play: agency: true).

static var ENABLED := true

const PROTECT_S := 1800.0  ## the window after a run when the Agency still covers you
const QUASH_EXPOSURE := 20.0
const FLIGHT_EXPOSURE := 4.0
const INVESTIGATE_COST := 3000
const DESTS := ["Ilopango", "the Honduran border strips", "an airstrip in Costa Rica"]

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


func _init(sess_, rng_: PyRandom) -> void:
	sess = sess_
	rng = rng_


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
	return job


func carrying() -> bool:
	return sess.active_jobs.any(func(j): return j.agency)


func protecting() -> bool:
	return active() and (carrying() or sess.time < protected_until)


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


func flight_done(job) -> void:
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
	_check_exposed()


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


func view(side: String) -> Dictionary:
	if side == "law":
		return {"exposure": int(exposure), "quashed": quashed, "burned": burned}
	return {"trust": int(trust), "protected": maxi(0, int(protected_until - sess.time)) if protecting() else 0, "burned": burned,
		"flights": flights}
