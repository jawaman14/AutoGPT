class_name Upgrades
extends RefCounted
## Upgrade trees for both sides: electronics and counter-surveillance,
## espionage, the airframe, and weaponry. A node needs its parents; buying it
## applies its effect to the live game (Session.apply_upgrades reads `has`).
##
## Runner nodes are bought with the pilot's money in the hangar. Law nodes come
## out of the task force's funds - a budget plus asset forfeiture from busts
## and seizures - bought at the controller's desk, or by the AI chief as the
## money comes in.
##
## Weaponry is abstract: it changes chases, boardings and raids, never shows a
## wound, and it raises the stakes - an armed bust is a bigger case.

## side -> [[tree id, tree name, [node, ...]], ...]; node: {id, name, cost, req, desc}
const TREES := {
	"runner": [
		["electronics", "Electronics & counter-surveillance", [
			{"id": "scanner", "name": "Radio scanner", "cost": 1800, "req": [],
				"desc": "Hear police dispatch in radio range (unless encrypted)."},
			{"id": "prog_scanner", "name": "Programmable scanner", "cost": 2500, "req": ["scanner"],
				"desc": "Also scans the police tactical channel."},
			{"id": "burst_radio", "name": "Burst transmitter", "cost": 4000, "req": ["prog_scanner"],
				"desc": "Every call you make is a one-second burst: DF gets a smear, not a fix."},
			{"id": "detector", "name": "Radar detector", "cost": 2500, "req": [],
				"desc": "Warns when a radar paints or locks you."},
			{"id": "bearing_detector", "name": "Direction-finding detector", "cost": 3000, "req": ["detector"],
				"desc": "Shows which site is painting you, and from where."},
			{"id": "spoofer", "name": "Transponder spoofer", "cost": 6000, "req": ["bearing_detector"],
				"desc": "Squawks a borrowed identity: a tip naming your tail number doesn't match what Center sees."},
		]],
		["espionage", "Espionage", [
			{"id": "lookouts", "name": "Lookouts", "cost": 2000, "req": [],
				"desc": "Kids on bicycles at your strip: word when police units launch nearby."},
			{"id": "bug_sweep", "name": "Bug sweeps", "cost": 3000, "req": [],
				"desc": "Half of the informants' tips about your loads never reach the task force."},
			{"id": "mole", "name": "Mole in dispatch", "cost": 8000, "req": ["bug_sweep"],
				"desc": "Hear every police order, encrypted or not."},
			{"id": "double_agent", "name": "Double agent", "cost": 10000, "req": ["mole"],
				"desc": "Each hot job you take feeds the task force a false tip somewhere else."},
		]],
		["airframe", "Airframe", [
			{"id": "ferry_tank", "name": "Ferry tank", "cost": 3000, "req": [],
				"desc": "A bladder tank in the cabin; pump it forward in flight."},
			{"id": "dark_paint", "name": "Low-visibility paint", "cost": 2500, "req": [],
				"desc": "Matte grey: police crews spot you at 80% of the range."},
			{"id": "quiet_prop", "name": "Quiet propeller", "cost": 3500, "req": ["dark_paint"],
				"desc": "Slower, wider blades: heard later, seen later (70% combined)."},
			{"id": "heavy_gear", "name": "Heavy-duty gear", "cost": 4000, "req": [],
				"desc": "Oleo struts that take a 50% harder landing before they fold."},
		]],
		["weaponry", "Weaponry", [
			{"id": "armed_boat", "name": "Armed boat crew", "cost": 4000, "req": [],
				"desc": "The go-fast doesn't stop for a cutter easily: boarding takes twice as long. A seizure then carries a firearms charge."},
			{"id": "strip_guards", "name": "Armed strip guards", "cost": 5000, "req": ["armed_boat"],
				"desc": "Guards at your strips slow a raid: 40% of landing raids come up empty - and the ones that don't are an armed-bust case."},
		]],
		["trade", "The island trade", [
			{"id": "mule_school", "name": "Trained mules", "cost": 2000, "req": [],
				"desc": "Mules who don't sweat at customs: 1.25x less likely to be pulled aside."},
			{"id": "forged_papers", "name": "Forged papers", "cost": 3500, "req": ["mule_school"],
				"desc": "Clean passports and tickets: 1.3x less likely caught, and a caught mule can't name us."},
			{"id": "baggage_handlers", "name": "Baggage handlers on the payroll", "cost": 7000, "req": ["forged_papers"],
				"desc": "Our people on the ramp move the bags past the dogs: mules 2.2x less likely caught."},
			{"id": "false_bottoms", "name": "False-bottomed containers", "cost": 5000, "req": [],
				"desc": "Welded compartments under the shrimp: containers half as likely found."},
		]],
	],
	"law": [
		["sensors", "Sensors", [
			{"id": "doppler", "name": "Doppler processing", "cost": 6000, "req": [],
				"desc": "The MTI notch halves: crossing the beam or flying slow hides you far less."},
			{"id": "coastal_radar", "name": "Coastal radar", "cost": 9000, "req": [],
				"desc": "A new radar site on the coast by the cove."},
			{"id": "aew", "name": "Airborne early warning", "cost": 12000, "req": ["doppler"],
				"desc": "A radar aircraft orbits offshore: sees low targets over the sea from 60 km."},
		]],
		["signals", "Signals", [
			{"id": "encryption", "name": "Encrypted radios", "cost": 3000, "req": [],
				"desc": "Scanners get static - but launches take longer to coordinate."},
			{"id": "heli_df", "name": "Helicopter DF", "cost": 4000, "req": [],
				"desc": "Airborne helicopters take bearings on runner calls too."},
			{"id": "intercept", "name": "Intercept runner channels", "cost": 5000, "req": ["heli_df"],
				"desc": "The task force listens to crew and boat calls in range: every one is a tip."},
			{"id": "jammer", "name": "Jammer van", "cost": 7000, "req": ["intercept"],
				"desc": "Jam a 5 km zone for three minutes (J at the desk): nobody's call gets through."},
		]],
		["intel", "Intelligence", [
			{"id": "informants", "name": "Informant network", "cost": 4000, "req": [],
				"desc": "Word on the street: tips when a load is moving."},
			{"id": "undercover", "name": "Undercover agent", "cost": 8000, "req": ["informants"],
				"desc": "Half of the hot jobs leak their exact destination."},
			{"id": "counter_mole", "name": "Mole hunt", "cost": 6000, "req": [],
				"desc": "Finds and burns the organisation's mole in dispatch."},
		]],
		["interdiction", "Interdiction", [
			{"id": "armed_heli", "name": "Armed helicopter", "cost": 7000, "req": [],
				"desc": "Warning shots: a runner with a helicopter on the tail is forced down 30% faster."},
			{"id": "blackhawk", "name": "Blackhawk", "cost": 10000, "req": ["armed_heli"],
				"desc": "Helicopters fly 30% faster."},
			{"id": "fast_cutter", "name": "Fast patrol boat", "cost": 6000, "req": [],
				"desc": "Cutters 25% faster; boardings 30% quicker."},
		]],
		["customs", "Customs", [
			{"id": "sniffer_dogs", "name": "Sniffer dogs", "cost": 5000, "req": [],
				"desc": "Dogs at the airport and the port: mules 1.6x, containers 1.15x more likely caught."},
			{"id": "passenger_profiling", "name": "Passenger profiling", "cost": 6000, "req": ["sniffer_dogs"],
				"desc": "Customs pull aside anyone off the island flight who fits: mules 1.4x more likely caught."},
			{"id": "container_xray", "name": "Container X-ray", "cost": 9000, "req": [],
				"desc": "A gantry X-ray at the port: containers 1.7x more likely found."},
		]],
	],
}

