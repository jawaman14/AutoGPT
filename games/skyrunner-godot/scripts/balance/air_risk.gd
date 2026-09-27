class_name AirRisk
extends RefCounted
## One flown run's odds without flying it, for the live-play simulator
## (tools/live_balance.gd): what the tactical sweep measured when the pilot bot
## flew the real flight model against the AI task force (sim-results/tactical.json,
## 30 flights per police posture and tactic).
##
## The session's police pick the posture: tipped off when the runner's suspicion
## is 60+, the aerostat when the balloon is up, else heavy / standard / light by
## the units in stock. The pilot flies the tactic that did best against it
## (delivered minus busted minus crashed) - a player learns which way in works.
## When even that one is busted more than LIE_LOW of the time, the pilot stays on
## the ground: every way in is watched.
##
## The pooled calibration (HQ.Calibration: every tactic flown evenly) is the
## wrong stand-in here: it busts a quarter of all flights, low and evasive runs
## into a standing task force included, which no player keeps flying (BALANCE
## entry 31).

const LIE_LOW := 0.25
const TACTICS := ["high", "low", "evasive"]

static var _table := {}  ## posture -> tactic -> [p_bust, p_crash, p_delivered]


## The sweep's rates, smoothed ((k + 1) / (n + 2)) so 0 of 30 isn't "never".
static func table() -> Dictionary:
	if not _table.is_empty():
		return _table
	var f := FileAccess.open("res://sim-results/tactical.json", FileAccess.READ)
	var rows = JSON.parse_string(f.get_as_text()) if f != null else []
	var n := {}
	for r in (rows if rows is Array else []):
		var key := "%s/%s" % [r.law, r.tactic]
		if not n.has(key):
			n[key] = [0, 0, 0, 0]
		n[key][0] += 1
		n[key][1] += 1 if r.busted else 0
		n[key][2] += 1 if r.crashed else 0
		n[key][3] += 1 if r.delivered else 0
	for key in n:
		var c: Array = n[key]
		var parts: PackedStringArray = key.split("/")
		if not _table.has(parts[0]):
			_table[parts[0]] = {}
		var d := float(c[0] + 2)
		_table[parts[0]][parts[1]] = [(c[1] + 1) / d, (c[2] + 1) / d, (c[3] + 1) / d]
	return _table


## What the police look like to a flight right now.
static func posture(s) -> String:
	if float(s.police.case("runner").suspicion) >= 60.0:
		return "tipped"
	if s.police.aerostat_ready_t != null:
		return "aerostat"
	var units := (0 if s.police.heli_grounded else int(s.police.stock.get("heli", 0))) + int(s.police.stock.get("interceptor", 0))
	return "heavy" if units >= 4 else ("light" if units <= 1 else "standard")


## {posture, tactic, bust, crash, delivered, fly}: the best tactic's odds, and
## whether it's worth flying at all.
static func odds(s) -> Dictionary:
	var p := posture(s)
	var rates: Dictionary = table().get(p, {})
	var best := {"posture": p, "tactic": "", "bust": 0.0, "crash": 0.0, "delivered": 0.0, "fly": false}
	var score := -INF
	for t in TACTICS:
		if not rates.has(t):
			continue
		var r: Array = rates[t]
		if r[2] - r[0] - r[1] > score:
			score = r[2] - r[0] - r[1]
			best = {"posture": p, "tactic": t, "bust": r[0], "crash": r[1], "delivered": r[2], "fly": r[0] <= LIE_LOW}
	return best
