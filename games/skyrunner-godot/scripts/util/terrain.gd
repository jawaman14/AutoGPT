class_name Terrain
extends RefCounted
## The procedural island: height grid, trees and the terrain queries the
## physics, radar and bots use every frame. A line-for-line port of the Python
## world.py generator (numpy PCG64 streams, same operation order, float32 where
## numpy used float32), so seed 7 builds the island the balance numbers were
## measured on. GDScript has no float32 arithmetic: _f32() rounds each float32
## step through a one-element PackedFloat32Array.

const GRID := 513
const SIZE_M := 32000.0
const HALF := SIZE_M / 2
const CELL := SIZE_M / (GRID - 1)
const BUCKET := 250.0

var _h := PackedFloat32Array()  ## GRID*GRID, row = y index
var _trees := PackedFloat32Array()  ## N*4: x, y, base z, height
var _fields: Array = []  ## Dictionaries: code x y heading length width has_elev elev setting tree_lines haul_road ux uy
var _field_elev := {}
var _buckets := {}  ## int key -> Array of tree indices

static var _f := PackedFloat32Array([0.0])

## Generation takes ~10 s in GDScript, so a generated terrain is kept on disk,
## keyed by everything that goes into it: the built-in maps ship baked in
## res://data/terrain (tools/bake_terrain.gd), anything else is cached in
## user://terrain on first use. Bump CACHE_VERSION whenever the generator
## changes, then re-bake.
const CACHE_VERSION := 2
const BAKED_DIR := "res://data/terrain"
const CACHE_DIR := "user://terrain"
static var disk_cache := true
static var bake_to := ""  ## tools/bake_terrain.gd: write here instead of the user cache


static func _f32(x: float) -> float:
	_f[0] = x
	return _f[0]


static func _clip(v: float, lo: float, hi: float) -> float:
	return lo if v < lo else (hi if v > hi else v)


