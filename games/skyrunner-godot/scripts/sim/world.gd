class_name World
extends RefCounted
## Procedural island, airfields, obstacles and terrain queries.
##
## Deterministic from a seed so renderer, physics and tests all see the same
## world. The grid generation and the hot queries run natively (Terrain); the
## airfield list here is the single source of truth. Worlds are immutable, so
## every Session in a process shares one terrain per seed.

const SIZE_M := 32000.0
const GRID := 513
const CELL := SIZE_M / (GRID - 1)
const HALF := SIZE_M / 2

static var AIRFIELDS: Array = _make_airfields()
static var AIRFIELD_BY_CODE: Dictionary = _by_code()
static var _terrain_cache := {}

var seed: int
var airfields: Array = AIRFIELDS
var terrain: Terrain
var field_elev: Dictionary


static func _make_airfields() -> Array:
	return [
		Airfield.new("HAR", "Port Harbor Intl", -9000, -9500, 70, 1800, 45, 8.0, "asphalt", "hub",
			{"shop": true, "police": true, "radar_km": 22.0}),
		Airfield.new("VAL", "Valley Regional", 2500, -3000, 20, 1000, 30, null, "asphalt", "regional",
			{"shop": true, "police": true, "radar_km": 12.0}),
		Airfield.new("FRM", "Miller's Farm", -6500, -1500, 110, 480, 20, null, "grass", "bush"),
		Airfield.new("PNR", "Pine Ridge", 10000, 8500, 225, 380, 15, null, "gravel", "bush", {"tree_lines": true}),
		Airfield.new("EGL", "Eagle's Nest", 1000, 9000, 250, 280, 14, 1150.0, "dirt", "bush", {"setting": "plateau"}),
		Airfield.new("COV", "Smuggler's Cove", 11500, -8000, 10, 320, 18, 3.0, "sand", "shady", {"setting": "beach"}),
		Airfield.new("QRY", "Old Quarry", -10000, 5500, 160, 240, 12, null, "dirt", "shady",
			{"setting": "pit", "haul_road": 0}),
		Airfield.new("ISL", "Isla Verde", 12800, 11500, 300, 550, 20, 12.0, "grass", "regional"),
	]


static func _by_code() -> Dictionary:
	var d := {}
	for a in AIRFIELDS:
		d[a.code] = a
	return d


static func airfield(code: String) -> Airfield:
	return AIRFIELD_BY_CODE[code]


func _init(p_seed := 7) -> void:
	seed = p_seed
	if not _terrain_cache.has(seed):
		var t := Terrain.new()
		var dicts := []
		for a in AIRFIELDS:
			dicts.append(a.to_dict())
		t.generate(seed, dicts)
		_terrain_cache[seed] = t
	terrain = _terrain_cache[seed]
	field_elev = terrain.get_field_elev()


## Terrain height (may be negative: sea floor).
func height(x: float, y: float) -> float:
	return terrain.height(x, y)


## Surface an aircraft can touch: runway, terrain or sea level.
func ground(x: float, y: float) -> float:
	for af in airfields:
		if af.contains(x, y, 8.0):
			return field_elev[af.code]
	return maxf(terrain.height(x, y), 0.0)


func is_water(x: float, y: float) -> bool:
	return terrain.height(x, y) < 0.0


func airfield_at(x: float, y: float, margin := 0.0) -> Airfield:
	for af in airfields:
		if af.contains(x, y, margin):
			return af
	return null


func airfield_elev(af: Airfield) -> float:
	return field_elev[af.code]


## [airfield, distance m]
func nearest_airfield(x: float, y: float) -> Array:
	var best: Airfield = null
	var bd := INF
	for a in airfields:
		var d2: float = (a.x - x) ** 2 + (a.y - y) ** 2
		if d2 < bd:
			bd = d2
			best = a
	return [best, sqrt(bd)]


func tree_hit(x: float, y: float, z: float, radius := 5.0) -> bool:
	return terrain.tree_hit(x, y, z, radius)


## Highest thing to hit near (x, y): terrain/sea surface or a tree top.
func obstacle_top(x: float, y: float, radius := 30.0) -> float:
	return terrain.tree_top(x, y, radius, ground(x, y))


func heights_many(xs: PackedFloat64Array, ys: PackedFloat64Array) -> PackedFloat64Array:
	return terrain.heights_many(xs, ys)


func line_of_sight(a: Array, b: Array, step := 200.0) -> bool:
	return terrain.line_of_sight(a[0], a[1], a[2], b[0], b[1], b[2], step)


func tree_count() -> int:
	return terrain.tree_count()
