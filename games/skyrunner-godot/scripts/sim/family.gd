class_name Family
extends RefCounted
## "The Family": a Cosa Nostra crime family out of Tampa by way of New York
## (the Morettis, invented; nobody here is a real person) that runs the docks'
## union, the casinos' count rooms, the bookmakers and a loan-sharking book,
## and that will help the organisation - or rob it, or sell it out.
##
## The rule: every helping hand might be a trap. Each offer carries a hidden
## `honest` flag, rolled when it's made, and a *read*: what your people notice
## about it ("they've paid on time for a year", "his lawyer was seen at the
## federal building"). The read is right about four times in five, so taking
## an offer is a judgement call, not a coin flip. Dishonesty rises with greed,
## with low respect, and with pressure: under a RICO case a made man flips, and
## a family with a rat in it sells everyone out to save itself.
##
## Offers (about one every OFFER_EVERY_S):
##   loan     cash now, repaid with the vig at the due time; the con: the vig
##            "changes", and the enforcers take what they're owed and more
##   laundry  a casino or a vending route cleans the cash: the case cools, for
##            a cut; the con: they skim, and a wiretap was listening
##   docks    the union at the port: the Coast Guard's boardings go slowly for
##            half an hour; the con: a rat tipped the Coast Guard off instead
##   guns     rifles from a fence at a premium; the con: a buy-bust
##   muscle   a crew of the Family's soldiers fights on our side for half an
##            hour; the con: they sell a stash to Los Cuervos
##   lawyer   the next bust is a fine and the cargo, not the aircraft; the con:
##            he reports to the prosecutor
##
## Without being asked: a street tax once the organisation is rich (pay it or
## a truck burns), selling to Los Cuervos too, a cop on the Family's payroll
## who leaks raids, moving in on a stash when the organisation is weak, and
## the rat's tips.
##
## The task force's side: the RICO case (rico_case), which a rat speeds up. At
## 100 the Commission trial ends the Family, and everything it knew about the
## organisation's stash houses goes into the evidence.
##
## Off for the Python replays (Family.ENABLED = false); built for sessions that
## ask (live play: family: true).

static var ENABLED := true

const NAME := "the Moretti family"
const OFFER_EVERY_S := 600.0
const OFFER_TTL_S := 300.0
const READ_ACCURACY := 0.8
const KINDS := ["loan", "laundry", "docks", "guns", "muscle", "lawyer"]
const TAX_AT := 60000  ## cash on hand that gets the Family's attention
const TAX_RATE := 0.1
const TAX_DUE_S := 900.0
const LOAN_DUE_S := 1800.0
const DOCKS_S := 1800.0
const MUSCLE_S := 1800.0
const PAYROLL_S := 1800.0
const RICO_CASE_COST := 2500
const RAT_AT := 60.0

const GOOD_READS := {
	"loan": ["They've carried our paper for a year and never moved the terms", "The shylock's own brother vouches for the vig"],
	"laundry": ["The count room's been clean since the new pit boss", "Their accountant is old-school: two sets of books, both balanced"],
	"docks": ["The union steward's nephew flies for us", "The longshoremen are out in force: nobody's talking to the Coast Guard"],
	"guns": ["The fence is a Moretti cousin; he's sold to us before", "The crates are army-stencilled and the price is too high to be a setup"],
	"muscle": ["Their soldiers want Los Cuervos off the docks as much as we do", "The capo sent his own son"],
	"lawyer": ["He got a Moretti underboss off in '81", "He won't take the case until the retainer clears: a careful man"],
}
const BAD_READS := {
	"loan": ["The shylock smiles too much; his last client moved to Ohio in a hurry", "The terms are generous. The Family is never generous"],
	"laundry": ["There's a van outside the social club that nobody owns", "The casino's manager is suddenly very friendly"],
	"docks": ["The steward was seen at the federal building", "They want the schedule for the whole week, in writing"],
	"guns": ["The fence is new and in a hurry", "They insisted on the meet at a motel with a clear view of the lot"],
	"muscle": ["The capo asked which stash is the busiest", "Their soldiers were drinking with Los Cuervos last week"],
	"lawyer": ["His last three clients all pleaded out", "He asked a lot of questions about the pilots' names"],
}

