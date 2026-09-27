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
		"South over the horizon (SOB): cheap product, and the task force can't follow past the line.\nSHIFT+G raises the General's aide: passage, mules (SHIFT+U), containers (SHIFT+I).\nWhat gets through lands in Warehouse 7 by the docks, to be sold like any load (SHIFT+H)."],
	["company", "agency", "The Company",
		"Company jobs turn up on the shady strips' boards: crates south, product north.\nThey pay well and the protection is real - until it isn't."],
]

## The desks: role -> [[id, needs, title, text, the commands that finish it]].
## A desk's lesson finishes on that role's own successful command (Session.command
## tells us), so it works the same from a remote seat.
const DESK_LESSONS := {
	"boss": [
		["b_orders", "", "Run the organisation",
			"UP/DOWN picks an order, LEFT/RIGHT changes it, ENTER issues it: fronts to launder, opsec, lying low, upgrades. The money is the club's safe.", ["hq"]],
		["b_logistics", "logistics", "Stock and cash have places",
			"K: logistics. Street money piles up in the stashes - truck it to the club (All cash home). Product sells only where it sits: move it to the corners, or to a buyer.", ["move_cash", "move_goods", "move_armoury", "escort_truck"]],
		["b_buyers", "trade", "Sell in bulk",
			"M: Benny Ruiz and the buyers. The Morettis, the Company and (guns only) Los Cuervos take lots at a discount - and every sale moves the street and the wars.", ["sell_product"]],
	],
	"lieutenant": [
		["l_squads", "ground_war", "Your squads",
			"CLICK a squad (or UP/DOWN), RIGHT-CLICK the map to send it. A sets an ambush, M melts away, H holds: guerrilla rules, never a fair fight.", ["squad_order"]],
		["l_recruit", "ground_war", "Raise a squad",
			"F, V or K raises a foot, car or truck squad from the soldiers on the payroll - each costs money and upkeep.", ["recruit_squad"]],
		["l_hire", "payroll", "The hiring hall",
			"W: Manny Ortega's hall. Soldiers for the squads, drivers, lookouts for the stashes, dealers for the corners. Payday every 10 minutes.", ["hire_worker"]],
		["l_family", "family", "The Family",
			"C: a sit-down with Sal Moretti. Y takes the newest offer, N turns it down, P pays the tribute - read the offer first, some are traps.", ["family_accept", "family_decline", "family_probe", "pay_tribute", "family_stall"]],
	],
	"controller": [
		["c_launch", "", "Launch",
			"H helicopter, I interceptor, C cutter launches a unit (toward the mouse). CLICK a unit, then the map, to send it. Watch the radar picture: tracks, squawks, DF bearings.", ["launch", "dispatch"]],
		["c_raid", "", "Raid a stash",
			"X raids the known stash house nearest the mouse (traffic and intel make them known). A raid burns it and takes what's inside.", ["raid_stash"]],
		["c_sweep", "trade", "The corners",
			"M sweeps the market under the mouse: dealers arrested, supply cut. T follows the money: bulk sales lead back to the organisation.", ["street_sweep", "trace_money"]],
		["c_rico", "family", "RICO",
			"O files a racketeering case against the Morettis: build it to a Commission trial.", ["rico_case"]],
		["c_airport", "island", "The airport and the port",
			"L cracks down at the airport, P puts inspectors on the port: fewer mules and containers get through - for a while.", ["airport_crackdown", "port_inspections"]],
		["c_court", "court", "Prosecute",
			"With a case open: N no bail, W immunity for a witness, K forfeiture, D charges, Y a plea offer. A offers an arrested worker a deal.", ["court_no_bail", "court_immunity", "court_forfeiture", "court_charge", "court_offer_plea", "offer_worker_deal"]],
	],
	"chief": [
		["h_orders", "", "Run the task force",
			"UP/DOWN picks an order, LEFT/RIGHT changes it, ENTER issues it: budget, patrols, informants, upgrades.", ["hq"]],
		["h_street", "trade", "The street",
			"M sweeps the market under the mouse; T follows the money from the bulk sales.", ["street_sweep", "trace_money"]],
	],
	"patrol": [
		["p_squads", "ground_war", "Narcotics squads",
			"CLICK a squad (or UP/DOWN), RIGHT-CLICK the map to send it; A sets a checkpoint there. A tail finds the stash a stop never would.", ["squad_order"]],
		["p_rico", "family", "RICO",
			"O files a racketeering case against the Morettis.", ["rico_case"]],
	],
	"copilot": [
		["o_crew", "", "The right seat",
			"K kicks a bale over the drop, O calls the boat, V pumps the ferry tank. 1-3 switch tabs.", ["kick", "call_boat", "pump"]],
	],
}

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
var desk_done := {}  ## role -> {lesson id: true}


func _init(state = null) -> void:
	if state is Dictionary:
		enabled = bool(state.get("on", true))
		for id in state.get("done", []):
			done[str(id)] = true
		for id in state.get("tips", []):
			tips_shown[str(id)] = true
		var dd = state.get("desks", {})
		if dd is Dictionary:
			for r in dd:
				desk_done[r] = {}
				for id in dd[r]:
					desk_done[r][str(id)] = true


func attach(s) -> Tutorial:
	sess = s
	s.tutorial = self
	_t0 = s.time
	if not _sub:
		_sub = true
		s.bus.subscribe("*", _on_event)
	return self


func to_dict() -> Dictionary:
	var dd := {}
	for r in desk_done:
		dd[r] = desk_done[r].keys()
	return {"on": enabled, "done": done.keys(), "tips": tips_shown.keys(), "desks": dd}


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
		"court":
			return sess.court != null
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


# ------------------------------------------------------------------ the desks
func desk_current(role: String) -> Variant:
	if not enabled:
		return null
	var dd: Dictionary = desk_done.get(role, {})
	for l in DESK_LESSONS.get(role, []):
		if not dd.has(l[0]) and _needs_ok(l[1]):
			return l
	return null


## Session.command calls this after a command succeeds.
func command_done(role: String, name: String) -> void:
	for l in DESK_LESSONS.get(role, []):
		if name in l[4] and not desk_done.get(role, {}).has(l[0]):
			if not desk_done.has(role):
				desk_done[role] = {}
			desk_done[role][l[0]] = true


func desk_skip(role: String) -> void:
	var c = desk_current(role)
	if c != null:
		if not desk_done.has(role):
			desk_done[role] = {}
		desk_done[role][c[0]] = true


func desk_view(role: String) -> Dictionary:
	var c = desk_current(role)
	var avail: Array = DESK_LESSONS.get(role, []).filter(func(l): return _needs_ok(l[1]))
	var n: int = avail.filter(func(l): return desk_done.get(role, {}).has(l[0])).size()
	return {"on": enabled, "id": c[0] if c != null else "", "title": c[2] if c != null else "", "text": c[3] if c != null else "",
		"step": mini(n + 1, avail.size()), "of": avail.size(), "tip": ""}
