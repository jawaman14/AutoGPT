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
const LIEUTENANT := "lieutenant"  ## the organisation's soldiers on the ground (GroundWar)
const PATROL := "patrol"  ## the task force's narcotics squads on the ground (GroundWar)
const ALL := [PILOT, COPILOT, SPOTTER, BOAT, BOSS, LIEUTENANT, CONTROLLER, INTERCEPTOR, CUTTER, CHIEF, PATROL]
const _SQUADS := ["squad_order", "recruit_squad", "disband_squad"]

const SOLO := "solo"  ## human pilot vs AI law
const POLICE := "police"  ## human controller vs AI runners
const COOP := "coop"  ## human runner crew vs AI law
const VERSUS := "versus"  ## humans on both sides, AI fills gaps
const CAMPAIGN := "campaign"  ## solo/co-op, chapter rules

const _GROUND_OPS := ["accept_job", "drop_job", "move_item", "loadmaster", "set_fuel", "fill_ferry"]
const _CREW_AIR := ["kick", "pump", "call_boat", "auto_kick"]

static var PERMISSIONS := {
	PILOT: _GROUND_OPS + _CREW_AIR + ["buy_aircraft", "buy_gear", "hire_spotter", "transponder", "squawk", "upgrade", "autopilot",
		"confirm", "chat", "turn_around", "hq", "gun_mode", "sell_weapons", "buy_weapons"],
	COPILOT: _GROUND_OPS + _CREW_AIR + ["hire_spotter", "chat", "gun_mode"],
	SPOTTER: ["spotter_move", "chat"],
	BOAT: ["boat_goto", "chat"],
	BOSS: ["hq", "chat", "gun_mode", "sell_weapons", "buy_weapons", "set_cache", "squad_order", "recruit_squad", "disband_squad"],
	CONTROLLER: ["launch", "dispatch", "recall", "encrypt", "radio_channel", "jam", "upgrade", "raid_stash", "aerostat", "chat", "hq", "squad_order", "investigate_agency"],
	INTERCEPTOR: ["claim_unit", "release_unit", "chat"],
	CUTTER: ["cutter_goto", "chat"],
	CHIEF: ["hq", "chat", "squad_order", "recruit_squad", "disband_squad", "investigate_agency"],
	LIEUTENANT: _SQUADS + ["chat", "gun_mode", "sell_weapons", "buy_weapons", "set_cache"],
	PATROL: _SQUADS + ["raid_stash", "chat"],
}

## Roles a human can take in each mode. Everything else is AI or absent.
const MODE_ROLES := {
	SOLO: [PILOT],
	POLICE: [CONTROLLER, INTERCEPTOR, CUTTER, CHIEF, PATROL],
	COOP: [PILOT, COPILOT, SPOTTER, BOAT, BOSS, LIEUTENANT],
	VERSUS: ALL,
	CAMPAIGN: [PILOT, COPILOT, SPOTTER, BOAT],
}


static func side(role: String) -> String:
	return "law" if role in [CONTROLLER, INTERCEPTOR, CUTTER, CHIEF, PATROL] else "runner"


static func allowed(role: String, command: String) -> bool:
	return PERMISSIONS.get(role, []).has(command)


static func valid(role: String) -> bool:
	return ALL.has(role)