var sess
var rng: PyRandom
var respect := 50.0  ## 0..100: how the Family regards the organisation
var greed := 0.25  ## 0..1
var rico := 0.0  ## 0..100: the task force's racketeering case against the Family
var rat := false  ## a made man is cooperating
var gone := false  ## the Commission trial happened
var ai := true  ## no human boss or lieutenant: the organisation's AI answers the offers
var offers: Array = []  ## {id, kind, text, cost, amount, read, honest, expires}
var loan := {}  ## {amount, owed, due, honest}
var docks_until := -1.0
var docks_honest := true
var muscle := []  ## [squad id, until]
var lawyer := ""  ## "" | "honest" | "con": on retainer for the next bust
var tribute_due := 0
var tribute_by := -1.0
var taxed := false  ## the street tax has been asked for at least once
var payroll_until := -1.0
var knows := {}  ## stash id -> true: what the Family has learned about us
var loans_taken := 0
var cons := 0  ## how many times it has robbed us
var last := ""  ## the last thing that happened, for the desks
var _serial := 0
var _t := 0.0
var _offer_t := 0.0
var _side_t := 0.0
var _rat_t := 0.0


func _init(sess_, rng_: PyRandom) -> void:
	sess = sess_
	rng = rng_
	_offer_t = OFFER_EVERY_S * 0.5


func active() -> bool:
	return not gone


# ------------------------------------------------------------------ offers
## How likely the Family is to play it straight right now.
func honesty() -> float:
	var p := 0.78 + (respect - 50.0) / 200.0 - greed * 0.3 - rico / 400.0 - (0.3 if rat else 0.0)
	return clampf(p, 0.1, 0.95)


func _can_offer(kind: String) -> bool:
	match kind:
		"loan":
			return loan.is_empty()
		"laundry":
			return sess.money >= 8000
		"docks":
			return docks_until < sess.time
		"guns":
			return sess.arsenals.has("org")
		"muscle":
			return sess.ground != null and sess.stash_net != null and not sess.stash_net.live().is_empty()
		"lawyer":
			return lawyer == ""
	return true


## Make an offer of `kind` (or one drawn at random). Returns it, or null.
func offer(kind := ""):
	if gone:
		return null
	if kind == "":
		var pool := KINDS.filter(func(k): return _can_offer(k))
		if pool.is_empty():
			return null
		kind = pool[rng.randint(0, pool.size() - 1)]
	elif not _can_offer(kind):
		return null
	var honest := rng.random() < honesty()
	var right := rng.random() < READ_ACCURACY
	var reads: Array = (GOOD_READS if honest == right else BAD_READS)[kind]
	_serial += 1
	var o := {"id": "F%d" % _serial, "kind": kind, "honest": honest, "read": reads[rng.randint(0, reads.size() - 1)],
		"expires": sess.time + OFFER_TTL_S, "cost": 0, "amount": 0}
	match kind:
		"loan":
			o.amount = rng.randint(5, 15) * 1000
			o.text = "A loan: $%s now, $%s back in %d min" % [Py.money(o.amount), Py.money(int(o.amount * 1.2)), int(LOAN_DUE_S / 60)]
		"laundry":
			o.amount = int(mini(sess.money, 40000) / 1000) * 1000
			o.cost = int(o.amount * 0.15)
			o.text = "Wash $%s through the casino's count room for a 15%% cut ($%s): the case cools" % [Py.money(o.amount), Py.money(o.cost)]
		"docks":
			o.cost = 2000
			o.text = "The union at the port: the Coast Guard's boardings go slow for %d min ($%s)" % [int(DOCKS_S / 60), Py.money(o.cost)]
		"guns":
			o.amount = rng.randint(4, 8)
			o.cost = int(o.amount * Arsenal.TIERS.rifle.price * 1.3)
			o.text = "%d rifles from a fence, $%s" % [o.amount, Py.money(o.cost)]
		"muscle":
			o.cost = 3000
			o.text = "A crew of the Family's soldiers on our side for %d min ($%s)" % [int(MUSCLE_S / 60), Py.money(o.cost)]
		"lawyer":
			o.cost = 4000
			o.text = "A lawyer on retainer: the next bust is a fine, not the aircraft ($%s)" % Py.money(o.cost)
	offers.append(o)
	sess.say("THE FAMILY - %s. (%s)" % [o.text, o.read])
	return o


