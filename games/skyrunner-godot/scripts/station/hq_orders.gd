class_name HQOrders
extends RefCounted
## The boss's and chief's order menus: every order with what it costs, what it
## does, its current state from the season view, and a parameter the player
## sets with LEFT/RIGHT (which front, who to bribe, how many units...). ENTER
## issues it as an `hq` command. Replaces the Python station's key soup (the
## old hotkeys still work).

const ZONES := ["west", "north", "sea"]
const BRIBE_NAMES := ["harbor", "tower", "dispatcher"]
const FRONT_NAMES := ["laundromat", "car_lot", "marina"]

var side := "runner"
var param := {}  ## order key -> index / count chosen with LEFT/RIGHT


func _init(side_: String) -> void:
	side = side_


static func _money(v) -> String:
	return "$" + Py.money(int(v))


## Rows for the current view: {key, label, detail, state, order, args, choices}.
func rows(ss: Dictionary) -> Array:
	return _runner_rows(ss) if side == "runner" else _law_rows(ss)


func _pick(key: String, n: int, default := 0) -> int:
	return posmod(int(param.get(key, default)), n)


func _runner_rows(ss: Dictionary) -> Array:
	var o: Dictionary = ss.get("org", {})
	var out := []
	var room: int = int(ss.get("capacity", 0)) - int(o.get("laundered_tonight", 0))
	out.append({"key": "launder", "label": "Launder cash", "order": "launder", "args": {},
		"detail": "wash up to %s tonight through the fronts (free move)" % _money(maxi(0, room)),
		"state": "%s washed" % _money(o.get("laundered_tonight", 0))})
	var f: String = FRONT_NAMES[_pick("buy_front", 3)]
	var fr: Array = HQ.FRONTS[f]
	out.append({"key": "buy_front", "label": "Buy a front: < %s >" % f.replace("_", " "), "order": "buy_front",
		"args": {"kind": f}, "detail": "%s, washes %s/night at %d%% fee" % [_money(fr[0]), _money(fr[1]), int(fr[2] * 100)],
		"state": "own: " + (", ".join(o.get("fronts", [])) if o.get("fronts", []) else "none")})
	var who: String = BRIBE_NAMES[_pick("bribe", 3)]
	var paid: bool = who in o.get("bribes", [])
	out.append({"key": "bribe", "label": "%s < %s >" % ["Stop paying" if paid else "Bribe", who], "order": "drop_bribe" if paid else "bribe",
		"args": {"who": who}, "detail": "%s/night: %s" % [_money(HQ.BRIBES[who][0]), HQ.BRIBES[who][1]],
		"state": "payroll: " + (", ".join(o.get("bribes", [])) if o.get("bribes", []) else "nobody")})
	out.append({"key": "lawyer", "label": "Lawyer: %s" % ("drop" if o.get("lawyer") else "retain"), "order": "lawyer",
		"args": {"on": not o.get("lawyer", false)}, "detail": "$3,000/night; you hear how strong the case is",
		"state": "on retainer" if o.get("lawyer") else "no"})
	out.append({"key": "opsec", "label": "Burner phones", "order": "opsec", "args": {},
		"detail": "$1,000: no wiretap evidence tonight", "state": "tonight" if o.get("opsec") else "-"})
	out.append({"key": "counterintel", "label": "Counter-intelligence", "order": "counterintel", "args": {},
		"detail": "$4,000: burns 75% of police informants", "state": "tonight" if o.get("counterintel") else "-"})
	out.append({"key": "loyalty", "label": "Loyalty bonus", "order": "loyalty", "args": {},
		"detail": "$2,500: +20% crew loyalty (fewer flip)", "state": "%d%%" % int(float(o.get("loyalty", 0)) * 100)})
	var crews := _pick("crews", 3, int(o.get("crews", 0)))
	out.append({"key": "crews", "label": "Contract crews < %d >" % crews, "order": "crews", "args": {"n": crews},
		"detail": "$3,000 each: extra runs, 60% share, they don't know who they fly for", "state": str(o.get("crews", 0))})
	var decoys := _pick("decoys", 3, int(o.get("decoys", 0)))
	out.append({"key": "decoys", "label": "Decoy flights < %d >" % decoys, "order": "decoys", "args": {"n": decoys},
		"detail": "$1,500 each: empty runs that pull the police the wrong way", "state": str(o.get("decoys", 0))})
	var zone: String = ZONES[_pick("route", 3, ZONES.find(o.get("route", "west")))]
	out.append({"key": "route", "label": "Route < %s >" % zone, "order": "route", "args": {"zone": zone},
		"detail": "pays x%.2f; the chief may be patrolling it (free move)" % HQ.ZONE_PAY[zone], "state": str(o.get("route", "-"))})
	out.append({"key": "lie_low", "label": "Lie low tonight", "order": "lie_low", "args": {},
		"detail": "no main run; heat cools three times faster", "state": "LYING LOW" if o.get("lie_low") else "-"})
	var tier := int(o.get("tier", 0))
	var nxt = HQ.AIRCRAFT_TIERS[tier + 1] if tier + 1 < HQ.AIRCRAFT_TIERS.size() else null
	out.append({"key": "upgrade", "label": "Upgrade aircraft", "order": "upgrade", "args": {},
		"detail": ("%s for %s (x%.1f per run, +%d heat)" % [Aircraft.spec(nxt[0]).name, _money(nxt[1]), nxt[2], nxt[3]]) if nxt != null else "already flying the best",
		"state": Aircraft.spec(HQ.AIRCRAFT_TIERS[tier][0]).name})
	var g: String = ["scanner", "detector"][_pick("gear", 2)]
	out.append({"key": "gear", "label": "Buy gear < %s >" % g, "order": "gear", "args": {"name": g},
		"detail": "%s for the crews" % _money(HQ.GEAR_PRICES[g]), "state": ", ".join(o.get("gear", [])) if o.get("gear", []) else "-"})
	out.append({"key": "ready", "label": "READY - send the run", "order": "ready", "args": {},
		"detail": "lock tonight's plan", "state": "READY" if o.get("ready") else ""})
	return out


