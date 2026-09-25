class_name SensorNet
extends RefCounted
## Detection: signatures in, noisy tracks out.
##
## Nobody on the law side sees the truth. Radars turn target signatures into
## tracks with position noise and an age; units that lose the track fly to the
## last known position. The same geometry drives the runner's radar detector
## ("painted" = a radar has line of sight to you, "locked" = it can actually
## see you above its clutter floor or through your transponder).

const TRACK_TIMEOUT := 45.0
const AEROSTAT_POS := [1500.0, -14800.0]


class Signature:
	var id: String
	var x: float
	var y: float
	var z: float  ## altitude MSL, m
	var agl: float
	var vx := 0.0
	var vy := 0.0
	var kind := "air"  ## air | surface
	var transponder := false
	var squawk := ""

	func _init(id_: String, x_: float, y_: float, z_: float, agl_: float, vx_ := 0.0, vy_ := 0.0, kind_ := "air",
			transponder_ := false, squawk_ := "") -> void:
		id = id_
		x = x_
		y = y_
		z = z_
		agl = agl_
		vx = vx_
		vy = vy_
		kind = kind_
		transponder = transponder_
		squawk = squawk_

	func speed_kts() -> float:
		return PyMath.hypot(vx, vy) / 0.514444


class RadarSite:
	var code: String
	var name: String
	var x: float
	var y: float
	var mast_z: float  ## absolute height of the antenna, m MSL
	var range_m: float
	var floor_base := 45.0  ## m AGL below which primary returns are lost in clutter
	var floor_per_m := 0.009
	var kind := "ground"  ## ground | aerostat
	var active := true

	func _init(code_: String, name_: String, x_: float, y_: float, mast_z_: float, range_m_: float, opts := {}) -> void:
		code = code_
		name = name_
		x = x_
		y = y_
		mast_z = mast_z_
		range_m = range_m_
		for k in opts:
			set(k, opts[k])

	func floor_at(dist_m: float) -> float:
		return floor_base + dist_m * floor_per_m

	## [painted, detected]
	func check(world: World, sig: Signature) -> Array:
		if not active or sig.kind != "air":
			return [false, false]
		var d := PyMath.hypot(sig.x - x, sig.y - y)
		if d > range_m:
			return [false, false]
		if not world.line_of_sight([x, y, mast_z], [sig.x, sig.y, sig.z], 250.0):
			return [false, false]
		if sig.transponder:
			return [true, true]  # secondary radar: the transponder answers regardless of clutter
		return [true, sig.agl >= floor_at(d)]


class Track:
	var target_id: String
	var x: float
	var y: float
	var z: float
	var vx: float
	var vy: float
	var t: float  ## time of last update
	var source: String
	var squawk = null  ## identity, only with transponder on
	var first_t := 0.0

	func age(now: float) -> float:
		return now - t

	func predicted(now: float, max_s := 20.0) -> Array:
		var dt := minf(max_s, age(now))
		return [x + vx * dt, y + vy * dt]


class Detection:
	var painted_by: Array = []
	var detected_by: Array = []

	## What the runner's radar detector shows.
	func detector_level() -> String:
		if not detected_by.is_empty():
			return "LOCK"
		if not painted_by.is_empty():
			return "PAINT"
		return ""


static func default_sites(world: World) -> Array:
	var sites := []
	for a in world.airfields:
		if a.radar_km > 0:
			sites.append(RadarSite.new(a.code, a.name + " radar", a.x, a.y, world.airfield_elev(a) + 30, a.radar_km * 1000))
	# The tethered balloon ("Fat Albert" in the real Keys). Off until the task force raises it.
	sites.append(RadarSite.new("AER", "Aerostat radar", AEROSTAT_POS[0], AEROSTAT_POS[1], 2500.0, 22000.0,
		{"floor_base": 20.0, "floor_per_m": 0.003, "kind": "aerostat", "active": false}))
	return sites


var world: World
var rng: PyRandom
var sites: Array
var tracks := {}


func _init(world_: World, rng_: PyRandom = null) -> void:
	world = world_
	if rng_ == null:
		rng_ = PyRandom.new()
		rng_.seed(0)
	rng = rng_
	sites = default_sites(world)


func site(code: String) -> RadarSite:
	for s in sites:
		if s.code == code:
			return s
	return null


func sweep(sigs: Array, now: float) -> Dictionary:
	var out := {}
	for sig in sigs:
		var det := Detection.new()
		for st in sites:
			var r: Array = st.check(world, sig)
			if r[0]:
				det.painted_by.append(st.code)
			if r[1]:
				det.detected_by.append(st.code)
		if not det.detected_by.is_empty():
			var src: String = det.detected_by[0]
			var s := site(src)
			var d := PyMath.hypot(sig.x - s.x, sig.y - s.y)
			report(sig, now, src, 40 + 0.004 * d)
		out[sig.id] = det
	expire(now)
	return out


func report(sig: Signature, now: float, source: String, sigma := 0.0) -> Track:
	var nx := rng.gauss(0, sigma) if sigma else 0.0
	var ny := rng.gauss(0, sigma) if sigma else 0.0
	var prev: Track = tracks.get(sig.id)
	var tr := Track.new()
	tr.target_id = sig.id
	tr.x = sig.x + nx
	tr.y = sig.y + ny
	tr.z = sig.z
	tr.vx = sig.vx
	tr.vy = sig.vy
	tr.t = now
	tr.source = source
	tr.squawk = sig.squawk if sig.transponder else null
	tr.first_t = prev.first_t if prev else now
	tracks[sig.id] = tr
	return tr


## A position with no velocity (DF fix, tip, spotter report).
func add_fix(target_id: String, x: float, y: float, now: float, source: String) -> Track:
	var prev: Track = tracks.get(target_id)
	var tr := Track.new()
	tr.target_id = target_id
	tr.x = x
	tr.y = y
	tr.z = prev.z if prev else 300.0
	tr.vx = 0.0
	tr.vy = 0.0
	tr.t = now
	tr.source = source
	tr.first_t = prev.first_t if prev else now
	tracks[target_id] = tr
	return tr


func expire(now: float) -> void:
	for tid in tracks.keys():
		if tracks[tid].age(now) > TRACK_TIMEOUT:
			tracks.erase(tid)