func get_offer(id: String):
	return Py.first(offers, func(o): return o.id == id)


## Take offer `id`. Returns "" or why not.
func accept(id: String) -> String:
	var o = get_offer(id)
	if o == null:
		return "No such offer."
	if sess.money < int(o.cost):
		return "Need $%s." % Py.money(int(o.cost))
	offers.erase(o)
	sess.money -= int(o.cost)
	var c = sess.police.case("runner")
	var honest: bool = o.honest
	match str(o.kind):
		"loan":
			loans_taken += 1
			sess.money += int(o.amount)
			loan = {"amount": o.amount, "owed": int(o.amount * (1.2 if honest else 1.8)), "due": sess.time + LOAN_DUE_S, "honest": honest}
			_did("$%s from the Family's shylock, due in %d min" % [Py.money(int(o.amount)), int(LOAN_DUE_S / 60)])
		"laundry":
			if honest:
				c.suspicion = maxf(0.0, c.suspicion - 15.0)
				respect = minf(100.0, respect + 5.0)
				_did("The cash comes back clean: the case cools")
			else:
				var skim := int(o.amount * 0.25)
				sess.money -= mini(skim, maxi(0, sess.money))
				c.suspicion = minf(100.0, c.suspicion + 8.0)
				rico = minf(100.0, rico + 5.0)
				_con("The count room skimmed another $%s - and the FBI had a wire in it" % Py.money(skim))
				sess.law_say("A wiretap in a casino count room: somebody washed smuggling money there")
		"docks":
			docks_until = sess.time + DOCKS_S
			docks_honest = honest
			sess.apply_upgrades()
			if honest:
				_did("The union has the docks: the Coast Guard's boardings go slow")
			else:
				c.suspicion = minf(100.0, c.suspicion + 10.0)
				_con("Somebody at the union called the Coast Guard with our schedule")
				sess.law_say("A tip from the docks: a go-fast is running tonight. Board it")
		"guns":
			if honest:
				sess.arsenals.org.add("rifle", int(o.amount))
				_did("%d rifles in the armoury" % int(o.amount))
			else:
				c.suspicion = minf(100.0, c.suspicion + 20.0)
				sess.law_funds += float(o.cost)
				if sess.arsenals.has("law"):
					sess.arsenals.law.add("rifle", int(o.amount))
				_con("The fence was a federal agent: the money's gone, the case grows")
				sess.law_say("Buy-bust at a motel: the smugglers' money is forfeit (+$%s)" % Py.money(int(o.cost)))
		"muscle":
			var st = Py.max_by(sess.stash_net.live(), func(s): return StashNet.suspicion(s))
			knows[st.id] = true
			if honest:
				var q = sess.ground.recruit("org", "foot", Vector2(st.x, st.y), false)
				if q is String:
					sess.money += int(o.cost)
					return q
				sess.ground.arsenal("org").give_back(q.loadout)  # their own guns, not ours
				q.loadout = {"rifle": q.men}
				q.ammo = q.men * 120
				q.tag = "family"
				sess.ground.order(q, {"type": "guard", "stash": st.id})
				muscle.append([q.id, sess.time + MUSCLE_S])
				_did("A Moretti crew guards %s" % st.name)
			else:
				st.heat += 25.0  # Los Cuervos know it now
				var k := mini(maxi(0, sess.money), 4000)
				sess.money -= k
				if sess.ground != null:
					var free: Array = sess.ground._free("rival")
					if not free.is_empty():
						sess.ground.order(free[0], {"type": "attack", "stash": st.id})
				_con("They sold %s to Los Cuervos, and took $%s for the trouble" % [st.name, Py.money(k)])
		"lawyer":
			lawyer = "honest" if honest else "con"
			_did("A lawyer on retainer")
	respect = minf(100.0, respect + 2.0)
	return ""


