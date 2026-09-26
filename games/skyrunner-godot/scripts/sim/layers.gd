class_name Layers
extends RefCounted
## Rule layers and seat plans: more players, more layers.
##
## Every seat needs meaningful decisions and every tool needs a counter (see
## docs/MULTIPLAYER.md), so the game stacks layers and turns on as many as the
## table can keep busy:
##   L1 Flight        weight & balance, fuel, strips, legal jobs
##   L2 Heat          contraband, radar, suspicion, police aircraft
##   L3 Crew          co-pilot, timed loading, airdrops, go-fast boats, cutters, ferry tanks
##   L4 Intel         scanner vs encryption, detector vs aerostat, spotters, DF, informants
##   L5 Organisation  a season of nights: HQs, laundering, bribes, evidence, budgets
## plan_match(players) picks the layer and deals out seats; AI fills the rest.

const LAYERS := [
	[1, "Flight", "Weight & balance, fuel, short strips, legal jobs", []],
	[2, "Heat", "Contraband, radar, suspicion and police aircraft", ["contraband", "interceptors", "rivals"]],
	[3, "Crew", "Co-pilot, timed loading, airdrops to go-fast boats, cutters, ferry tanks",
		["copilot", "airdrop", "ferry", "cutters"]],
	[4, "Intel", "Scanners vs encryption, detectors vs the aerostat, spotters, radio DF, informants",
		["scanner", "detector", "spotters", "df", "encryption", "aerostat", "informants"]],
	[5, "Organisation", "A season of nights between two HQs: laundering, bribes, evidence, budgets", ["hq"]],
]

# the order humans are seated in; AI covers the rest
const VERSUS_ORDER := [Roles.PILOT, Roles.CONTROLLER, Roles.COPILOT, Roles.INTERCEPTOR,
	Roles.BOSS, Roles.CHIEF, Roles.SPOTTER, Roles.CUTTER, Roles.BOAT]
const COOP_ORDER := [Roles.PILOT, Roles.COPILOT, Roles.SPOTTER, Roles.BOSS, Roles.BOAT]
const VERSUS_LAYER := {1: 3, 2: 4, 3: 4, 4: 4, 5: 5}  # players -> layer (6+ -> 5)
const COOP_LAYER := {1: 3, 2: 3, 3: 4, 4: 5}


static func features_for(level: int) -> Dictionary:
	var out := {}
	for i in maxi(1, mini(level, LAYERS.size())):
		for f in LAYERS[i][3]:
			out[f] = true
	return out


class Seat:
	var role: String
	var human: bool

	func _init(r: String, h: bool) -> void:
		role = r
		human = h

	func _to_string() -> String:
		return role + ("" if human else " (AI)")


class MatchPlan:
	var players: int
	var mode: String
	var layer: int
	var seats: Array = []
	var notes: Array = []

	func _init(p: int, m: String, l: int) -> void:
		players = p
		mode = m
		layer = l

	func features() -> Dictionary:
		return Layers.features_for(layer)

	func humans(side: String) -> Array:
		var out := []
		for s in seats:
			if s.human and Roles.side(s.role) == side:
				out.append(s.role)
		return out

	func describe() -> String:
		var lay: Array = Layers.LAYERS[layer - 1]
		var run := ", ".join(seats.filter(func(s): return Roles.side(s.role) == "runner").map(func(s): return str(s)))
		var law := ", ".join(seats.filter(func(s): return Roles.side(s.role) == "law").map(func(s): return str(s)))
		var out := "%d player(s), %s, layer %d (%s)\n  runners: %s\n  law:     %s" % [players, mode, layer, lay[1], run, law]
		for n in notes:
			out += "\n  - " + n
		return out


static func plan_match(players: int, versus := true, layer := 0) -> MatchPlan:
	players = maxi(1, players)
	var order: Array
	var mode: String
	var lvl: int
	if players == 1 or not versus:
		order = COOP_ORDER
		mode = Roles.SOLO if players == 1 else Roles.COOP
		lvl = layer if layer else COOP_LAYER.get(players, 5)
	else:
		order = VERSUS_ORDER
		mode = Roles.VERSUS
		lvl = layer if layer else VERSUS_LAYER.get(players, 5)
	var humans := order.slice(0, players)
	var plan := MatchPlan.new(players, mode, lvl)
	# seats that exist at this layer
	var wanted := [Roles.PILOT, Roles.CONTROLLER]
	if lvl >= 3:
		wanted += [Roles.COPILOT, Roles.INTERCEPTOR, Roles.BOAT, Roles.CUTTER]
	if lvl >= 4:
		wanted += [Roles.SPOTTER]
	if lvl >= 5:
		wanted += [Roles.BOSS, Roles.CHIEF]
	for r in humans:
		if not wanted.has(r):
			wanted.append(r)
	for r in wanted:
		plan.seats.append(Seat.new(r, humans.has(r)))
	var run_h := plan.humans("runner").size()
	var law_h := plan.humans("law").size()
	if mode == Roles.VERSUS and run_h != law_h:
		plan.notes.append("%s have the extra human; the other side's AI seats play at full strength."
			% ("Runners" if run_h > law_h else "Law"))
	if lvl >= 5 and not humans.has(Roles.BOSS):
		plan.notes.append("No human boss: the pilot gets the HQ screen between nights (or the AI runs it).")
	if lvl >= 5 and mode == Roles.VERSUS and not humans.has(Roles.CHIEF):
		plan.notes.append("No human chief: the controller gets the budget screen between nights (or the AI runs it).")
	return plan