## Gear the old hangar sold, now tree nodes (the id is the Session.GEAR key).
const GEAR_NODES := ["scanner", "detector", "ferry_tank"]
## Law features that are tree nodes (buying them turns the feature on).
const FEATURE_NODES := {"encryption": "encryption", "informants": "informants"}


static func node(side: String, id: String) -> Dictionary:
	for tree in TREES[side]:
		for n in tree[2]:
			if n.id == id:
				return n
	return {}


static func side_of(id: String) -> String:
	for side in TREES:
		if not node(side, id).is_empty():
			return side
	return ""


## Why `id` can't be bought right now, or "" when it can.
static func blocker(side: String, id: String, owned: Dictionary, funds: int) -> String:
	var n := node(side, id)
	if n.is_empty():
		return "No such upgrade."
	if owned.has(id):
		return "Already have it."
	for r in n.req:
		if not owned.has(r):
			return "Needs %s first." % node(side, r).name
	if funds < int(n.cost):
		return "Costs $%s." % Py.money(int(n.cost))
	return ""


## The next thing an AI chief buys: cheapest affordable node, in tree order.
static func ai_pick(owned: Dictionary, funds: int) -> String:
	var best := ""
	var best_cost := 1 << 30
	for tree in TREES["law"]:
		for n in tree[2]:
			if blocker("law", n.id, owned, funds) == "" and int(n.cost) < best_cost:
				best = n.id
				best_cost = int(n.cost)
	return best