func decline(id: String) -> String:
	var o = get_offer(id)
	if o == null:
		return "No such offer."
	offers.erase(o)
	respect = maxf(0.0, respect - 3.0)  # nobody says no to the Family for free
	last = "Declined: %s" % o.text
	return ""


func _did(text: String) -> void:
	last = text
	sess.say("THE FAMILY - " + text)


func _con(text: String) -> void:
	cons += 1
	respect = maxf(0.0, respect - 5.0)
	last = text
	sess.say("THE FAMILY - " + text)
	sess.bus.emit("family_con", sess.time, text, ["runner"], {})


## The session is about to bust us: a lawyer on retainer may make it a fine.
## Returns true when the bust is handled here.
func lawyer_bust(how: String) -> bool:
	if lawyer == "":
		return false
	var kind := lawyer
	lawyer = ""
	var c = sess.police.case("runner")
	if kind == "con":
		c.suspicion = minf(100.0, c.suspicion + 25.0)
		_con("The lawyer worked for the prosecutor all along")
		return false
	var fine := 2000 + int(maxi(0, sess.money) * 0.1)
	sess.money -= fine
	for j in sess.active_jobs.duplicate():
		if j.hot():
			sess.econ.record_seizure(Economy.good_of(j), Economy.job_market(j))
			sess.active_jobs.erase(j)
			sess.loadout.remove_job(j.id)
	sess.law_funds += 1500.0
	sess.police.reset(false)
	_did("The lawyer gets it down to a fine: -$%s and the cargo (%s)" % [Py.money(fine), how])
	sess.law_say("The pilot walks on a technicality: a fine and the cargo. Somebody paid for a very good lawyer")
	return true


## The union's docks deal: the factor on the Coast Guard's boarding time.
func seize_factor() -> float:
	if docks_until < sess.time:
		return 1.0
	return 2.0 if docks_honest else 0.5


## A cop on the Family's payroll warns us of raids: extra chance to get away.
func raid_escape() -> float:
	return 0.3 if payroll_until > sess.time else 0.0


func pay_tribute() -> String:
	if tribute_due <= 0:
		return "Nobody's asking."
	if sess.money < tribute_due:
		return "Need $%s." % Py.money(tribute_due)
	sess.money -= tribute_due
	respect = minf(100.0, respect + 10.0)
	_did("Tribute paid: $%s. The Family is satisfied - for now" % Py.money(tribute_due))
	tribute_due = 0
	tribute_by = -1.0
	return ""


# ------------------------------------------------------------------ the law's side
## The task force builds a racketeering case. Returns "" or why not.
func rico_case() -> String:
	if gone:
		return "The Family's bosses are already in prison."
	if sess.law_funds < RICO_CASE_COST:
		return "Need $%d in funds." % RICO_CASE_COST
	sess.law_funds -= RICO_CASE_COST
	rico = minf(100.0, rico + 8.0 + rng.uniform(0.0, 6.0) + (8.0 if rat else 0.0))
	sess.law_say("RICO: the organised-crime squad files for more wiretaps on the Morettis - case %d%%" % int(rico))
	_check_trial()
	return ""


func _check_trial() -> void:
	if gone or rico < 100.0:
		return
	gone = true
	offers.clear()
	docks_until = -1.0
	payroll_until = -1.0
	lawyer = ""
	sess.apply_upgrades()
	sess.law_funds += 12000.0
	var n := 0
	if sess.stash_net != null:
		for id in knows:
			var st = sess.stash_net.get_stash(id)
			if st != null and not st.burned:
				st.intel += 30.0
				n += 1
	var text := "The Moretti family's bosses convicted under RICO: 100 years each"
	sess.say("NEWS - %s. What they knew about us is in the evidence (%d stash houses)." % [text, n])
	sess.law_say("NEWS - %s. The seized files name %d of the smugglers' stash houses (+$12,000)." % [text, n])
	sess.bus.emit("commission_trial", sess.time, text, ["runner", "law"], {"stashes": n})


