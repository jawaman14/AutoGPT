class_name MapCity
extends RefCounted
## "Costa Brava": a hand-designed coast with a port city, the default map.
##
##   south coast  the port city of San Telmo: a street grid, the docks and a
##                harbour basin, the international airport (HAR) on reclaimed
##                land west of town, the coastal highway
##   west         the Rio Negro and its estuary: mangroves, swamp, a sand bar
##                strip (MGR)
##   centre       the farm plain: fields, hedgerows, the farm strip (FRM) and
##                the regional airport (VAL)
##   north        a jungle-covered range: the mesa strip (EGL), the ridge
##                strip (PNR), a jungle camp
##   east         dry scrub hills and the old quarry (QRY)
##   south-east   the smugglers' cove (COV) and the cays offshore (ISL)
##
## The native generator grows the relief from lobes and ridges; `post` then
## carves the river and the harbour, levels the city, the swamp and the plain,
## classifies every terrain cell (`land_use`), replants the trees by biome and
## adds the buildings as obstacles, so what's drawn is what you hit. The HQ
## zones keep their rule names: west = the plain, estuary and quarry; north =
## the jungle; sea = the cove and the cays.

const SEED := 100000  ## the map seed that means this map (0 = classic, others generated)
const TERRAIN_SEED := 4711

enum {SEA, BEACH, MANGROVE, SWAMP, FARM, GRASS, JUNGLE, SCRUB, ROCK, URBAN, PORT, ROAD}
## Map/vertex tint per class and how strongly it replaces the height-based colour.
const TINT := {BEACH: [Color(0.84, 0.78, 0.56), 0.7], MANGROVE: [Color(0.16, 0.30, 0.16), 0.8], SWAMP: [Color(0.33, 0.36, 0.22), 0.8],
	FARM: [Color(0.52, 0.55, 0.26), 0.75], JUNGLE: [Color(0.10, 0.26, 0.10), 0.7], SCRUB: [Color(0.55, 0.50, 0.33), 0.65],
	URBAN: [Color(0.60, 0.57, 0.53), 0.9], PORT: [Color(0.50, 0.50, 0.50), 0.95], ROAD: [Color(0.30, 0.30, 0.31), 0.0]}
const CLASS_NAMES := ["sea", "beach", "mangrove", "swamp", "farmland", "grass", "jungle", "scrub", "rock", "urban",
	"port", "road"]

const CITY_C := Vector2(-1200.0, -10050.0)
const CITY_R := Vector2(3400.0, 1650.0)
const COAST_Y := -11350.0  ## the waterfront
const HARBOUR_X := Vector2(-2700.0, 700.0)  ## the basin between the quays
const PLAIN_C := Vector2(-5400.0, -10000.0)  ## the coastal plain from the airport to town
const PLAIN_R := Vector2(5000.0, 1500.0)
const COVE_C := Vector2(11600.0, -9300.0)  ## the cove's sandy lowland
const COVE_R := Vector2(2600.0, 2100.0)
const ESTUARY_C := Vector2(-11600.0, -6600.0)
const ESTUARY_R := Vector2(4300.0, 5200.0)
const ORG_AT := Vector2(-1500.0, -9700.0)  ## the nightclub, downtown
const LAW_AT := Vector2(950.0, -11170.0)  ## the customs house, on the docks east of the basin
const FARM_C := Vector2(1500.0, -3600.0)
const FARM_R := Vector2(6200.0, 3400.0)
const RIVER := [[-3200.0, 5200.0], [-4300.0, 2600.0], [-6600.0, 200.0], [-8600.0, -2800.0], [-10400.0, -5600.0],
	[-12400.0, -8400.0], [-14200.0, -10300.0], [-15600.0, -11600.0]]

## Roads: the coastal highway, the north road through the plain, the east road
## to the quarry, and the estuary track.
const ROADS := [
	[[-8600.0, -9750.0], [-6200.0, -9900.0], [-4600.0, -10150.0], [-1200.0, -10150.0], [2200.0, -10000.0],
		[4800.0, -9300.0], [7800.0, -8700.0], [10300.0, -8900.0]],
	[[-1000.0, -9900.0], [-900.0, -7600.0], [-400.0, -5600.0], [-900.0, -3400.0], [-1600.0, -1200.0],
		[-1900.0, 1400.0], [-900.0, 3800.0], [1200.0, 6200.0], [1600.0, 7600.0]],
	[[2200.0, -10000.0], [2900.0, -7400.0], [4600.0, -5400.0], [7300.0, -2600.0], [9100.0, -300.0], [9800.0, 800.0]],
	[[-6200.0, -9900.0], [-7800.0, -8600.0], [-9900.0, -7400.0], [-11700.0, -8000.0]],
	[[-900.0, -3400.0], [-4200.0, 2200.0], [-5600.0, 5600.0]],
]

