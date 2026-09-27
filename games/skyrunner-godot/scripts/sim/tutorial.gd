class_name Tutorial
extends RefCounted
## The optional tutorial: a panel that teaches as you play, on top of any mode
## (the story, the open world, the sandbox). Nothing is scripted around you -
## each lesson waits for you to do the thing (take a job, get airborne, land it,
## hire a dealer, truck the cash home) and a lesson for a system waits until
## that system is in the game, so in the story each chapter's new faction gets
## its lesson when it opens. One-off tips cover the moments that need one: the
## first time you're wanted, low on fuel, busted, in fog, short of wages.
##
## F10 skips a lesson; SHIFT+F10 turns the tutorial off (the lobby turns it back
## on). Progress rides in the save, so a loaded game doesn't start over.
##
## The sim side (this) sees the events and the state; the seat's UI calls
## note() for what only it sees (a menu opened, stepping out on foot).

## [id, needs (a system that must be in the game, "" none), title, text]
const LESSONS := [
	["welcome", "", "Welcome aboard",
		"This panel teaches as you play: each step finishes when you do it.\nF10 skips a step, SHIFT+F10 turns the tutorial off. F1 lists every key."],
	["jobs", "", "Find work",
		"Parked at an airfield: press J for the job board. UP/DOWN to pick, ENTER to take it.\nLegal freight and passengers pay the bills; 'hot' jobs pay big and draw the police."],
	["load", "", "Load and fuel",
		"Press L for the load planner: where each item sits and how much fuel you carry.\nKeep the CG dot inside the envelope - too far aft and she pitches up and stalls."],
	["takeoff", "", "Take off",
		"Z full throttle (or R / PAGE UP), hold the centreline with Q/E, and ease back on S\nat about 55 kt. G/T flaps, B brakes. Climb past 300 ft."],
	["deliver", "", "Deliver",
		"Fly to the job's destination: the HUD shows its bearing and distance, M the big map.\nLand, stop on the strip, and the job pays out."],
	["transponder", "", "Seen and unseen",
		"N switches the transponder. Squawking looks legitimate; flying dark hides you only\nbelow the radar floor - a squawk that vanishes is suspicious. The detector shows who paints you."],
	["grass", "trade", "Your own product",
		"Bush strips sell grass: the board lists our own loads (paid up front, into our stash).\nTake one and fly it to the stash's strip."],
	["dealer", "payroll", "Hire the street",
		"SHIFT+W: Manny Ortega's hiring hall. Hire a street dealer - he sells what's in the stash,\ncorner by corner. Everyone on the payroll gets paid every 10 minutes."],
	["cash_home", "logistics", "Money has weight",
		"SHIFT+H: logistics. Street money piles up in the stash where it's made; wages and loads\ncome out of the club's safe. Truck the cash home - or load it as cash bags (C) and fly it."],
	["seller_cash", "logistics", "Cash on the strip",
		"The growers and the connection want cash on the strip: before you take our own load,\nload cash bags (SHIFT+H, C) where you keep the money - and fly them out."],
	["on_foot", "ground_war", "On foot",
		"Parked: TAB climbs out. WASD walk, E use, 1-4 draw a gun from the armoury, LMB fire,\nI your pack. TAB again to get back in."],
	["buyers", "trade", "Sell in bulk",
		"SHIFT+B: Benny Ruiz and the buyers. The Morettis, the Company and (guns only) Los Cuervos\ntake lots at a discount - and every sale moves the street and the wars."],
	["family", "family", "The Family",
		"SHIFT+F: sit down with Sal Moretti. Every offer comes with your man's read on it -\nand some offers are traps. SHIFT+Y takes the newest, SHIFT+N turns it down."],
	["island", "island", "Isla Soberana",
		"South over the horizon (SOB): cheap product, and the task force can't follow past the line.\nSHIFT+G raises the General's aide: passage, mules (SHIFT+U), containers (SHIFT+I)."],
	["company", "agency", "The Company",
		"Company jobs turn up on the shady strips' boards: crates south, product north.\nThey pay well and the protection is real - until it isn't."],
]

## [id, text] - shown once, when their moment comes (see _tips)
const TIPS := {
	"wanted": "You're WANTED. Break contact: low, behind hills, into cloud or rain; lose them over the sea. Landing dirty at a watched strip ends it.",
	"fuel": "Fuel under a quarter. Land and refuel (L), or pump the ferry tank (V) if you carry one.",
	"busted": "Busted. With a court in the game it's a case now: SHIFT+L talks to your lawyer - bail, motions, a plea or a deal.",
	"fog": "Sea fog tonight: the police crews can't see far and thick fog grounds the helicopters. The radar doesn't care.",
	"storm": "A storm: rain and cloud hide you from the crews, but the turbulence is real and helicopters stay home.",
	"short": "Payday's coming and the safe is thin. Unpaid crews skim, walk or talk - get the street money home.",
	"raided": "A stash was raided: what was in it is gone, cash too. Heat builds with every truck and delivery - spread the traffic.",
	"truck": "A truck was stopped. Roads near police strips and checkpoints are the risk; a soldier escort or a good driver helps.",
	"connection": "The Colombians called: cocaine jobs are on the shady strips' boards now. Much more money per pound - and per year inside.",
}

