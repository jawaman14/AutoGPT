class_name SensorNet
extends RefCounted
## Detection: signatures in, noisy tracks out.
##
## Nobody on the law side sees the truth. Radars turn target signatures into
## tracks with position noise and an age; units that lose the track fly to the
## last known position. The same geometry drives the runner's radar detector
## ("painted" = a radar has line of sight to you, "locked" = it can actually
## see you above its clutter floor or through your transponder).
##
## REALISM (the Godot radar; off for the Python parity replays):
##   - 4/3-earth radar horizon: a target d away sits d^2/(2kR) lower to the beam
##   - clutter: the floor rises over a rough sea (wind) and in rain; storms also
##     shorten the range
##   - MTI: the canceller drops primary returns with little radial speed (fly
##     across a radar's beam, or slow, and you fade)
##   - scan periods: a site only looks at you once a turn (4.8 s ground, 12 s
##     aerostat); between turns the last look stands
##   - probability of detection falls off with range and radar cross-section
##     (a Twin Otter is a bigger blip than a Cherokee); the best site owns the track
##   - tracks keep a trail and Mode C altitude; the detector knows who's painting

const TRACK_TIMEOUT := 45.0
static var REALISM := true
const EARTH_R := 6371000.0
const K_FACTOR := 4.0 / 3.0
const MTI_MIN_MS := 18.0  ## ~35 kt radial: below this a primary return is cancelled as clutter
const TRAIL_LEN := 12
const RAIN_FLOOR := {"clear": 0.0, "cloud": 15.0, "storm": 60.0}
## Relative radar cross-section by aircraft (C182 = 1).
const RCS := {"c172p": 0.8, "c182": 1.0, "pa28": 0.8, "c310": 1.4, "dhc6": 2.2}
static var AEROSTAT_POS := [1500.0, -14800.0]  ## per map (World.use_layout)


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
	var code := "1200"  ## the 4-digit transponder code (Mode A)
	var rcs := 1.0

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
	var period_s := 4.8  ## one antenna turn
	var next_scan := 0.0
	var phase := 0.0  ## deg, where the beam points at t = 0

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

	## The beam's bearing (deg from north) at time t, for the scope.
	func beam(t: float) -> float:
		return fposmod(phase + t / period_s * 360.0, 360.0)

	## Radar horizon: how far below the beam's straight line the earth drops at d.
	static func horizon_drop(d: float) -> float:
		return d * d / (2.0 * K_FACTOR * EARTH_R)

	## The realistic look: [painted, can_detect, probability of detection].
	func check_real(world: World, sig: Signature, wx: Dictionary) -> Array:
		if not active or sig.kind != "air":
			return [false, false, 0.0]
		var d := PyMath.hypot(sig.x - x, sig.y - y)
		var sky: String = wx.get("sky", "clear")
		var reach := range_m * (0.85 if sky == "storm" else 1.0)
		if d > reach:
			return [false, false, 0.0]
		var drop := horizon_drop(d)
		if not world.line_of_sight([x, y, mast_z], [sig.x, sig.y, sig.z - drop], 250.0):
			return [false, false, 0.0]
		if sig.transponder:
			return [true, true, 1.0]  # secondary radar: the transponder answers
		var wind: float = wx.get("wind_kt", 8.0)
		var base := floor_base * ((0.6 + 0.04 * wind) if world.is_water(sig.x, sig.y) else 1.0)
		var floor_ := base + d * floor_per_m + float(RAIN_FLOOR.get(sky, 0.0))
		if sig.agl - drop < floor_:
			return [true, false, 0.0]
		var radial := absf(sig.vx * (sig.x - x) + sig.vy * (sig.y - y)) / maxf(d, 1.0)
		if radial < MTI_MIN_MS and d > 600.0:
			return [true, false, 0.0]  # the MTI notch: crossing the beam, or too slow
		var r50 := reach * 0.9 * pow(sig.rcs, 0.25)
		var pd := 1.0 / (1.0 + pow(d / r50, 8.0))
		return [true, pd > 0.02, pd]


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
	var code = null  ## Mode A code, transponder only
	var alt = null  ## Mode C altitude (m MSL), transponder only
	var trail: Array = []  ## [[x, y], ...] oldest first (REALISM)
	var first_t := 0.0

	func age(now: float) -> float:
		return now - t

	func predicted(now: float, max_s := 20.0) -> Array:
		var dt := minf(max_s, age(now))
		return [x + vx * dt, y + vy * dt]