## The organisation's stash houses: where a load goes after it lands. Each
## has the strip it's trucked from and an HQ zone for the season's rules.
const STASHES := [
	{"id": "barn", "name": "Finca Morales barn", "kind": "barn", "x": -700.0, "y": -3350.0, "strip": "FRM", "zone": "west"},
	{"id": "shack", "name": "Mangrove shack", "kind": "shack", "x": -11200.0, "y": -8350.0, "strip": "MGR", "zone": "west"},
	{"id": "docks", "name": "Warehouse 7, the docks", "kind": "warehouse", "x": -1700.0, "y": -10950.0, "strip": "HAR", "zone": "sea"},
	{"id": "lockup", "name": "Lock-up, Barrio Chino", "kind": "lockup", "x": 1500.0, "y": -9500.0, "strip": "VAL", "zone": "west"},
	{"id": "camp", "name": "Jungle camp", "kind": "camp", "x": 1500.0, "y": 7450.0, "strip": "PNR", "zone": "north"},
	{"id": "quarry", "name": "Quarry shed", "kind": "shed", "x": 9750.0, "y": 650.0, "strip": "QRY", "zone": "west"},
	{"id": "boathouse", "name": "Cay boathouse", "kind": "boathouse", "x": 13350.0, "y": -12700.0, "strip": "ISL", "zone": "sea"},
	{"id": "villa", "name": "Hillside villa", "kind": "villa", "x": -5500.0, "y": 5500.0, "strip": "EGL", "zone": "north"},
]


static func _params() -> Dictionary:
	return {
		"lobes": [[0.0, 300.0, 14300.0, 11700.0], [9800.0, -7600.0, 5200.0, 4200.0], [-10800.0, -6400.0, 5200.0, 6000.0],
			[-8200.0, -10000.0, 3200.0, 1700.0]],
		"ridges": [[-13000.0, 8200.0, -2500.0, 9400.0, 3000.0, 1750.0], [-2500.0, 9400.0, 10500.0, 8600.0, 2800.0, 1100.0],
			[8200.0, 4200.0, 12400.0, -2200.0, 2200.0, 520.0]],
		"islets": [[13200.0, -13300.0, 1500.0, 9.0], [10200.0, -14600.0, 700.0, 12.0], [15200.0, -10800.0, 600.0, 10.0]],
		"base": 0.8,
		"centre": [0.0, 0.0],
	}


## The strips: hand-sited, then nudged to the best-rated spot within `jitter` m
## whose ground lies in the elevation band. The mesa strip must be the highest
## thing on the map: the native levelling caps all terrain beyond a plateau
## strip at 180 m below it.
## [code, name, x, y, heading, length, width, elev, surface, kind, opts, setting for rating, jitter, [zmin, zmax]]
static func _strip_specs() -> Array:
	return [
		["HAR", "San Telmo Intl", -8500.0, -10150.0, 80.0, 1800.0, 45.0, 6.0, "asphalt", "hub",
			{"shop": true, "police": true, "radar_km": 22.0}, "flat", 500.0, [-100.0, 100.0]],
		["VAL", "Valle Verde", 5600.0, -4700.0, 30.0, 1000.0, 30.0, null, "asphalt", "regional",
			{"shop": true, "police": true, "radar_km": 12.0}, "flat", 900.0, [15.0, 260.0]],
		["FRM", "Finca Morales", -1500.0, -2600.0, 0.0, 480.0, 20.0, null, "grass", "bush", {}, "flat", 700.0, [15.0, 260.0]],
		["MGR", "Barra del Rio", -12600.0, -9400.0, 60.0, 340.0, 18.0, 3.0, "sand", "shady", {"setting": "beach"}, "beach", 700.0,
			[0.5, 20.0]],
		["QRY", "Old Quarry", 10500.0, 1700.0, 0.0, 240.0, 12.0, null, "dirt", "shady",
			{"setting": "pit", "haul_road": 0}, "pit", 1400.0, [120.0, 600.0]],
		["EGL", "Mesa del Aguila", -7500.0, 8800.0, 90.0, 280.0, 14.0, null, "dirt", "bush", {"setting": "plateau"}, "plateau", 3500.0,
			[950.0, 1600.0]],
		["PNR", "La Selva", 4700.0, 8200.0, 90.0, 380.0, 15.0, null, "gravel", "bush", {"tree_lines": true}, "flat", 1800.0,
			[150.0, 650.0]],
		["COV", "Smuggler's Cove", 11600.0, -9300.0, 40.0, 320.0, 18.0, 3.0, "sand", "shady", {"setting": "beach"}, "beach", 1600.0,
			[0.5, 20.0]],
		["ISL", "Cayo Largo", 13200.0, -13300.0, 70.0, 550.0, 20.0, 12.0, "grass", "regional", {}, "flat", 0.0, [-100.0, 100.0]],
	]