func _flip() -> void:
	rat = true
	sess.law_say("A made man in the Moretti family wants to talk: he's cooperating")
	sess.bus.emit("rat_flipped", sess.time, "", ["law"], {})


# ------------------------------------------------------------------ the clock
func update(dt: float) -> void:
	if gone:
		return
	_t += dt
	if _t < 10.0:
		return
	var step := _t
	_t = 0.0
	var now: float = sess.time
	offers = offers.filter(func(o): return o.expires > now)
	# offers, and the AI's answers when nobody human runs the organisation
	_offer_t += step
	if _offer_t >= OFFER_EVERY_S:
		_offer_t = 0.0
		offer()
	if ai:
		for o in offers.duplicate():
			if o.expires - now < OFFER_TTL_S * 0.4:  # it thinks it over (a human in the cockpit gets first say)
				if ai_wants(o):
					accept(o.id)
				else:
					decline(o.id)
	# the loan comes due
	if not loan.is_empty() and now >= float(loan.due):
		_collect()
	# the muscle goes home
	for m in muscle.duplicate():
		if now >= m[1] and sess.ground != null:
			var q = sess.ground.get_squad(m[0])
			if q != null:
				q.loadout = {}  # their guns go with them
				sess.ground.disband(q)
			muscle.erase(m)
	if docks_until > 0.0 and now >= docks_until:
		docks_until = -1.0
		sess.apply_upgrades()
	if payroll_until > 0.0 and now >= payroll_until:
		payroll_until = -1.0
		sess.apply_upgrades()
	# the street tax
	if tribute_due <= 0 and sess.money >= TAX_AT and (not taxed or rng.random() < 0.01 * step / 10.0):
		taxed = true
		tribute_due = int(sess.money * TAX_RATE / 1000) * 1000
		tribute_by = now + TAX_DUE_S
		greed = minf(1.0, greed + 0.05)
		sess.say("THE FAMILY - A man in a good suit: the Family wants its piece, $%s, within %d min" % [Py.money(tribute_due), int(TAX_DUE_S / 60)])
		sess.bus.emit("street_tax", now, "", ["runner"], {"due": tribute_due})
	if tribute_due > 0:
		if ai and sess.money >= tribute_due:
			pay_tribute()
		elif now >= tribute_by:
			_torch()
	# the Family's own business, every few minutes
	_side_t += step
	if _side_t >= 300.0:
		_side_t = 0.0
		_business()
	# a racketeering case grows on its own, slowly; past RAT_AT someone may flip
	rico = minf(100.0, rico + 0.3 * step / 60.0)
	if not rat and rico >= RAT_AT and rng.random() < 0.03 * step / 10.0:
		_flip()
	if rat:
		_rat_t += step
		if _rat_t >= 600.0:
			_rat_t = 0.0
			_rat_tip()
	_check_trial()


## Would the organisation's AI take this? Value against what the read suggests.
func ai_wants(o: Dictionary) -> bool:
	var trusting: bool = GOOD_READS[o.kind].has(o.read)
	if not trusting:
		return false
	match str(o.kind):
		"loan":
			return sess.money < 5000
		"laundry":
			return sess.police.case("runner").suspicion >= 30.0
		"docks":
			return sess.maritime.boats.any(func(b): return b.kind == "gofast")
		"guns":
			return sess.arsenals.org.count() < 10 and sess.money > int(o.cost) * 3
		"muscle":
			return sess.money > 20000
		"lawyer":
			return sess.money > 30000
	return false


func _collect() -> void:
	var owed := int(loan.owed)
	var honest: bool = loan.honest
	loan = {}
	if honest and sess.money >= owed:
		sess.money -= owed
		respect = minf(100.0, respect + 8.0)
		_did("The loan is repaid with the vig: -$%s" % Py.money(owed))
		return
	# the vig changed, or we can't pay: the enforcers
	var k := mini(maxi(0, sess.money), owed)
	sess.money -= k
	var text := "The shylock's enforcers: the vig was $%s, they took $%s" % [Py.money(owed), Py.money(k)]
	if k < owed:
		text += _break_something()
	respect = maxf(0.0, respect - 10.0)
	if honest:
		last = text
		sess.say("THE FAMILY - " + text)
	else:
		_con(text + " (the terms 'changed')")


