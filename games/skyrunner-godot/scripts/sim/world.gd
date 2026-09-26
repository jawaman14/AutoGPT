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

static var layout: MapLayout = MapLayout.classic()
static var AIRFIELDS: Array = layout.airfields
static var AIRFIELD_BY_CODE: Dictionary = _by_code()
static var _terrain_cache := {}
static var _layouts := {}  ## map seed -> MapLayout (the city's post-pass data lives on it)

var seed: int
var airfields: Array = AIRFIELDS
var terrain: Terrain
var field_elev: Dictionary
var map: MapLayout


## Make a map current: airfields, HQ zones, aerostat and HQ sites all follow it.
## One island per process (the balance workers and tests use the classic one).
static func use_layout(l: MapLayout) -> void:
	layout = l
	AIRFIELDS = l.airfields
	AIRFIELD_BY_CODE = _by_code()
	HQ.ZONE_CENTRE = l.zone_centre
	HQ.ZONE_FIELDS = l.zone_fields
	SensorNet.AEROSTAT_POS = l.aerostat_pos


## The map for a seed: 0 = the classic island, MapCity.SEED the city coast,
## anything else is generated.
static func use_map(map_seed: int) -> MapLayout:
	if map_seed == layout.map_seed:
		return layout
	if not _layouts.has(map_seed):
		_layouts[map_seed] = MapLayout.classic() if map_seed == 0 else (MapCity.generate() if map_seed == MapCity.SEED
			else MapGen.generate(map_seed))
	use_layout(_layouts[map_seed])
	return layout


static func _by_code() -> Dictionary:
	var d := {}
	for a in AIRFIELDS:
		d[a.code] = a
	for a in layout.foreign:
		d[a.code] = a
	return d


static func airfield(code: String) -> Airfield:
	return AIRFIELD_BY_CODE[code]


func _init(p_seed := 7) -> void:
	map = layout
	airfields = AIRFIELDS
	var generated: bool = map.params != null
	seed = map.terrain_seed if generated else p_seed
	var key := "%s/%d" % [map.id, seed]
	if not _terrain_cache.has(key):
		var t := Terrain.new()
		var dicts := []
		for a in AIRFIELDS:
			dicts.append(a.to_dict())
		if generated:
			t.generate_custom(seed, map.params, dicts)
			if map.post:
				MapCity.post(t, map)
		else:
			t.generate(seed, dicts)
		_terrain_cache[key] = t
	terrain = _terrain_cache[key]
	field_elev = terrain.get_field_elev()
	for a in map.foreign:
		field_elev[a.code] = float(a.elev)
	if map.hqs.is_empty():
		map.hqs = MapCity.site_hqs(self, map) if map.id == "city" else MapGen.site_hqs(self, map)


## Terrain height (may be negative: sea floor).
func height(x: float, y: float) -> float:
	if not map.foreign.is_empty() and y < -World.HALF:
		return Island.height(x, y)
	return terrain.height(x, y)


## Surface an aircraft can touch: runway, terrain or sea level.
func ground(x: float, y: float) -> float:
	for af in airfields:
		if af.contains(x, y, 8.0):
			return field_elev[af.code]
	if not map.foreign.is_empty() and y < -World.HALF:
		for af in map.foreign:
			if af.contains(x, y, 8.0):
				return field_elev[af.code]
		return maxf(Island.height(x, y), 0.0)  # beyond the map's edge: the island, else the sea
	return maxf(terrain.height(x, y), 0.0)


func is_water(x: float, y: float) -> bool:
	if not map.foreign.is_empty() and y < -World.HALF:
		return Island.height(x, y) < 0.0
	return terrain.height(x, y) < 0.0


func airfield_at(x: float, y: float, margin := 0.0) -> Airfield:
	for af in airfields:
		if af.contains(x, y, margin):
			return af
	for af in map.foreign:
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