## The map: the strips sited on the relief (after the post-pass shaping) and
## the zones, aerostat and stash houses. The HQs are sited by `site_hqs`.
static func generate() -> MapLayout:
	var l := MapLayout.new()
	l.id = "city"
	l.map_seed = SEED
	l.terrain_seed = TERRAIN_SEED
	l.params = _params()
	l.post = true
	var base := Terrain.new()
	base.generate_custom(TERRAIN_SEED, l.params, [])
	var h := base.get_heights()
	_shape(h, [])
	base.set_data(h, PackedFloat32Array(), [])
	var rng := PyRandom.new()
	rng.seed(SEED)
	var placed := []
	for s in _strip_specs():
		var x: float = s[2]
		var y: float = s[3]
		var hdg: float = s[4]
		var elev = s[7]
		if s[12] > 0:
			# the pit's graded exit is cut along the runway axis without end: it must run out to sea, east
			var hdgs := [70.0, 80.0, 90.0, 100.0, 110.0] if s[11] == "pit" else []
			var best := MapGen._rate(base, x, y, s[5], s[6], s[11], -200.0 if s[7] != null else 1.5,
				s[7] if s[7] != null else (base.height64(x, y) if s[11] == "plateau" else null), hdgs)
			var z0 := base.height64(x, y)
			var at := [best[0] if (z0 >= s[13][0] and z0 <= s[13][1]) else -1.0, x, y, best[1] if best[0] > 0 else hdg]
			for i in 160:
				var p := MapGen._polar(s[2], s[3], rng.uniform(0, 360), rng.uniform(0, s[12]))
				if Py.any(placed, func(a): return PyMath.hypot(a.x - p[0], a.y - p[1]) < 2800):
					continue
				var z := base.height64(p[0], p[1])
				if z < s[13][0] or z > s[13][1]:
					continue
				var r := MapGen._rate(base, p[0], p[1], s[5], s[6], s[11], -200.0 if s[7] != null else 1.5,
					s[7] if s[7] != null else (z if s[11] == "plateau" else null), hdgs)
				if r[0] > at[0]:
					at = [r[0], p[0], p[1], r[1]]
			x = at[1]
			y = at[2]
			hdg = at[3]
		if s[11] == "plateau":
			elev = snappedf(base.height64(x, y), 1.0)
		var opts: Dictionary = s[10].duplicate()
		if s[11] == "pit":
			opts["haul_road"] = 1 if sin(deg_to_rad(hdg)) > 0 else 0  # the end facing east
		placed.append(Airfield.new(s[0], s[1], x, y, hdg, s[5], s[6], elev, s[8], s[9], opts))
	l.airfields = placed
	l.zone_fields = {"west": ["FRM", "QRY", "MGR"], "north": ["EGL", "PNR"], "sea": ["COV", "ISL"]}
	l.zone_centre = {"west": [-3500.0, -3000.0], "north": [1000.0, 8500.0], "sea": [13500.0, -11500.0]}
	l.aerostat_pos = [5500.0, -13800.0]
	l.roads = ROADS.duplicate(true)
	l.stashes = STASHES.duplicate(true)
	l.foreign = [Island.airfield()]  # Isla Soberana, over the southern horizon
	return l


# ------------------------------------------------------------------ shaping
static func _xy(i: int, j: int) -> Vector2:
	return Vector2(-World.HALF + i * World.CELL, -World.HALF + j * World.CELL)


static func _ell(p: Vector2, c: Vector2, r: Vector2) -> float:
	return Vector2((p.x - c.x) / r.x, (p.y - c.y) / r.y).length()


## Value noise in [0, 1] (three octaves, 2.6 km / 900 m / 350 m): ragged edges
## for the regions, so nothing on the map is a perfect ellipse.
static func _hash(ix: int, iy: int) -> float:
	var n := ((ix * 73856093) ^ (iy * 19349663)) & 0x7fffffff
	n = (n * 1103515245 + 12345) & 0x7fffffff
	n = ((n ^ (n >> 13)) * 1274126177) & 0x7fffffff
	return float((n >> 7) & 0xffff) / 65535.0


