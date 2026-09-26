class_name Roles
extends RefCounted
## Sides, roles, match modes and who is allowed to do what.
##
## Every non-flight action is a *command* issued by a role
## (Session.command(role, name, args)). Local menus, network clients and AI
## crew all go through the same gate.

const PILOT := "pilot"
const COPILOT := "copilot"
const SPOTTER := "spotter"
const BOAT := "boat"
const BOSS := "boss"  ## the organisation's HQ
const CONTROLLER := "controller"
const INTERCEPTOR := "interceptor"  ## police pilot: flies one unit in 3D
const CUTTER := "cutter"
const CHIEF := "chief"  ## the task force's HQ
const ALL := [PILOT, COPILOT, SPOTTER, BOAT, BOSS, CONTROLLER, INTERCEPTOR, CUTTER, CHIEF]

const SOLO := "solo"  ## human pilot vs AI law
const POLICE := "police"  ## human controller vs AI runners
const COOP := "coop"  ## human runner crew vs AI law
const VERSUS := "versus"  ## humans on both sides, AI fills gaps
const CAMPAIGN := "campaign"  ## solo/co-op, chapter rules

const _GROUND_OPS := ["accept_job", "drop_job", "move_item", "loadmaster", "set_fuel", "fill_ferry"]
const _CREW_AIR := ["kick", "pump", "call_boat", "auto_kick"]

static var PERMISSIONS := {
	PILOT: _GROUND_OPS + _CREW_AIR + ["buy_aircraft", "buy_gear", "hire_spotter", "transponder", "squawk", "upgrade", "autopilot",
		"confirm", "chat", "turn_around", "hq"],
	COPILOT: _GROUND_OPS + _CREW_AIR + ["hire_spotter", "chat"],
	SPOTTER: ["spotter_move", "chat"],
	BOAT: ["boat_goto", "chat"],
	BOSS: ["hq", "chat"],
	CONTROLLER: ["launch", "dispatch", "recall", "encrypt", "radio_channel", "jam", "upgrade", "raid_stash", "aerostat", "chat", "hq"],
	INTERCEPTOR: ["claim_unit", "release_unit", "chat"],
	CUTTER: ["cutter_goto", "chat"],
	CHIEF: ["hq", "chat"],
}

## Roles a human can take in each mode. Everything else is AI or absent.
const MODE_ROLES := {
	SOLO: [PILOT],
	POLICE: [CONTROLLER, INTERCEPTOR, CUTTER, CHIEF],
	COOP: [PILOT, COPILOT, SPOTTER, BOAT, BOSS],
	VERSUS: ALL,
	CAMPAIGN: [PILOT, COPILOT, SPOTTER, BOAT],
}


static func side(role: String) -> String:
	return "law" if role in [CONTROLLER, INTERCEPTOR, CUTTER, CHIEF] else "runner"


static func allowed(role: String, command: String) -> bool:
	return PERMISSIONS.get(role, []).has(command)


static func valid(role: String) -> bool:
	return ALL.has(role)
