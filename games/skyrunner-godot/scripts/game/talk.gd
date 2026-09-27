class_name Talk
extends RefCounted
## Conversations with the Family and with the General's aide, written as
## Dialogue Manager scripts (dialogue/*.dialogue; Nathan Hoad's Dialogue
## Manager, MIT, runtime vendored in addons/dialogue_manager/).
##
## No editor plugin, autoload or import step: `manager()` instances the
## runtime once (it registers the "DialogueManager" engine singleton itself)
## and `resource()` compiles a script from its text. The scripts read and act
## through a `State`, built from the seat's snapshot and its command callable,
## so a conversation goes through the same permission-checked commands as the
## desks' keys - on the host's own seat or a remote one alike.

const DIR := "res://dialogue/"
const CAPO := "Sal Moretti"
const AIDE := "Captain Ibarra"

static var _cache := {}


## The Dialogue Manager runtime, made on first use.
static func manager() -> Node:
	if Engine.has_singleton("DialogueManager"):
		return Engine.get_singleton("DialogueManager")
	var dm: Node = load("res://addons/dialogue_manager/dialogue_manager.gd").new()
	dm.name = "DialogueManager"
	(Engine.get_main_loop() as SceneTree).root.add_child(dm)
	return dm


## `name`.dialogue, compiled (cached). Null, with the errors printed, if it doesn't compile.
static func resource(name: String) -> DialogueResource:
	if _cache.has(name):
		return _cache[name]
	var text := FileAccess.get_file_as_string(DIR + name + ".dialogue")
	var result: DMCompilerResult = DMCompiler.compile_string(text, DIR + name + ".dialogue")
	if not result.errors.is_empty():
		for e in result.errors:
			push_error("%s.dialogue line %d: %s" % [name, int(e.line_number) + 1, DMConstants.get_error_message(e.error)])
		return null
	var r := DialogueResource.new()
	r.using_states = result.using_states
	r.titles = result.titles
	r.first_title = result.first_title
	r.character_names = result.character_names
	r.lines = result.lines
	r.raw_text = text
	_cache[name] = r
	return r


## Open conversation `name` at `title` over a seat's link (LocalLink or
## NetClient) in a balloon under `parent`. Returns the balloon (null if the
## script didn't compile).
static func open(parent: Node, name: String, title: String, link) -> TalkBalloon:
	var res := resource(name)
	if res == null:
		return null
	var st := State.new(func(): return link.snapshot(), func(n: String, a: Dictionary) -> Array:
		link.send_command(n, a)
		return link.last_result if link is LocalLink else [true, ""])
	var b := TalkBalloon.new()
	parent.add_child(b)
	b.start(res, title, st)
	return b