static func _vn(x: float, y: float, s: float) -> float:
	var fx := x / s
	var fy := y / s
	var ix := floori(fx)
	var iy := floori(fy)
	var tx := fx - ix
	var ty := fy - iy
	tx = tx * tx * (3.0 - 2.0 * tx)
	ty = ty * ty * (3.0 - 2.0 * ty)
	return lerpf(lerpf(_hash(ix, iy), _hash(ix + 1, iy), tx), lerpf(_hash(ix, iy + 1), _hash(ix + 1, iy + 1), tx), ty)


static var _ng := PackedFloat32Array()
const NOISE_N := 257  ## the noise is baked on a 125 m grid once and sampled bilinearly


static func noise(x: float, y: float) -> float:
	if _ng.is_empty():
		_ng.resize(NOISE_N * NOISE_N)
		var c := World.SIZE_M / (NOISE_N - 1)
		for j in NOISE_N:
			for i in NOISE_N:
				var px := -World.HALF + i * c
				var py := -World.HALF + j * c
				_ng[j * NOISE_N + i] = 0.55 * _vn(px, py, 2600.0) + 0.3 * _vn(px + 7000.0, py, 900.0) + 0.15 * _vn(px, py + 3000.0, 350.0)
	var fx := clampf((x + World.HALF) / World.SIZE_M * (NOISE_N - 1), 0.0, NOISE_N - 1.001)
	var fy := clampf((y + World.HALF) / World.SIZE_M * (NOISE_N - 1), 0.0, NOISE_N - 1.001)
	var i := int(fx)
	var j := int(fy)
	var tx := fx - i
	var ty := fy - j
	var k := j * NOISE_N + i
	return lerpf(lerpf(_ng[k], _ng[k + 1], tx), lerpf(_ng[k + NOISE_N], _ng[k + NOISE_N + 1], tx), ty)


## A farm field's shade (fields are ~400 x 300 m, rotated a little per field).
static func field_shade(x: float, y: float) -> float:
	return _hash(floori(x / 400.0), floori(y / 300.0))


## A region's elliptical radius with a ragged edge (`amt` of noise).
static func _eln(p: Vector2, c: Vector2, r: Vector2, amt := 0.3) -> float:
	return _ell(p, c, r) + (noise(p.x, p.y) - 0.5) * amt


## The river's course: the control points smoothed (Catmull-Rom) and made to
## meander, then rasterised once into a distance field on the terrain grid.
static var _riv_d := PackedFloat32Array()
static var _riv_t := PackedFloat32Array()
const RIVER_REACH := 1200.0


static func river_course() -> PackedVector2Array:
	var pts := PackedVector2Array()
	var n := RIVER.size()
	for k in n - 1:
		var p0 := Vector2(RIVER[maxi(k - 1, 0)][0], RIVER[maxi(k - 1, 0)][1])
		var p1 := Vector2(RIVER[k][0], RIVER[k][1])
		var p2 := Vector2(RIVER[k + 1][0], RIVER[k + 1][1])
		var p3 := Vector2(RIVER[mini(k + 2, n - 1)][0], RIVER[mini(k + 2, n - 1)][1])
		var steps := int(p1.distance_to(p2) / 60.0) + 1
		for q in steps:
			var t := float(q) / steps
			var t2 := t * t
			var t3 := t2 * t
			pts.append(0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3))
	pts.append(Vector2(RIVER[n - 1][0], RIVER[n - 1][1]))
	# meanders: a lateral wiggle that fades out at the source
	var out := PackedVector2Array()
	var run := 0.0
	for k in pts.size():
		if k > 0:
			run += pts[k].distance_to(pts[k - 1])
		var dir := (pts[mini(k + 1, pts.size() - 1)] - pts[maxi(k - 1, 0)]).normalized()
		var side := Vector2(-dir.y, dir.x)
		var amp := minf(1.0, run / 2500.0)
		out.append(pts[k] + side * amp * (300.0 * sin(run / 1900.0 * TAU) + 110.0 * sin(run / 640.0 * TAU + 1.3)))
	return out


static func _river_field() -> void:
	if not _riv_d.is_empty():
		return
	var G := World.GRID
	_riv_d.resize(G * G)
	_riv_d.fill(1e9)
	_riv_t.resize(G * G)
	var c := river_course()
	var total := 0.0
	for k in c.size() - 1:
		total += c[k].distance_to(c[k + 1])
	var run := 0.0
	var span := int(RIVER_REACH / World.CELL) + 1
	for k in c.size() - 1:
		var a := c[k]
		var b := c[k + 1]
		var seg := a.distance_to(b)
		var ci := int((a.x + World.HALF) / World.CELL)
		var cj := int((a.y + World.HALF) / World.CELL)
		for j in range(maxi(0, cj - span), mini(G, cj + span + 1)):
			for i in range(maxi(0, ci - span), mini(G, ci + span + 1)):
				var p := _xy(i, j)
				var t := clampf((p - a).dot(b - a) / maxf(1.0, seg * seg), 0.0, 1.0)
				var d := p.distance_to(a + (b - a) * t)
				if d < _riv_d[j * G + i]:
					_riv_d[j * G + i] = d
					_riv_t[j * G + i] = (run + t * seg) / total
		run += seg