func _law_rows(ss: Dictionary) -> Array:
	var L: Dictionary = ss.get("law", {})
	var funded: Dictionary = L.get("funded", {})
	var out := []
	for unit in ["heli", "interceptor", "cutter"]:
		var n := _pick("fund_" + unit, 4, int(funded.get(unit, 0)))
		out.append({"key": "fund_" + unit, "label": "Fund %s < %d >" % [unit, n], "order": "fund", "args": {"unit": unit, "n": n},
			"detail": "$%.0fk each per night (free move)" % HQ.LAW_COSTS_K[unit], "state": str(funded.get(unit, 0))})
	var zones := [null] + ZONES
	var pz = zones[_pick("patrol", 4, zones.find(L.get("patrol")))]
	out.append({"key": "patrol", "label": "Patrol < %s >" % (pz if pz != null else "none"), "order": "patrol", "args": {"zone": pz},
		"detail": "units start near that zone; a match makes interception far likelier", "state": str(L.get("patrol")) if L.get("patrol") else "-"})
	out.append({"key": "aerostat", "label": "Raise the aerostat", "order": "aerostat", "args": {},
		"detail": "$6k: 22 km radar over the south coast and sea lanes", "state": "up" if L.get("aerostat") else "down"})
	var inf := int(L.get("informants", 0))
	out.append({"key": "recruit", "label": "Recruit an informant", "order": "recruit", "args": {},
		"detail": "$%.0fk, odds x%.2f (each extra one is harder); +1.8 evidence/night and tips" % [HQ.LAW_COSTS_K["informant"] * (1 + inf), pow(0.6, inf)],
		"state": "%d/%d" % [inf, HQ.INFORMANT_CAP]})
	out.append({"key": "wiretap", "label": "Wiretap", "order": "wiretap", "args": {},
		"detail": "$7k: +3 evidence unless they use burners (warrant needs 20 evidence)",
		"state": ("on" if L.get("wiretap") else "-") + ("" if ss.get("wiretap_ok") else "  (no warrant)")})
	out.append({"key": "audit", "label": "Financial audit", "order": "audit", "args": {},
		"detail": "$3k: evidence from laundering exposure; estimates their clean money", "state": "on" if L.get("audit") else "-"})
	out.append({"key": "ia_sweep", "label": "Internal-affairs sweep", "order": "ia_sweep", "args": {},
		"detail": "$4k: may catch a bribed official (big evidence)", "state": "on" if L.get("ia_sweep") else "-"})
	out.append({"key": "encryption", "label": "Encrypted radios", "order": "encryption", "args": {},
		"detail": "$5k once: scanners go deaf", "state": "yes" if L.get("encryption") else "no"})
	out.append({"key": "press", "label": "Press conference", "order": "press", "args": {},
		"detail": "after a bust: support up, budget up", "state": "done" if L.get("press") else "-"})
	out.append({"key": "ready", "label": "READY - start the operation", "order": "ready", "args": {},
		"detail": "lock tonight's posture", "state": "READY" if L.get("ready") else ""})
	return out


## LEFT/RIGHT on a row with a parameter.
func adjust(row: Dictionary, d: int, ss: Dictionary) -> void:
	var k: String = row["key"]
	var sizes := {"buy_front": 3, "bribe": 3, "crews": 3, "decoys": 3, "route": 3, "gear": 2, "fund_heli": 4,
		"fund_interceptor": 4, "fund_cutter": 4, "patrol": 4}
	if not sizes.has(k):
		return
	var cur := int(param.get(k, _current(k, ss)))
	param[k] = posmod(cur + d, sizes[k])


func _current(k: String, ss: Dictionary) -> int:
	var o: Dictionary = ss.get("org", {})
	var L: Dictionary = ss.get("law", {})
	match k:
		"crews", "decoys":
			return int(o.get(k, 0))
		"route":
			return maxi(0, ZONES.find(o.get("route", "west")))
		"patrol":
			return ([null] + ZONES).find(L.get("patrol"))
		"fund_heli", "fund_interceptor", "fund_cutter":
			return int(L.get("funded", {}).get(k.substr(5), 0))
	return 0