class Detection:
	var painted_by: Array = []
	var detected_by: Array = []
	var painters: Array = []  ## REALISM: {code, kind, bearing (from you to the site), locked}

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
var weather := {"sky": "clear", "wind_kt": 8.0}
var xrng: PyRandom  ## REALISM draws (Pd), its own stream so the parity stream never moves
var _last := {}  ## site code -> {signature id: [painted, detected]} from its last turn


func _init(world_: World, rng_: PyRandom = null) -> void:
	world = world_
	if rng_ == null:
		rng_ = PyRandom.new()
		rng_.seed(0)
	rng = rng_
	xrng = PyRandom.new()
	xrng.seed(4242)
	sites = default_sites(world)
	for st in sites:
		if st.kind == "aerostat":
			st.period_s = 12.0
		# stagger the antennas so they don't all look at once
		st.phase = fposmod(float(st.code.hash() % 360), 360.0)
		st.next_scan = st.phase / 360.0 * st.period_s


func site(code: String) -> RadarSite:
	for s in sites:
		if s.code == code:
			return s
	return null


func sweep(sigs: Array, now: float) -> Dictionary:
	if REALISM:
		return _sweep_real(sigs, now)
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


func _sweep_real(sigs: Array, now: float) -> Dictionary:
	var out := {}
	var turning := sites.filter(func(st): return now >= st.next_scan - 1e-6)
	for sig in sigs:
		var det := Detection.new()
		var best: RadarSite = null
		var best_sigma := 1e12
		for st in sites:
			var mem: Dictionary = _last.get(st.code, {})
			var r: Array = mem.get(sig.id, [false, false])
			if turning.has(st):
				var look: Array = st.check_real(world, sig, weather)
				var hit: bool = look[1] and xrng.random() < look[2]
				r = [look[0], hit]
				mem[sig.id] = r
				_last[st.code] = mem
				if hit:
					var sigma := 40.0 + 0.004 * PyMath.hypot(sig.x - st.x, sig.y - st.y)
					if sigma < best_sigma:
						best_sigma = sigma
						best = st
			if r[0]:
				det.painted_by.append(st.code)
				det.painters.append({"code": st.code, "kind": st.kind, "locked": r[1],
					"bearing": fposmod(rad_to_deg(atan2(st.x - sig.x, st.y - sig.y)), 360.0)})
			if r[1]:
				det.detected_by.append(st.code)
		if best != null:
			report(sig, now, best.code, best_sigma)
		out[sig.id] = det
	for st in turning:
		st.next_scan = now + st.period_s
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
	if REALISM:
		tr.code = sig.code if sig.transponder else null
		tr.alt = sig.z if sig.transponder else null
		tr.trail = (prev.trail if prev else []) + [[tr.x, tr.y]]
		if tr.trail.size() > TRAIL_LEN:
			tr.trail = tr.trail.slice(-TRAIL_LEN)
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
	if prev:
		tr.trail = prev.trail
	tracks[target_id] = tr
	return tr


## Coverage for the scope: which cells of an n x n grid this site sees at `agl` m
## above the ground (radar horizon and terrain, no clutter). Cached per site/agl.
var _coverage := {}


func coverage(code: String, agl: float, n := 48) -> PackedByteArray:
	var key := "%s/%d/%d" % [code, int(agl), n]
	if _coverage.has(key):
		return _coverage[key]
	var st := site(code)
	var out := PackedByteArray()
	out.resize(n * n)
	var cell := 2.0 * World.HALF / n
	for j in n:
		for i in n:
			var x := -World.HALF + (i + 0.5) * cell
			var y := World.HALF - (j + 0.5) * cell
			var d := PyMath.hypot(x - st.x, y - st.y)
			var z := world.ground(x, y) + agl - SensorNet.RadarSite.horizon_drop(d)
			out[j * n + i] = 1 if d <= st.range_m and world.line_of_sight([st.x, st.y, st.mast_z], [x, y, z], 400.0) else 0
	_coverage[key] = out
	return out


func expire(now: float) -> void:
	for tid in tracks.keys():
		if tracks[tid].age(now) > TRACK_TIMEOUT:
			tracks.erase(tid)