## [distance to the river's centre line, fraction along it (0 source, 1 mouth)]
static func _river(p: Vector2) -> Array:
	_river_field()
	var G := World.GRID
	var fx := clampf((p.x + World.HALF) / World.CELL, 0.0, G - 1.001)
	var fy := clampf((p.y + World.HALF) / World.CELL, 0.0, G - 1.001)
	var i := int(fx)
	var j := int(fy)
	var tx := fx - i
	var ty := fy - j
	var k := j * G + i
	var d := lerpf(lerpf(_riv_d[k], _riv_d[k + 1], tx), lerpf(_riv_d[k + G], _riv_d[k + G + 1], tx), ty)
	return [d, _riv_t[int(round(fy)) * G + int(round(fx))]]


## How free the terrain at `p` is to be reshaped: 0 on and around a strip (its
## levelling is the native generator's), 1 well clear of every strip.
static func _free(p: Vector2, fields: Array) -> float:
	var f := 1.0
	for af in fields:
		if absf(p.x - af.x) > af.length / 2 + 1000.0 or absf(p.y - af.y) > af.length / 2 + 1000.0:
			continue
		var l: Array = af.to_local(p.x, p.y)
		var along: float = absf(l[0]) - af.length / 2
		var across: float = absf(l[1]) - af.width / 2
		var d := Vector2(maxf(along, 0.0), maxf(across, 0.0)).length()
		# low coastal strips sit on ground the post-pass levels anyway: protect just the strip
		var low: bool = af.elev != null and float(af.elev) <= 15.0 and af.setting != "plateau"
		var reach := 0.0 if low else 300.0
		f = minf(f, smoothstep(reach, reach + (60.0 if low else 250.0), d))
	return f


## Reshape the height grid in place: river, estuary, city and harbour, the plain.
static func _shape(h: PackedFloat32Array, fields: Array) -> void:
	var G := World.GRID
	for j in G:
		for i in G:
			var p := _xy(i, j)
			var k := j * G + i
			var z: float = h[k]
			var free := _free(p, fields) if not fields.is_empty() else 1.0
			if free <= 0.0:
				continue
			var nz := z
			# the farm plain: the relief flattened into rolling fields
			var rf := _eln(p, FARM_C, FARM_R, 0.35)
			if rf < 1.0 and nz > 0:
				nz = lerpf(nz, 28.0 + 0.3 * nz, smoothstep(1.0, 0.65, rf) * 0.85)
			# the coastal plain: the airport's reclaimed land and the road into town
			var rp := _ell(p, PLAIN_C, PLAIN_R)
			if rp < 1.1 and nz > -8.0:
				nz = lerpf(nz, maxf(nz, 2.5) if nz < 2.5 else 4.0 + maxf(0.0, p.y + 10800.0) * 0.003, smoothstep(1.1, 0.7, rp))
			var rv2 := _ell(p, COVE_C, COVE_R)
			if rv2 < 1.0 and nz > 0:
				nz = lerpf(nz, 3.0 + 0.05 * nz, smoothstep(1.0, 0.55, rv2))
			# the estuary: low, wet ground; nothing above a few metres near the mouth
			var re := _eln(p, ESTUARY_C, ESTUARY_R, 0.4)
			if re < 1.0 and nz > 0:
				nz = lerpf(nz, 1.2 + 0.04 * nz, smoothstep(1.0, 0.55, re))
			# the city: levelled, rising gently inland; the harbour basin dredged
			var rc := _eln(p, CITY_C, CITY_R, 0.2)
			if rc < 1.15:
				var w := smoothstep(1.15, 0.8, rc)
				var target := 3.5 + maxf(0.0, p.y - COAST_Y) * 0.004
				if p.y < COAST_Y:
					target = -12.0 if (p.x > HARBOUR_X.x and p.x < HARBOUR_X.y) else 2.8
				nz = lerpf(nz, target, w)
			if p.y < COAST_Y and p.x > HARBOUR_X.x and p.x < HARBOUR_X.y:
				nz = minf(nz, -12.0)  # the channel out to sea
			# the river: a channel widening to the mouth, its valley cut into the hills
			var rv := _river(p)
			var half: float = lerpf(55.0, 420.0, rv[1] * rv[1])
			if rv[0] < minf(half + 600.0, RIVER_REACH):
				var bed: float = -2.5 - 3.0 * rv[1]
				var bank := minf(nz, 2.5 + maxf(0.0, rv[0] - half) * 0.12)
				nz = lerpf(bed, bank, smoothstep(half * 0.6, half, rv[0])) if rv[0] < half else minf(nz, bank)
			h[k] = lerpf(z, nz, free)