## numpy: t = clip((x - e0) / (e1 - e0), 0, 1); t * t * (3 - 2 * t)
static func _smoothstep(e0: float, e1: float, x: float) -> float:
	var t := _clip((x - e0) / (e1 - e0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## world._value_noise: bilinear, smoothstep-weighted lattice of rng.random()
static func _value_noise(rng: NpRandom, n: int, cells: int) -> PackedFloat64Array:
	var l := cells + 2
	var lat := rng.random_array(l * l)
	var idx := PackedInt32Array()
	idx.resize(n)
	var f := PackedFloat64Array()
	f.resize(n)
	var step := float(cells) / n  # linspace(0, cells, n, endpoint=False)
	for k in n:
		var t := float(k) * step + 0.0
		idx[k] = int(t)
		var ff := t - idx[k]
		f[k] = ff * ff * (3.0 - 2.0 * ff)
	var out := PackedFloat64Array()
	out.resize(n * n)
	for r in n:
		var ir: int = idx[r]
		var fy: float = f[r]
		var row_a := ir * l
		var row_b := (ir + 1) * l
		var base := r * n
		for c in n:
			var ic: int = idx[c]
			var fx: float = f[c]
			var a: float = lat[row_a + ic]
			var b: float = lat[row_a + ic + 1]
			var cc: float = lat[row_b + ic]
			var d: float = lat[row_b + ic + 1]
			out[base + c] = (a * (1.0 - fx) + b * fx) * (1.0 - fy) + (cc * (1.0 - fx) + d * fx) * fy
	return out


static func _fbm(rng: NpRandom, n: int, base_cells: int, octaves: int) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(n * n)
	out.fill(0.0)
	var amp := 1.0
	var total := 0.0
	var cells := base_cells
	for o in octaves:
		var vn := _value_noise(rng, n, cells)
		for k in out.size():
			out[k] += amp * vn[k]
		total += amp
		amp *= 0.5
		cells *= 2
	for k in out.size():
		out[k] = out[k] / total
	return out


static func _normalise(v: PackedFloat64Array) -> void:
	var lo := INF
	var hi := -INF
	for x in v:
		lo = minf(lo, x)
		hi = maxf(hi, x)
	for k in v.size():
		v[k] = (v[k] - lo) / (hi - lo)


static func _cv() -> PackedFloat64Array:
	var cv := PackedFloat64Array()
	cv.resize(GRID)
	for k in GRID:
		cv[k] = float(k) * (SIZE_M / (GRID - 1)) + (-HALF)
	cv[GRID - 1] = HALF
	return cv


static func _contains(af: Dictionary, px: float, py: float, margin: float) -> bool:
	var dx: float = px - af.x
	var dy: float = py - af.y
	var a: float = dx * af.ux + dy * af.uy
	var c: float = dx * af.uy - dy * af.ux
	return absf(a) <= af.length / 2 + margin and absf(c) <= af.width / 2 + margin


func _parse_fields(airfields: Array) -> void:
	_fields.clear()
	for d in airfields:
		var e = d.get("elev")
		var hr = d.get("haul_road")
		var h: float = float(d.heading) * PI / 180.0  # math.radians
		_fields.append({"code": str(d.code), "x": float(d.x), "y": float(d.y), "heading": float(d.heading),
			"length": float(d.length), "width": float(d.width), "has_elev": e != null, "elev": float(e) if e != null else 0.0,
			"setting": str(d.get("setting", "flat")), "tree_lines": bool(d.get("tree_lines", false)),
			"haul_road": -1 if hr == null else int(hr), "ux": sin(h), "uy": cos(h)})


static func _sample64(h: PackedFloat64Array, x: float, y: float) -> float:
	var fx := (x + HALF) / CELL
	var fy := (y + HALF) / CELL
	var i := int(_clip(fx, 0, GRID - 2))
	var j := int(_clip(fy, 0, GRID - 2))
	var tx := fx - i
	var ty := fy - j
	return h[j * GRID + i] * (1 - tx) * (1 - ty) + h[j * GRID + i + 1] * tx * (1 - ty) \
		+ h[(j + 1) * GRID + i] * (1 - tx) * ty + h[(j + 1) * GRID + i + 1] * tx * ty


func generate(p_seed: int, airfields: Array) -> void:
	var key := _cache_key(["classic", p_seed, airfields])
	if _load_cached(key, airfields):
		return
	_generate(p_seed, airfields)
	_save_cached(key)


func generate_custom(p_seed: int, params: Dictionary, airfields: Array) -> void:
	var key := _cache_key(["custom", p_seed, params, airfields])
	if _load_cached(key, airfields):
		return
	_generate_custom(p_seed, params, airfields)
	_save_cached(key)


static func _cache_key(what: Array) -> String:
	return var_to_str([CACHE_VERSION, what]).sha256_text().substr(0, 24)


func _load_cached(key: String, airfields: Array) -> bool:
	if not disk_cache:
		return false
	var f: FileAccess = null
	for dir in [BAKED_DIR, CACHE_DIR]:
		var path := "%s/%s.bin" % [dir, key]
		if FileAccess.file_exists(path):
			f = FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
			if f != null:
				break
	if f == null:
		return false
	var d = f.get_var()
	if not (d is Dictionary and d.get("v") == CACHE_VERSION):
		return false
	_parse_fields(airfields)
	_h = d.h
	_trees = d.trees
	_field_elev = d.fe
	_bucket_trees()
	return true


func _save_cached(key: String) -> void:
	if not disk_cache:
		return
	var dir := bake_to if bake_to != "" else CACHE_DIR
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open_compressed("%s/%s.bin" % [dir, key], FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	if f != null:  # a read-only user dir just means no cache
		f.store_var({"v": CACHE_VERSION, "h": _h, "trees": _trees, "fe": _field_elev})


func _generate(p_seed: int, airfields: Array) -> void:
	_parse_fields(airfields)
	_field_elev.clear()
	var cv := _cv()
	var rng := NpRandom.new()
	rng.seed(p_seed)
	var noise := _fbm(rng, GRID, 4, 7)
	_normalise(noise)
	var detail := _fbm(rng, GRID, 16, 4)
	_normalise(detail)
	var h := PackedFloat64Array()
	h.resize(GRID * GRID)
	for r in GRID:
		var yy: float = cv[r]
		for c in GRID:
			var xx: float = cv[c]
			var k := r * GRID + c
			var nz: float = noise[k]
			var dt: float = detail[k]
			var rr := PyMath.hypot(xx / 14500, yy / 13500) + (nz - 0.5) * 0.35
			var land := _smoothstep(1.02, 0.72, rr)
			var ridge_d := absf(yy - (5200 + 2200 * sin(xx / 6000.0)))
			var q := ridge_d / 3000
			var ridge := exp(-(q * q)) * (0.25 + 0.75 * nz + 0.5 * dt)
			var hv := land * (35 + 260 * nz + 120 * dt) + land * ridge * 1150
			hv = hv - (1 - land) * 60
			h[k] = hv
	_shape_fields(h)
	_plant_trees(p_seed)


func _shape_fields(h: PackedFloat64Array) -> void:
	var cv := _cv()
	# guarantee land for offshore strips
	for af in _fields:
		var amp: float = minf(30.0, af.elev + 3.0) if af.has_elev else 30.0
		var afx: float = af.x
		var afy: float = af.y
		for r in GRID:
			var dy: float = cv[r] - afy
			for c in GRID:
				var dx: float = cv[c] - afx
				var bump := exp(-((dx * dx + dy * dy) / (1400.0 * 1400.0)))
				var k := r * GRID + c
				h[k] = maxf(h[k], bump * amp - (1 - bump) * 60)
	for af in _fields:
		var elev: float = af.elev if af.has_elev else _sample64(h, af.x, af.y)
		elev = maxf(elev, 2.0)
		var half_len: float = af.length / 2
		var half_w: float = af.width / 2
		var ux: float = af.ux
		var uy: float = af.uy
		var setting: String = af.setting
		var haul: int = af.haul_road
		for r in GRID:
			var dy: float = cv[r] - af.y
			for c in GRID:
				var dx: float = cv[c] - af.x
				var k := r * GRID + c
				var lon := dx * ux + dy * uy
				var lat := dx * uy - dy * ux
				var along := absf(lon) - half_len
				var across := absf(lat) - half_w
				var dist := PyMath.hypot(maxf(along, 0.0), maxf(across, 0.0))
				var hv: float = h[k]
				if setting == "plateau":
					var top := _smoothstep(130, 80, dist)
					hv = hv * (1 - top) + elev * top if dist < 130 else minf(hv, elev - 180 * _smoothstep(130, 260, dist))
				elif setting == "pit":
					var flat := _smoothstep(110, 60, dist)
					var qa := (across - 55) / 30
					var side := exp(-(qa * qa)) * 70 * _smoothstep(90, 0, along)
					hv = hv * (1 - flat) + elev * flat + side
					if haul >= 0:
						var s_end := -1.0 if haul == 0 else 1.0
						var beyond := s_end * lon - half_len
						var cut := beyond > -20 and absf(lat) < 70 + maxf(beyond, 0.0) * 0.3
						if cut:
							hv = minf(hv, elev - maxf(beyond, 0.0) * 0.06)
				else:
					var reach := 650.0 if setting == "beach" else 260.0
					var blend := _smoothstep(reach, 50, dist)
					hv = hv * (1 - blend) + elev * blend
				h[k] = hv
		_field_elev[af.code] = elev
	_h = PackedFloat32Array()
	_h.resize(h.size())
	for k in h.size():
		_h[k] = h[k]  # float64 -> float32, round to nearest like static_cast<float>


func _plant_trees(p_seed: int) -> void:
	var trng := NpRandom.new()
	trng.seed(p_seed + 1)
	var forest := _fbm(trng, GRID, 8, 3)
	var cand := trng.uniform_array(120000, -HALF, HALF)
	var pts := PackedFloat32Array()
	for n in 60000:
		var x: float = cand[2 * n]
		var y: float = cand[2 * n + 1]
		var z := height64(x, y)
		if z < 6 or z > 1300:
			continue
		var fi := int((y + HALF) / CELL)
		var fj := int((x + HALF) / CELL)
		if forest[fi * GRID + fj] < 0.52:
			continue
		var on_field := false
		for af in _fields:
			if _contains(af, x, y, 45):
				on_field = true
				break
		if on_field:
			continue
		var th := trng.uniform(9, 20)
		pts.append_array(PackedFloat32Array([x, y, z, th]))
	# deliberate obstacles: tree lines off both ends of bush strips
	for af in _fields:
		if not af.tree_lines:
			continue
		for end in [-1, 1]:
			var d: float = af.length / 2 + 110
			for s in 13:
				var kk := float(s) * 7.5 + (-45.0)  # linspace(-45, 45, 13)
				var x: float = af.x + end * af.ux * d + af.uy * kk
				var y: float = af.y + end * af.uy * d - af.ux * kk
				pts.append_array(PackedFloat32Array([x, y, height64(x, y), 16.0]))
	_trees = pts
	_bucket_trees()


## Generative islands: the same noise stack as the classic island, but the land
## is a union of elliptical lobes, the mountains are polyline ridges and small
## islets can be scattered offshore. params:
##   lobes:  [[cx, cy, rx, ry], ...]
##   ridges: [[x0, y0, x1, y1, width, height], ...]
##   islets: [[x, y, radius, height], ...]
##   base:   float (lowland relief, default 1.0)
func _generate_custom(p_seed: int, params: Dictionary, airfields: Array) -> void:
	_parse_fields(airfields)
	_field_elev.clear()
	var cv := _cv()
	var rng := NpRandom.new()
	rng.seed(p_seed)
	var noise := _fbm(rng, GRID, 4, 7)
	_normalise(noise)
	var detail := _fbm(rng, GRID, 16, 4)
	_normalise(detail)
	var lobes: Array = params.get("lobes", [])
	var ridges: Array = params.get("ridges", [])
	var islets: Array = params.get("islets", [])
	var base: float = params.get("base", 1.0)
	var h := PackedFloat64Array()
	h.resize(GRID * GRID)
	for r in GRID:
		var yy: float = cv[r]
		for c in GRID:
			var xx: float = cv[c]
			var k := r * GRID + c
			var nz: float = noise[k]
			var dt: float = detail[k]
			var land := 0.0
			for lb in lobes:
				var rr := PyMath.hypot((xx - float(lb[0])) / float(lb[2]), (yy - float(lb[1])) / float(lb[3])) + (nz - 0.5) * 0.35
				land = maxf(land, _smoothstep(1.02, 0.72, rr))
			var mount := 0.0
			for rg in ridges:
				var x0: float = rg[0]
				var y0: float = rg[1]
				var vx: float = float(rg[2]) - x0
				var vy: float = float(rg[3]) - y0
				var len2 := maxf(1.0, vx * vx + vy * vy)
				var t := _clip(((xx - x0) * vx + (yy - y0) * vy) / len2, 0.0, 1.0)
				var d := PyMath.hypot(xx - (x0 + t * vx), yy - (y0 + t * vy))
				var q := d / float(rg[4])
				# taper at the ends so ridges don't stop in a wall
				var taper := _smoothstep(0.0, 0.15, t) * _smoothstep(1.0, 0.85, t)
				mount = maxf(mount, exp(-(q * q)) * taper * float(rg[5]))
			var hv := land * base * (35 + 260 * nz + 120 * dt) + land * mount * (0.25 + 0.75 * nz + 0.5 * dt)
			hv = hv - (1 - land) * 60
			for isl in islets:
				var dx: float = xx - float(isl[0])
				var dy: float = yy - float(isl[1])
				var r2: float = float(isl[2]) * float(isl[2])
				var bump := exp(-((dx * dx + dy * dy) / r2))
				hv = maxf(hv, bump * float(isl[3]) * (0.7 + 0.6 * dt) - (1 - bump) * 60)
			h[k] = hv
	_shape_fields(h)
	_plant_trees(p_seed)


func set_data(heights: PackedFloat32Array, trees: PackedFloat32Array, airfields: Array) -> void:
	_parse_fields(airfields)
	_h = heights.duplicate()
	_trees = trees.duplicate()
	_bucket_trees()


static func _bucket_key(bi: int, bj: int) -> int:
	return (bi << 32) ^ (bj & 0xFFFFFFFF)


static func _floordiv_f32(x: float) -> int:
	# numpy float32 floor_divide by a Python float bucket size
	return int(floorf(_f32(x / float(_f32(BUCKET)))))


func _bucket_trees() -> void:
	_buckets.clear()
	for i in tree_count():
		var key := _bucket_key(_floordiv_f32(_trees[4 * i]), _floordiv_f32(_trees[4 * i + 1]))
		if not _buckets.has(key):
			_buckets[key] = []  # (an Array: packed arrays are values, append would hit a copy)
		(_buckets[key] as Array).append(i)


func get_heights() -> PackedFloat32Array:
	return _h.duplicate()


func get_trees() -> PackedFloat32Array:
	return _trees.duplicate()


func get_field_elev() -> Dictionary:
	return _field_elev


func tree_count() -> int:
	return _trees.size() / 4


## Python world.height(): float32 arithmetic.
func height(x: float, y: float) -> float:
	var fx := (x + HALF) / CELL
	var fy := (y + HALF) / CELL
	var i := int(_clip(fx, 0, GRID - 2))
	var j := int(_clip(fy, 0, GRID - 2))
	var tx := fx - i
	var ty := fy - j
	var a := _f32(1 - tx)
	var b := _f32(tx)
	var c := _f32(1 - ty)
	var d := _f32(ty)
	var r0 := j * GRID + i
	var r1 := r0 + GRID
	var v := _f32(_f32(_h[r0] * a) * c)
	v = _f32(v + _f32(_f32(_h[r0 + 1] * b) * c))
	v = _f32(v + _f32(_f32(_h[r1] * a) * d))
	v = _f32(v + _f32(_f32(_h[r1 + 1] * b) * d))
	return v


## The same with float64 arithmetic (numpy float64 callers).
func height64(x: float, y: float) -> float:
	var fx := (x + HALF) / CELL
	var fy := (y + HALF) / CELL
	var i := int(_clip(fx, 0, GRID - 2))
	var j := int(_clip(fy, 0, GRID - 2))
	var tx := fx - i
	var ty := fy - j
	var r0 := j * GRID + i
	var r1 := r0 + GRID
	return _h[r0] * (1 - tx) * (1 - ty) + _h[r0 + 1] * tx * (1 - ty) + _h[r1] * (1 - tx) * ty + _h[r1 + 1] * tx * ty


func _heights_many_one(x: float, y: float) -> float:
	var fx := _clip((x + HALF) / CELL, 0, GRID - 1.0001)
	var fy := _clip((y + HALF) / CELL, 0, GRID - 1.0001)
	var i := int(fx)
	var j := int(fy)
	var tx := fx - i
	var ty := fy - j
	var r0 := j * GRID + i
	var r1 := r0 + GRID
	return _h[r0] * (1 - tx) * (1 - ty) + _h[r0 + 1] * tx * (1 - ty) + _h[r1] * (1 - tx) * ty + _h[r1 + 1] * tx * ty


func heights_many(xs: PackedFloat64Array, ys: PackedFloat64Array) -> PackedFloat64Array:
	var n := mini(xs.size(), ys.size())
	var out := PackedFloat64Array()
	out.resize(n)
	for k in n:
		out[k] = _heights_many_one(xs[k], ys[k])
	return out


func line_of_sight(ax: float, ay: float, az: float, bx: float, by: float, bz: float, step: float) -> bool:
	var d := PyMath.hypot(bx - ax, by - ay)
	var n := maxi(2, int(d / step))
	for k in range(1, n):
		var t := float(k) / n
		var g := maxf(_heights_many_one(ax + (bx - ax) * t, ay + (by - ay) * t), 0.0)
		if not (g <= az + (bz - az) * t):
			return false
	return true


func tree_hit(x: float, y: float, z: float, radius: float) -> bool:
	var bi := int(floorf(x / BUCKET))
	var bj := int(floorf(y / BUCKET))
	var xf := _f32(x)
	var yf := _f32(y)
	var rf := _f32(radius)
	for di in [-1, 0, 1]:
		for dj in [-1, 0, 1]:
			var key := _bucket_key(bi + di, bj + dj)
			if not _buckets.has(key):
				continue
			for idx in _buckets[key]:
				var o: int = 4 * idx
				var ddx := _f32(_trees[o] - xf)
				var ddy := _f32(_trees[o + 1] - yf)
				var rr := _f32(rf + _f32(_trees[o + 3] * 0.25))
				if z < _f32(_trees[o + 2] + _trees[o + 3]) and _f32(_f32(ddx * ddx) + _f32(ddy * ddy)) < _f32(rr * rr):
					return true
	return false


## max(floor, tree tops within radius)
func tree_top(x: float, y: float, radius: float, p_floor: float) -> float:
	var top := p_floor
	var bi := int(floorf(x / BUCKET))
	var bj := int(floorf(y / BUCKET))
	var xf := _f32(x)
	var yf := _f32(y)
	var r2 := _f32(radius * radius)
	for di in [-1, 0, 1]:
		for dj in [-1, 0, 1]:
			var key := _bucket_key(bi + di, bj + dj)
			if not _buckets.has(key):
				continue
			for idx in _buckets[key]:
				var o: int = 4 * idx
				var ddx := _f32(_trees[o] - xf)
				var ddy := _f32(_trees[o + 1] - yf)
				if _f32(_f32(ddx * ddx) + _f32(ddy * ddy)) < r2:
					top = maxf(top, _f32(_trees[o + 2] + _trees[o + 3]))
	return top
