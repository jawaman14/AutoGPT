class_name StashNet
extends RefCounted
## The organisation's stash houses (maps that have them: MapCity). A stash
## job lands its load at a strip near the stash; the ground crew then trucks it
## in while the pilot is free to fly on. The truck is the exposed part:
##
##   - a police unit within a mile of the truck, low enough to see it, stops it
##   - so can a roadblock: a roll made when the truck leaves, likelier with the
##     stash's heat, a police strip, and a runner the task force is onto
##   - a seized truck costs the load (the task force forfeits it) but not the
##     aircraft
##
## Every delivery warms the stash up (heat decays slowly). A warm stash is
## known to the task force, and a known stash can be raided: burned for good,
## and any truck heading to it is taken too.

const TRUCK_MS := 11.0  ## ~40 km/h on island roads
const TRUCK_LOAD_S := 45.0
const STOP_RANGE_M := 1600.0
const HEAT_DELIVERY := 15.0
const HEAT_SEIZED := 25.0
const HEAT_DECAY_MIN := 1.5  ## per minute
const KNOWN_HEAT := 30.0  ## the task force knows where it is

class Truck:
	var job_id: int
	var title: String
	var stash: String
	var x0: float
	var y0: float
	var x1: float
	var y1: float
	var t0: float
	var dur: float
	var pay: int
	var items: int
	var stop_at := -1.0  ## fraction of the route where a roadblock waits, -1 none
	var weapons := {}  ## a gun run's weapons (Arsenal)
	var gun_mode := "sell"

	func frac(now: float) -> float:
		return clampf((now - t0) / dur, 0.0, 1.0)

	func pos(now: float) -> Array:
		var f := clampf((now - t0 - StashNet.TRUCK_LOAD_S) / maxf(1.0, dur - StashNet.TRUCK_LOAD_S), 0.0, 1.0)
		return [lerpf(x0, x1, f), lerpf(y0, y1, f)]


var stashes: Array = []  ## map dictionaries plus state: heat, burned
var trucks: Array = []
var rng: PyRandom
var events: Array = []  ## [side, text]: "runner" / "law"


func _init(map_stashes: Array, rng_: PyRandom) -> void:
	rng = rng_
	for s in map_stashes:
		var d: Dictionary = s.duplicate()
		d["heat"] = 0.0
		d["burned"] = false
		stashes.append(d)


func get_stash(id: String):
	for s in stashes:
		if s.id == id:
			return s
	return null


func live() -> Array:
	return stashes.filter(func(s): return not s.burned)


func known() -> Array:
	return stashes.filter(func(s): return s.heat >= KNOWN_HEAT or s.burned)


## A stash job from `origin`: contraband for one of the live stashes (not the
## one next door). Pays over the strip rate: the buyer takes it off your hands.
func job_from(origin: Airfield, jobs_rng: PyRandom, price_mult := 1.0):
	var choices := live().filter(func(s): return s.strip != origin.code)
	if choices.is_empty():
		return null
	var st: Dictionary = jobs_rng.choice(choices)
	var dest := World.airfield(st.strip)
	var jid := Jobs.new_id()
	var cnt := jobs_rng.randint(2, 5)
	var items := []
	for k in cnt:
		items.append(Jobs.item("Kilo brick crate", "cargo", jobs_rng.uniform(18, 35), jid, {"hot": true}))
	var w := Py.sum_by(items, func(i): return i.weight_lb)
	var dist := PyMath.hypot(origin.x - dest.x, origin.y - dest.y) / 1000
	var road := PyMath.hypot(st.x - dest.x, st.y - dest.y) / 1000
	var pay := int((1100 + w * 10 + dist * 120 + road * 150) * Jobs._difficulty(dest) * price_mult)
	return Jobs.Job.new(jid, "Stash run -> %s (land %s, truck in)" % [st.name, dest.code], "contraband", origin.code, dest.code,
		items, pay, {"stash": st.id, "notes": "Land at %s; the crew trucks it %.1f km to %s. The truck can be stopped." % [
			dest.name, road, st.name]})


## Put a landed stash job on the road. `risk` adds to the roadblock odds (the
## session knows about police strips and cases).
func dispatch(job: Jobs.Job, af: Airfield, now: float, pay: int, risk := 0.0) -> Truck:
	var st: Dictionary = get_stash(job.stash)
	var t := Truck.new()
	t.job_id = job.id
	t.title = job.title
	t.stash = st.id
	t.x0 = af.x
	t.y0 = af.y
	t.x1 = st.x
	t.y1 = st.y
	t.t0 = now
	t.dur = TRUCK_LOAD_S + PyMath.hypot(st.x - af.x, st.y - af.y) * 1.3 / TRUCK_MS  # roads wind: 1.3x the crow's line
	t.pay = pay
	t.items = job.items.size()
	t.weapons = job.weapons
	t.gun_mode = job.gun_mode
	var p := clampf(0.04 + float(st.heat) / 300.0 + risk, 0.0, 0.85)
	if st.burned:
		p = 1.0
	if rng.random() < p:
		t.stop_at = rng.uniform(0.2, 0.9)
	trucks.append(t)
	return t


## Advance the trucks. Returns [[truck, "delivered" | "seized", why], ...].
func update(dt: float, now: float, police_units: Array) -> Array:
	for s in stashes:
		s.heat = maxf(0.0, s.heat - dt * HEAT_DECAY_MIN / 60.0)
	var done := []
	for t in trucks.duplicate():
		var p: Array = t.pos(now)
		var why := ""
		if t.stop_at >= 0 and t.frac(now) >= t.stop_at:
			why = "a roadblock"
		for u in police_units:
			if u.state != "crashed" and u.z < 900 and PyMath.hypot(u.x - p[0], u.y - p[1]) < STOP_RANGE_M:
				why = "police %s overhead" % u.kind
				break
		if why != "":
			trucks.erase(t)
			get_stash(t.stash).heat += HEAT_SEIZED
			done.append([t, "seized", why])
		elif t.frac(now) >= 1.0:
			trucks.erase(t)
			get_stash(t.stash).heat += HEAT_DELIVERY
			done.append([t, "delivered", ""])
	return done


## Raid a stash: only one the task force knows about. Returns "" or why not.
func raid(id: String) -> String:
	var st = get_stash(id)
	if st == null:
		return "No such stash."
	if st.burned:
		return "Already burned."
	if st.heat < KNOWN_HEAT:
		return "No intelligence on %s yet." % st.name
	st.burned = true
	return ""


## The trucks going to `id` (a raid takes them too).
func trucks_to(id: String) -> Array:
	return trucks.filter(func(t): return t.stash == id)