## Land-use class of every terrain cell (row = y index), from the shaped heights.
static func classify(h: PackedFloat32Array, fields: Array) -> PackedByteArray:
	var G := World.GRID
	var out := PackedByteArray()
	out.resize(G * G)
	for j in G:
		for i in G:
			var k := j * G + i
			var p := _xy(i, j)
			var z: float = h[k]
			var slope := 0.0
			if i > 0 and i < G - 1 and j > 0 and j < G - 1:
				slope = Vector2(h[k + 1] - h[k - 1], h[k + G] - h[k - G]).length() / (2 * World.CELL)
			var c := GRASS
			var n := noise(p.x, p.y)
			if z < 0.0:
				c = SEA
			elif _eln(p, CITY_C, CITY_R, 0.2) < 0.95 and z > 1.0:
				c = PORT if (p.y < COAST_Y + 650 and p.x > HARBOUR_X.x - 400 and p.x < HARBOUR_X.y + 400) else URBAN
			elif _eln(p, ESTUARY_C, ESTUARY_R, 0.4) < 1.05 and z < 9.0:
				c = MANGROVE if (z < 2.2 or _river(p)[0] < 350.0 + 700.0 * n) else SWAMP
			elif z < 3.0:
				c = BEACH
			elif slope > 0.55 or z > 950:
				c = ROCK
			elif _eln(p, FARM_C, FARM_R, 0.35) < 0.95 and slope < 0.14:
				c = FARM
			elif p.y > 1800.0 + 3000.0 * (n - 0.5) and z > 60.0 + 90.0 * n:
				c = JUNGLE
			elif p.x > 6300.0 + 3000.0 * (n - 0.5) and p.y > -6800.0 + 2000.0 * (n - 0.5) and p.y < 5200.0:
				c = SCRUB
			elif _river(p)[0] < 220.0 + 200.0 * n and z < 60.0:
				c = SWAMP  # the river's wet margins
			out[k] = c
	for af in fields:  # strips count as roads (paved or graded)
		var r: float = af.length / 2 + 40.0
		for j in range(maxi(0, int((af.y - r + World.HALF) / World.CELL)), mini(G, int((af.y + r + World.HALF) / World.CELL) + 2)):
			for i in range(maxi(0, int((af.x - r + World.HALF) / World.CELL)), mini(G, int((af.x + r + World.HALF) / World.CELL) + 2)):
				if af.contains(_xy(i, j).x, _xy(i, j).y, 20.0):
					out[j * G + i] = ROAD
	return out


static func at(lu: PackedByteArray, x: float, y: float) -> int:
	var i := clampi(int(round((x + World.HALF) / World.CELL)), 0, World.GRID - 1)
	var j := clampi(int(round((y + World.HALF) / World.CELL)), 0, World.GRID - 1)
	return lu[j * World.GRID + i]


## Distance from (x, y) to the nearest road centre line.
static func road_dist(roads: Array, x: float, y: float) -> float:
	var best := 1e18
	var p := Vector2(x, y)
	for r in roads:
		for k in r.size() - 1:
			var a := Vector2(r[k][0], r[k][1])
			var b := Vector2(r[k + 1][0], r[k + 1][1])
			var t := clampf((p - a).dot(b - a) / maxf(1.0, (b - a).length_squared()), 0.0, 1.0)
			best = minf(best, p.distance_to(a + (b - a) * t))
	return best


const MASK_N := 1024  ## road mask resolution (31 m cells)


## Cells within ~30-45 m of a road (a 1024 x 1024 mask): no trees there.
static func road_mask(roads: Array) -> PackedByteArray:
	var m := PackedByteArray()
	m.resize(MASK_N * MASK_N)
	var cell := World.SIZE_M / MASK_N
	for r in roads:
		for k in r.size() - 1:
			var a := Vector2(r[k][0], r[k][1])
			var b := Vector2(r[k + 1][0], r[k + 1][1])
			var n := int(a.distance_to(b) / 10.0) + 1
			for s in n + 1:
				var p := a.lerp(b, float(s) / n)
				var ci := int((p.x + World.HALF) / cell)
				var cj := int((p.y + World.HALF) / cell)
				for dj in [-1, 0, 1]:
					for di in [-1, 0, 1]:
						if ci + di >= 0 and ci + di < MASK_N and cj + dj >= 0 and cj + dj < MASK_N:
							m[(cj + dj) * MASK_N + ci + di] = 1
	return m