## What a conversation can see and do. Plain fields, refreshed from the
## snapshot before every line; methods issue commands, then refresh.
class State:
	var snap_fn: Callable  ## () -> Dictionary: the seat's snapshot
	var cmd_fn: Callable  ## (name, args) -> [ok, message]
	var capo := CAPO
	var aide := AIDE
	var money := 0
	var result := ""  ## the last command's refusal, if any
	# the Family
	var family := false
	var family_gone := false
	var respect := 0
	var has_offer := false
	var offer_id := ""
	var offer_kind := ""
	var offer_text := ""
	var offer_read := ""
	var offer_probe := ""
	var offer_cost := 0
	var tribute := 0
	var tribute_min := 0
	var stalled := false
	var loan_owed := 0
	var last := ""
	# the island
	var island := false
	var relations := 0
	var status := ""
	var passage_min := 0
	var passage_cost := 0
	var mule_pct := 0
	var ship_pct := 0
	var price := 0.0
	# the court (the pilot's case)
	var court := false
	var case_open := false
	var stage := ""
	var lawyer_name := ""
	var lawyer_tier := ""
	var judge := ""
	var judge_known := ""
	var bribable := false
	var charges := ""
	var strength := ""
	var odds := -1  ## the conviction odds in percent, once discovery is in (-1 unknown)
	var witnesses := -1
	var informant := false
	var trial_min := 0
	var bail := 0
	var bond := 0
	var no_bail := false
	var plea_years := 0.0
	var plea_charge := ""
	var has_plea := false
	var release_min := 0
	var verdict := ""
	var years := 0.0
	var appealed := false
	var tampered := false
	var bribed := false
	var filed := []  ## motions filed
	var continuances := 0
	# the trade (the buyers)
	var trade := false
	var coke := 0
	var weed := 0
	var rifles := 0
	var connected := true
	var connect_left := 0
	var street_coke := 0
	var street_weed := 0
	var quotes := {}
	var corners := {}
	var trade_last := ""
	# the payroll (the organisation's crew)
	var payroll := false
	var crew := 0
	var wage_bill := 0
	var crew_loyalty := 0  ## percent
	var unpaid := 0
	var cand: Array = []  ## up to four candidates: {id, name, role, skill, wage, hint}
	var jailed: Array = []  ## crew in custody without a lawyer: {id, name, role}

	func _init(snap_fn_: Callable, cmd_fn_: Callable) -> void:
		snap_fn = snap_fn_
		cmd_fn = cmd_fn_
		refresh()

	func refresh() -> void:
		var snap = snap_fn.call()
		if not (snap is Dictionary):
			return
		money = int(snap.get("money", 0))
		var f: Dictionary = snap.get("family", {})
		family = not f.is_empty()
		family_gone = bool(f.get("gone", false))
		respect = int(f.get("respect", 0))
		var offers: Array = f.get("offers", [])
		has_offer = not offers.is_empty()
		var o: Dictionary = offers.back() if has_offer else {}
		offer_id = str(o.get("id", ""))
		offer_kind = str(o.get("kind", ""))
		offer_text = str(o.get("text", ""))
		offer_read = str(o.get("read", ""))
		offer_probe = str(o.get("probe", ""))
		offer_cost = int(o.get("cost", 0))
		tribute = int(f.get("tribute", 0))
		tribute_min = int(ceil(float(f.get("tribute_s", 0)) / 60.0))
		stalled = bool(f.get("stalled", false))
		loan_owed = int(f.get("loan", {}).get("owed", 0))
		last = str(f.get("last", ""))
		var i: Dictionary = snap.get("island", {})
		island = not i.is_empty()
		relations = int(i.get("relations", 0))
		status = str(i.get("status", ""))
		passage_min = int(ceil(float(i.get("passage_s", 0)) / 60.0))
		passage_cost = int(i.get("passage_cost", 0))
		mule_pct = int(round(100.0 * float(i.get("mule_p", 0.0))))
		ship_pct = int(round(100.0 * float(i.get("ship_p", 0.0))))
		price = float(i.get("price", 0.0))
		var c: Dictionary = snap.get("court", {})
		court = not c.is_empty()
		case_open = bool(c.get("open", false))
		stage = str(c.get("stage", ""))
		lawyer_name = str(c.get("lawyer", "")).capitalize() if str(c.get("lawyer", "")).begins_with("the ") else str(c.get("lawyer", ""))
		lawyer_tier = str(c.get("lawyer_tier", ""))
		judge = str(c.get("judge", ""))
		judge_known = str(c.get("judge_known", ""))
		bribable = bool(c.get("bribable", false))
		charges = ", ".join(c.get("charges", []))
		strength = str(c.get("strength", ""))
		odds = int(round(100.0 * float(c.get("odds")))) if c.has("odds") else -1
		witnesses = int(c.get("witnesses", -1))
		informant = bool(c.get("informant", false))
		trial_min = int(ceil(float(c.get("trial_s", 0)) / 60.0))
		bail = int(c.get("bail", 0))
		bond = int(bail * 0.1)
		no_bail = bool(c.get("no_bail", false))
		var pl: Dictionary = c.get("plea", {})
		has_plea = not pl.is_empty()
		plea_years = float(pl.get("years", 0.0))
		plea_charge = str(Court.CHARGES.get(str(pl.get("charge", "")), [""])[0]) if has_plea else ""
		release_min = int(ceil(float(c.get("release_s", 0)) / 60.0))
		verdict = str(c.get("verdict", ""))
		years = float(c.get("years", 0.0))
		appealed = bool(c.get("appealed", false))
		tampered = bool(c.get("tampered", false))
		bribed = bool(c.get("bribed", false))
		filed = c.get("motions", [])
		continuances = int(c.get("continuances", 0))
		var p: Dictionary = snap.get("payroll", {})
		payroll = not p.is_empty()
		crew = p.get("crew", []).size()
		wage_bill = int(p.get("wage_bill", 0))
		crew_loyalty = int(round(100.0 * float(p.get("loyalty", 0.0))))
		unpaid = int(p.get("unpaid", 0))
		cand = p.get("candidates", []).slice(0, 4)
		var t: Dictionary = snap.get("trade", {})
		trade = not t.is_empty()
		coke = int(t.get("stock", {}).get("cocaine", 0))
		weed = int(t.get("stock", {}).get("marijuana", 0))
		connected = bool(t.get("connected", true))
		connect_left = maxi(0, int(Trade.CONNECT_LB) - int(t.get("sold", {}).get("marijuana", 0)))
		street_coke = int(t.get("street", {}).get("cocaine", 0.0))
		street_weed = int(t.get("street", {}).get("marijuana", 0.0))
		quotes = t.get("quotes", {})
		corners = t.get("corners", {})
		trade_last = str(t.get("last", ""))
		rifles = int(snap.get("arsenal", {}).get("stock", {}).get("rifle", 0))
		jailed = p.get("jail", []).filter(func(j): return not j.lawyer)

	func _do(name: String, args := {}) -> bool:
		var r: Array = cmd_fn.call(name, args)
		result = "" if r[0] else str(r[1])
		refresh()
		return r[0]

	func money_s(v: int) -> String:
		return "$" + Py.money(v)

	# the Family
	func take() -> bool:
		return _do("family_accept", {"id": offer_id})

	func refuse() -> bool:
		return _do("family_decline", {"id": offer_id})

	func press() -> bool:
		return _do("family_probe", {"id": offer_id})

	func pay() -> bool:
		return _do("pay_tribute")

	func stall() -> bool:
		return _do("family_stall")

	# the island
	func buy_passage() -> bool:
		return _do("buy_passage")

	func mules() -> bool:
		return _do("island_ship", {"method": "mules", "amount": 4})

	func container() -> bool:
		return _do("island_ship", {"method": "ship", "amount": 500})

	# the payroll
	func has_cand(i: int) -> bool:
		return i < cand.size()

	func cand_line(i: int) -> String:
		if i >= cand.size():
			return ""
		var c: Dictionary = cand[i]
		var sk := float(c.skill)
		return "%s, a %s - %s, $%d a payday. (%s)" % [c.name, Payroll.ROLES[c.role][2], "sharp" if sk >= 0.7 else ("solid" if sk >= 0.4 else "green"),
			int(c.wage), c.hint]

	func take_on(i: int) -> bool:
		return i < cand.size() and _do("hire_worker", {"id": cand[i].id})

	func crew_bonus() -> bool:
		return _do("pay_bonus")

	func jailed_name() -> String:
		return "" if jailed.is_empty() else "%s (%s)" % [jailed[0].name, Payroll.ROLES[jailed[0].role][2]]

	func lawyer_for_jailed() -> bool:
		return not jailed.is_empty() and _do("pay_worker_lawyer", {"id": jailed[0].id})

	# the buyers
	const LOT := {"cocaine": 20, "marijuana": 200, "guns": 5}

	func _have(good: String) -> int:
		return {"cocaine": coke, "marijuana": weed, "guns": rifles}.get(good, 0)

	func can_sell(buyer: String, good: String) -> bool:
		var q: Dictionary = quotes.get(buyer, {}).get(good, {})
		return not q.is_empty() and str(q.get("why", "x")) == "" and int(q.get("room", 0)) > 0 and _have(good) > 0

	func quote_line(buyer: String, good: String) -> String:
		var q: Dictionary = quotes.get(buyer, {}).get(good, {})
		var n := mini(mini(LOT[good], int(q.get("room", 0))), _have(good))
		if good == "guns":
			return "%d rifles at $%s each" % [n, Py.money(int(q.get("price", 0.0)))]
		return "%d lb of %s at $%s a pound" % [n, "grass" if good == "marijuana" else "cocaine", Py.money(int(q.get("price", 0.0)))]

	func sell(buyer: String, good: String) -> bool:
		return _do("sell_product", {"buyer": buyer, "good": good, "qty": LOT[good], "tier": "rifle"})

	func corners_line() -> String:
		var parts := []
		for m in corners:
			var c: Dictionary = corners[m]
			if int(c.ours) + int(c.theirs) > 0:
				parts.append("%s: %d of ours, %d of theirs" % [m, int(c.ours), int(c.theirs)])
		return ", ".join(parts) if not parts.is_empty() else "nobody on the corners yet - hire dealers (Manny)"

	# the court
	func has_filed(kind: String) -> bool:
		return filed.has(kind)

	func post_bail(how: String) -> bool:
		return _do("court_bail", {"how": how})

	func hire(tier: String) -> bool:
		return _do("court_hire", {"tier": tier})

	func move(kind: String) -> bool:
		return _do("court_motion", {"kind": kind})

	func lean_on_witness() -> bool:
		return _do("court_tamper")

	func pay_judge() -> bool:
		return _do("court_bribe")

	func plead() -> bool:
		return _do("court_plea")

	func cooperate() -> bool:
		return _do("court_cooperate")

	func appeal() -> bool:
		return _do("court_appeal")

	func wait() -> bool:
		return _do("court_wait")