## Refuse the Family and something burns.
func _torch() -> void:
	tribute_due = 0
	tribute_by = -1.0
	respect = maxf(0.0, respect - 25.0)
	var text := "The tribute wasn't paid"
	text += _break_something()
	last = text
	sess.say("THE FAMILY - " + text)
	sess.bus.emit("family_torch", sess.time, text, ["runner"], {})


## Something of ours gets hurt: a truck torched, a stash turned over, cash taken.
func _break_something() -> String:
	if sess.stash_net != null and not sess.stash_net.trucks.is_empty():
		var t = sess.stash_net.trucks[0]
		sess.stash_net.trucks.erase(t)
		return ": a truck for %s burned on the road, the load with it" % t.stash
	if sess.stash_net != null and not sess.stash_net.live().is_empty():
		var st: Dictionary = sess.stash_net.live()[rng.randint(0, sess.stash_net.live().size() - 1)]
		st.heat += 20.0
		knows[st.id] = true
		return ": %s was turned over, and now the whole street knows it" % st.name
	var k := mini(maxi(0, sess.money), 5000)
	sess.money -= k
	return ": the club's windows, and $%s" % Py.money(k)


## The Family's own business: selling to both sides, a cop on the payroll,
## moving in on a weak organisation.
func _business() -> void:
	var r := rng.random()
	if r < 0.3 and sess.arsenals.has("rival"):
		sess.arsenals.rival.add("rifle", 3)
		if sess.ground != null:
			sess.ground.commanders.rival.cash += 2000.0
		if respect < 40.0 and sess.stash_net != null and not sess.stash_net.live().is_empty():
			var st = Py.max_by(sess.stash_net.live(), func(s): return StashNet.suspicion(s))
			st.heat += 15.0
			knows[st.id] = true
			last = "The Family sold Los Cuervos rifles, and told them where %s is" % st.name
		else:
			last = "The Family sold Los Cuervos a crate of rifles: it sells to both sides"
		sess.say("The word on the street: " + last)
	elif r < 0.5 and respect >= 60.0 and payroll_until < sess.time:
		payroll_until = sess.time + PAYROLL_S
		sess.apply_upgrades()
		_did("A sergeant on the Family's payroll will warn us of raids for %d min" % int(PAYROLL_S / 60))
	elif r < 0.6 and respect < 40.0 and sess.money < 5000 and sess.stash_net != null and sess.stash_net.live().size() > 1:
		var st = Py.min_by(sess.stash_net.live(), func(s): return s.heat)
		st.burned = true  # it's theirs now: no more loads through it
		_con("The Family moved in on %s while we were weak: it's theirs now" % st.name)


func _rat_tip() -> void:
	if sess.stash_net == null or sess.stash_net.live().is_empty():
		return
	var known: Array = sess.stash_net.live().filter(func(s): return knows.has(s.id))
	var st: Dictionary = known[0] if not known.is_empty() else sess.stash_net.live()[rng.randint(0, sess.stash_net.live().size() - 1)]
	st.intel += 20.0
	rico = minf(100.0, rico + 5.0)
	sess.law_say("The Moretti informant names a smugglers' stash: %s" % st.name)


func view(side: String) -> Dictionary:
	if side == "law":
		return {"rico": int(rico), "rat": rat, "gone": gone, "payroll": false}
	return {"respect": int(respect), "gone": gone, "last": last, "tribute": tribute_due,
		"tribute_s": maxi(0, int(tribute_by - sess.time)) if tribute_due > 0 else 0,
		"loan": {} if loan.is_empty() else {"owed": int(loan.owed) if loan.honest else int(loan.amount * 1.2), "due_s": maxi(0, int(float(loan.due) - sess.time))},
		"docks_s": maxi(0, int(docks_until - sess.time)), "lawyer": lawyer != "",
		"offers": offers.map(func(o): return {"id": o.id, "kind": o.kind, "text": o.text, "read": o.read, "cost": o.cost,
			"expires_s": int(o.expires - sess.time)})}