static func on_road(mask: PackedByteArray, x: float, y: float) -> bool:
	var cell := World.SIZE_M / MASK_N
	var ci := clampi(int((x + World.HALF) / cell), 0, MASK_N - 1)
	var cj := clampi(int((y + World.HALF) / cell), 0, MASK_N - 1)
	return mask[cj * MASK_N + ci] == 1


# ------------------------------------------------------------------ the post-pass
## Reshape `t` (the native terrain with the strips levelled), classify it,
## replant the trees and add the buildings. Called once per process by World.
static func post(t: Terrain, l: MapLayout) -> void:
	var dicts := []
	for a in l.airfields:
		dicts.append(a.to_dict())
	var h := t.get_heights()
	_shape(h, l.airfields)
	var lu := classify(h, l.airfields)
	l.land_use = lu
	var probe := Terrain.new()
	probe.set_data(h, PackedFloat32Array(), dicts)
	l.buildings = _city(probe, l)
	var trees := _plant(probe, t.get_trees(), l)
	for b in l.buildings:
		# a building is a cluster of obstacle points over its footprint (Terrain.tree_hit)
		var nx := maxi(1, int(ceil(b.w / 14.0)))
		var ny := maxi(1, int(ceil(b.d / 14.0)))
		for a in nx:
			for c in ny:
				var ox: float = (a + 0.5) / nx * b.w - b.w / 2
				var oy: float = (c + 0.5) / ny * b.d - b.d / 2
				trees.append_array([b.x + ox, b.y + oy, b.z, b.h])
	t.set_data(h, trees, dicts)


## Trees by biome: the native forest thinned where there are fields, streets
## and beaches; mangroves in the estuary; the jungle made dense.
static func _plant(t: Terrain, native: PackedFloat32Array, l: MapLayout) -> PackedFloat32Array:
	var lu := l.land_use
	var out := PackedFloat32Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = TERRAIN_SEED
	var keep_frac := {GRASS: 1.0, JUNGLE: 1.0, SCRUB: 0.35, FARM: 0.08, SWAMP: 0.5}
	var mask := road_mask(l.roads)
	var ok := func(x: float, y: float) -> bool:
		if MapCity.on_road(mask, x, y):
			return false
		for af in l.airfields:
			if absf(x - af.x) < af.length and absf(y - af.y) < af.length and af.contains(x, y, 45.0):
				return false
		return true
	for k in native.size() / 4:
		var x: float = native[k * 4]
		var y: float = native[k * 4 + 1]
		var c := at(lu, x, y)
		if rng.randf() >= float(keep_frac.get(c, 0.0)) or not ok.call(x, y):
			continue
		out.append_array([x, y, t.height64(x, y), native[k * 4 + 3]])
	var add := func(cls: int, n: int, hmin: float, hmax: float) -> void:
		for i in n:
			var x := rng.randf_range(-World.HALF, World.HALF)
			var y := rng.randf_range(-World.HALF, World.HALF)
			if at(lu, x, y) != cls or not ok.call(x, y):
				continue
			var z := t.height64(x, y)
			if z < 0.3:
				continue
			out.append_array([x, y, z, rng.randf_range(hmin, hmax)])
	add.call(JUNGLE, 90000, 14.0, 26.0)
	add.call(MANGROVE, 200000, 5.0, 9.0)
	add.call(SWAMP, 12000, 7.0, 13.0)
	# hedgerows: a line of trees on some field edges (every 400 m grid line)
	for gx in range(-12000, 12001, 400):
		for gy in range(-12000, 12001, 25):
			if rng.randf() < 0.35 and at(lu, gx, gy) == FARM and ok.call(float(gx), float(gy)):
				out.append_array([float(gx), float(gy), t.height64(gx, gy), rng.randf_range(8.0, 13.0)])
	return out


