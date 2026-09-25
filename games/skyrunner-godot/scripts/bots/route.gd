class_name RoutePlanner
extends RefCounted
## Terrain-masking route planner: follow the valleys, stay under the radar.
##
## Dijkstra over a coarse copy of the height map (250 m cells). Moving into
## higher ground costs extra and so does simply being high, so the cheapest path
## threads through low ground: the classic low-level smuggling route, and one
## that a loaded single can actually climb.

const CELL_M := 250.0
static var _cache := {}


## n x n grid (row = y) of max(terrain, 0), each cell as high as its highest neighbour.
static func _grid(world: World) -> Array:
	var key := world.seed
	if _cache.has(key):
		return _cache[key]
	var half := World.HALF
	var n := int(2 * half / CELL_M) + 1
	var xs := PackedFloat64Array()
	var step := (2 * half) / (n - 1)
	for k in n:
		xs.append(k * step + (-half))
	xs[n - 1] = half
	var qx := PackedFloat64Array()
	var qy := PackedFloat64Array()
	for r in n:
		for c in n:
			qx.append(xs[c])
			qy.append(xs[r])
	var raw := world.heights_many(qx, qy)
	var h := PackedFloat64Array()
	h.resize(n * n)
	for k in n * n:
		h[k] = maxf(raw[k], 0.0)
	# a cell is as high as its highest neighbour: don't thread needles (edge-padded)
	var out := PackedFloat64Array()
	out.resize(n * n)
	for r in n:
		for c in n:
			var m := -INF
			for dj in [-1, 0, 1]:
				for di in [-1, 0, 1]:
					var rr := clampi(r + dj, 0, n - 1)
					var cc := clampi(c + di, 0, n - 1)
					m = maxf(m, h[rr * n + cc])
			out[r * n + c] = m
	_cache[key] = [out, n]
	return _cache[key]


static func _cell(x: float, y: float, n: int) -> Array:
	var half := World.HALF
	var fy := (y + half) / CELL_M
	var j: int
	if 0 <= fy and fy < n:
		j = mini(n - 1, Py.round_int(fy))
	else:
		j = maxi(0, mini(n - 1, int(fy)))
	var i := maxi(0, mini(n - 1, Py.round_int((x + half) / CELL_M)))
	return [j, i]


# ------------------------------------------------ binary heap on [d, j, i]
static func _less(a: Array, b: Array) -> bool:
	if a[0] != b[0]:
		return a[0] < b[0]
	if a[1] != b[1]:
		return a[1] < b[1]
	return a[2] < b[2]


static func _push(heap: Array, item: Array) -> void:
	heap.append(item)
	var k := heap.size() - 1
	while k > 0:
		var p := (k - 1) >> 1
		if _less(heap[k], heap[p]):
			var t = heap[k]
			heap[k] = heap[p]
			heap[p] = t
			k = p
		else:
			break


static func _pop(heap: Array) -> Array:
	var top: Array = heap[0]
	var last: Array = heap.pop_back()
	if not heap.is_empty():
		heap[0] = last
		var k := 0
		var n := heap.size()
		while true:
			var l := 2 * k + 1
			var r := l + 1
			var m := k
			if l < n and _less(heap[l], heap[m]):
				m = l
			if r < n and _less(heap[r], heap[m]):
				m = r
			if m == k:
				break
			var t = heap[k]
			heap[k] = heap[m]
			heap[m] = t
			k = m
	return top


## Waypoints [[x, y], ...] (excluding start, including goal).
static func plan_route(world: World, start: Array, goal: Array, climb_weight := 6.0, height_weight := 1.5,
		spacing_m := 1500.0) -> Array:
	var g := _grid(world)
	var h: PackedFloat64Array = g[0]
	var n: int = g[1]
	var half := World.HALF
	var sc := _cell(start[0], start[1], n)
	var gc := _cell(goal[0], goal[1], n)
	var sj: int = sc[0]
	var si: int = sc[1]
	var gj: int = gc[0]
	var gi: int = gc[1]
	var dist := PackedFloat64Array()
	dist.resize(n * n)
	dist.fill(INF)
	var prev := PackedInt32Array()
	prev.resize(n * n)
	prev.fill(-1)
	dist[sj * n + si] = 0.0
	var pq := [[0.0, sj, si]]
	var steps := []
	for dj in [-1, 0, 1]:
		for di in [-1, 0, 1]:
			if dj or di:
				steps.append([dj, di, PyMath.hypot(dj, di) * CELL_M])
	var hmin := INF
	for v in h:
		hmin = minf(hmin, v)
	while not pq.is_empty():
		var top := _pop(pq)
		var d: float = top[0]
		var j: int = top[1]
		var i: int = top[2]
		if d > dist[j * n + i]:
			continue
		if j == gj and i == gi:
			break
		var hc := h[j * n + i]
		for st in steps:
			var jj: int = j + st[0]
			var ii: int = i + st[1]
			if not (0 <= jj and jj < n and 0 <= ii and ii < n):
				continue
			var hn := h[jj * n + ii]
			var step: float = st[2]
			var cost := step * (1.0 + climb_weight * maxf(0.0, hn - hc) / step + height_weight * (hn - hmin) / 1000.0)
			var nd := d + cost
			if nd < dist[jj * n + ii]:
				dist[jj * n + ii] = nd
				prev[jj * n + ii] = j * n + i
				_push(pq, [nd, jj, ii])
	var path := []
	var j := gj
	var i := gi
	while not (j == sj and i == si) and prev[j * n + i] >= 0:
		path.append([i * CELL_M - half, j * CELL_M - half])
		var p := prev[j * n + i]
		j = p / n
		i = p % n
	path.reverse()
	# thin to one waypoint every `spacing_m`, always keep the goal exact
	var out := []
	var acc := 0.0
	var last: Array = start
	for p in path:
		acc += Py.dist2(p, last)
		last = p
		if acc >= spacing_m:
			out.append(p)
			acc = 0.0
	out.append(goal)
	return out