var sess
var enabled := true
var done := {}  ## lesson id -> true
var tips_shown := {}  ## tip id -> true
var tip := ""  ## the tip on screen
var tip_until := 0.0
var _notes := {}  ## what the seat's UI reported (menus opened, stepping out)
var _t0 := -1.0
var _sub := false
var _xpdr = null  ## the transponder when the lesson began


func _init(state = null) -> void:
	if state is Dictionary:
		enabled = bool(state.get("on", true))
		for id in state.get("done", []):
			done[str(id)] = true
		for id in state.get("tips", []):
			tips_shown[str(id)] = true


func attach(s) -> Tutorial:
	sess = s
	s.tutorial = self
	_t0 = s.time
	if not _sub:
		_sub = true
		s.bus.subscribe("*", _on_event)
	return self


func to_dict() -> Dictionary:
	return {"on": enabled, "done": done.keys(), "tips": tips_shown.keys()}


# ------------------------------------------------------------------ the lessons
func _needs_ok(needs: String) -> bool:
	match needs:
		"":
			return true
		"trade":
			return sess.trade != null
		"payroll":
			return sess.payroll != null
		"logistics":
			return sess.logistics != null
		"ground_war":
			return sess.ground != null
		"family":
			return sess.family != null and sess.family.active()
		"island":
			return sess.island != null
		"agency":
			return sess.agency != null and sess.agency.active()
	return false


## The lesson on screen: the first one not done whose system is in the game.
func current() -> Variant:
	if not enabled:
		return null
	for l in LESSONS:
		if not done.has(l[0]) and _needs_ok(l[1]):
			return l
	return null


## "3/9": this lesson's place among those the game can teach right now.
func progress() -> Array:
	var avail := LESSONS.filter(func(l): return _needs_ok(l[1]))
	var n := avail.filter(func(l): return done.has(l[0])).size()
	return [mini(n + 1, avail.size()), avail.size()]


func complete(id: String) -> void:
	if done.has(id):
		return
	done[id] = true
	var c = current()
	if enabled and c != null:
		sess.say("TUTORIAL - done: %s. Next: %s" % [_title(id), c[2]])
	elif enabled:
		sess.say("TUTORIAL - that's everything for now. New lessons appear as the game opens up.")


func _title(id: String) -> String:
	for l in LESSONS:
		if l[0] == id:
			return l[2]
	return id


func skip() -> void:
	var c = current()
	if c != null:
		done[c[0]] = true


func set_enabled(on: bool) -> void:
	enabled = on
	sess.say("Tutorial %s." % ("on" if on else "off - SHIFT+F10 or the lobby brings it back"))


## What only the seat's UI sees: "menu_j", "menu_l", "on_foot", "talk_family", "talk_general", "logistics".
func note(what: String) -> void:
	_notes[what] = true


func _on_event(ev: EventBus.Event) -> void:
	var d := ev.data
	match ev.kind:
		"job_accepted":
			complete("jobs")
		"job_delivered":
			complete("deliver")
			if str(d.get("good", "")) == "marijuana":
				complete("grass")
			if d.get("agency", false):
				complete("company")
		"cash_home":
			complete("cash_home")
		"bulk_sale":
			complete("buyers")
		"island_shipment":
			complete("island")
		"stash_raided":
			_show("raided")
		"truck_seized":
			_show("truck")
		"connection":
			_show("connection")


## Every frame or so: state-based lessons and the tips.
func tick(s) -> void:
	if _t0 < 0.0:
		_t0 = s.time
	if s.time - _t0 > 12.0:
		complete("welcome")
	if _notes.has("menu_l"):
		complete("load")
	if not s.parked and s.state != null and not s.state.on_ground and s.state.agl > 300.0 * 0.3048:
		complete("takeoff")
	if _xpdr == null:
		_xpdr = s.transponder
	if done.has("deliver") and s.transponder != _xpdr:
		complete("transponder")  # tried the switch, either way
	if s.logistics != null and s.logistics.aboard > 0:
		complete("seller_cash")
	if s.trade != null and s.trade.dealers("org").size() > 0:
		complete("dealer")
	if _notes.has("on_foot"):
		complete("on_foot")
	if _notes.has("talk_family") or (s.family != null and s.family.accepted > 0):
		complete("family")
	if _notes.has("talk_general"):
		complete("island")
	if not enabled:
		return
	# the tips
	if s.police.wanted > 0:
		_show("wanted")
	if s.state != null and not s.parked and s.loadout != null:
		var cap: float = s.loadout.mass.fuel_capacity_lb()
		if cap > 0.0 and s.state.fuel_lb < cap * 0.25:
			_show("fuel")
	if s.phase == "busted" and s.court != null:
		_show("busted")
	if float(s.weather.get("fog", 0.0)) > 0.0:
		_show("fog")
	if str(s.weather.get("sky", "")) == "storm":
		_show("storm")
	if s.payroll != null and s.money < s.payroll.wage_bill("org"):
		_show("short")
	if tip != "" and s.time > tip_until:
		tip = ""


func _show(id: String) -> void:
	if tips_shown.has(id) or not enabled:
		return
	tips_shown[id] = true
	tip = TIPS[id]
	tip_until = sess.time + 20.0
	sess.say("TIP - " + tip)


func view() -> Dictionary:
	var c = current()
	var p := progress()
	return {"on": enabled, "id": c[0] if c != null else "", "title": c[2] if c != null else "", "text": c[3] if c != null else "",
		"step": p[0], "of": p[1], "tip": tip}