## The city: a street grid of blocks, the buildings on them (taller downtown),
## and warehouses and cranes on the docks. Heights are capped under every
## strip's approach so no tower stands in a glide path.
## Each: {x, y, z, w, d, h, style} (style: res | shop | tower | warehouse | crane)
static func _city(t: Terrain, l: MapLayout) -> Array:
	var out := []
	var lu := l.land_use
	var rng := RandomNumberGenerator.new()
	rng.seed = TERRAIN_SEED + 1
	var street := 14.0
	var block := 110.0
	var bx := CITY_C.x - CITY_R.x
	while bx < CITY_C.x + CITY_R.x:
		var by := CITY_C.y - CITY_R.y
		while by < CITY_C.y + CITY_R.y:
			var cx := bx + block / 2
			var cy := by + block / 2
			var cls := at(lu, cx, cy)
			if cls == URBAN:
				var r := _ell(Vector2(cx, cy), CITY_C, CITY_R)
				var down := clampf(1.0 - r, 0.0, 1.0)
				var lots := 2 if down > 0.55 else 3
				var lot := (block - street) / lots
				for a in lots:
					for b in lots:
						if rng.randf() < 0.12:
							continue  # a yard, a plaza, a vacant lot
						var x := bx + street / 2 + (a + 0.5) * lot
						var y := by + street / 2 + (b + 0.5) * lot
						var z := t.height64(x, y)
						if z < 1.0 or at(lu, x, y) != URBAN:
							continue
						if Vector2(x, y).distance_to(ORG_AT) < 70.0 or Vector2(x, y).distance_to(LAW_AT) < 70.0:
							continue  # the nightclub's and the customs house's plots
						if road_dist(l.roads, x, y) < lot / 2 + 12.0:
							continue  # the highway runs through town
						var tall := 6.0 + rng.randf() * (6.0 + 50.0 * down * down)
						var style := "tower" if tall > 26 else ("shop" if rng.randf() < 0.3 else "res")
						out.append({"x": x, "y": y, "z": z, "w": lot - rng.randf_range(4, 10), "d": lot - rng.randf_range(4, 10),
							"h": tall, "style": style})
			by += block
		bx += block
	# the docks: warehouses behind the quays, cranes on the edge
	var qx := HARBOUR_X.x - 350.0
	while qx < HARBOUR_X.y + 350.0:
		for row in 2:
			var x := qx + 30
			var y := COAST_Y + 90.0 + row * 70.0
			if t.height64(x, y) > 1.0 and rng.randf() < 0.8 and Vector2(x, y).distance_to(LAW_AT) > 80.0:
				out.append({"x": x, "y": y, "z": t.height64(x, y), "w": 52.0, "d": 26.0, "h": rng.randf_range(8, 12), "style": "warehouse"})
		qx += 70.0
	for c in 5:
		var x := lerpf(HARBOUR_X.x + 200, HARBOUR_X.y - 200, c / 4.0)
		var y := COAST_Y + 22.0
		if t.height64(x, y) > 0.5:
			out.append({"x": x, "y": y, "z": t.height64(x, y), "w": 12.0, "d": 12.0, "h": 38.0, "style": "crane"})
	# nothing in a glide path: a 3-degree slope from each runway end, 1.8 km out
	var keep := []
	for b in out:
		var ok := true
		for af in l.airfields:
			var lc: Array = af.to_local(b.x, b.y)
			var beyond: float = absf(lc[0]) - af.length / 2
			if absf(lc[1]) < af.width / 2 + 90 + maxf(beyond, 0.0) * 0.2 and beyond < 1800 and beyond > -af.length / 2:
				var cap: float = maxf(beyond, 0.0) * 0.05 - 8.0
				if cap < 5.0:
					ok = false
				else:
					b.h = minf(b.h, cap)
			if af.contains(b.x, b.y, 120.0):
				ok = false
		if ok:
			keep.append(b)
	return keep


# ------------------------------------------------------------------ headquarters
## The organisation runs from a nightclub downtown (the office upstairs), the
## task force from the customs house on the docks (radar on the roof), Los
## Cuervos from a hacienda in the jungle foothills.
static func site_hqs(w: World, l: MapLayout) -> Dictionary:
	var org := [ORG_AT.x, ORG_AT.y]
	var law := [LAW_AT.x, LAW_AT.y]
	var rival := MapGen._pad(w, [4200.0, 4600.0], 0, 1500, 30.0, [org, law])
	var face := func(p: Array, target: Array) -> float:
		return fposmod(rad_to_deg(atan2(target[0] - p[0], target[1] - p[1])), 360.0)
	return {
		"org": {"kind": "org", "style": "nightclub", "name": "Club Tropicana", "x": org[0], "y": org[1],
			"heading": 180.0, "zone": "sea"},
		"law": {"kind": "law", "style": "customs", "name": "Customs House (Task Force)", "x": law[0], "y": law[1],
			"heading": 180.0, "zone": "west"},
		"rival": {"kind": "rival", "style": "hacienda", "name": "Hacienda Los Cuervos", "x": rival[0], "y": rival[1],
			"heading": face.call(rival, [1500.0, 7450.0]), "zone": "north"},
	}
