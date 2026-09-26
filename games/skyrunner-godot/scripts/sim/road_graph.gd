class_name RoadGraph
extends RefCounted
## The map's roads as a graph for ground units: nodes at the polyline
## vertices (shared vertices and ends within MERGE_M are one junction; a road's
## loose end within TEE_M of another road joins it as a T), edges along the
## polylines. Places off the network (stash houses, HQs, strips) get a stub to
## the nearest node. `path` is A* over the nodes and returns the points to
## drive; `route` adds the off-road legs at each end.
##
## Maps with no roads (the classic island, the generated islands) get a sparse
## graph of straight tracks between the strips and HQ sites instead, so squads
## still have somewhere to go; GroundWar only runs there when asked to.

const MERGE_M := 60.0
const TEE_M := 450.0

var nodes: Array = []  ## Vector2
var adj: Array = []  ## node -> [[other, length], ...]
var road_nodes := 0  ## nodes before the stubs


func _init(roads: Array, places: Array = []) -> void:
	for r in roads:
		var prev := -1
		for p in r:
			var i := _node(Vector2(p[0], p[1]))
			if prev >= 0 and prev != i:
				_link(prev, i)
			prev = i
	# a loose end near another road: a T junction
	for i in nodes.size():
		if adj[i].size() == 1:
			var best := -1
			var bd := TEE_M
			for j in nodes.size():
				if j != i and adj[i][0][0] != j:
					var d: float = nodes[i].distance_to(nodes[j])
					if d < bd and not _linked(i, j):
						bd = d
						best = j
			if best >= 0:
				_link(i, best)
	road_nodes = nodes.size()
	for p in places:
		stub(Vector2(p[0], p[1]))


## A graph of straight tracks between `points` (maps without roads): each
## point to its three nearest neighbours.
static func tracks(points: Array) -> RoadGraph:
	var g := RoadGraph.new([])
	for p in points:
		g._node(Vector2(p[0], p[1]))
	for i in g.nodes.size():
		var d := []
		for j in g.nodes.size():
			if j != i:
				d.append([g.nodes[i].distance_to(g.nodes[j]), j])
		d.sort_custom(func(a, b): return a[0] < b[0])
		for k in mini(3, d.size()):
			if not g._linked(i, d[k][1]):
				g._link(i, d[k][1])
	g.road_nodes = g.nodes.size()
	return g


func _node(p: Vector2) -> int:
	for i in nodes.size():
		if nodes[i].distance_to(p) < MERGE_M:
			return i
	nodes.append(p)
	adj.append([])
	return nodes.size() - 1


func _linked(a: int, b: int) -> bool:
	for e in adj[a]:
		if e[0] == b:
			return true
	return false


func _link(a: int, b: int) -> void:
	var d: float = nodes[a].distance_to(nodes[b])
	adj[a].append([b, d])
	adj[b].append([a, d])


## Tie a place to the nearest road node; returns the new node.
func stub(p: Vector2) -> int:
	var n := nearest(p)
	var i := nodes.size()
	nodes.append(p)
	adj.append([])
	if n >= 0:
		_link(i, n)
	return i


func nearest(p: Vector2, roads_only := true) -> int:
	var best := -1
	var bd := INF
	for i in (road_nodes if roads_only and road_nodes > 0 else nodes.size()):
		var d := p.distance_squared_to(nodes[i])
		if d < bd:
			bd = d
			best = i
	return best


## A* from node a to node b: the node indices, or [] if unreachable.
func path(a: int, b: int) -> Array:
	if a < 0 or b < 0:
		return []
	if a == b:
		return [a]
	var g := {a: 0.0}
	var came := {}
	var open := [a]
	while not open.is_empty():
		var cur: int = open[0]
		var cf: float = g[cur] + nodes[cur].distance_to(nodes[b])
		for o in open:
			var f: float = g[o] + nodes[o].distance_to(nodes[b])
			if f < cf:
				cf = f
				cur = o
		if cur == b:
			var out := [b]
			while came.has(out[0]):
				out.push_front(came[out[0]])
			return out
		open.erase(cur)
		for e in adj[cur]:
			var ng: float = g[cur] + e[1]
			if not g.has(e[0]) or ng < g[e[0]]:
				g[e[0]] = ng
				came[e[0]] = cur
				if not open.has(e[0]):
					open.append(e[0])
	return []


## The points to drive from `from` to `to`: off-road to the nearest node, the
## roads, off-road to the target. Straight line if the network can't connect them.
func route(from: Vector2, to: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array([from])
	var a := nearest(from, false)
	var b := nearest(to, false)
	var p := path(a, b)
	if p.is_empty() or from.distance_to(to) < 400.0:
		out.append(to)
		return out
	for i in p:
		if out[out.size() - 1].distance_to(nodes[i]) > 1.0:
			out.append(nodes[i])
	if out[out.size() - 1].distance_to(to) > 1.0:
		out.append(to)
	return out


static func length(pts: PackedVector2Array) -> float:
	var s := 0.0
	for i in pts.size() - 1:
		s += pts[i].distance_to(pts[i + 1])
	return s


## The point `dist` metres along `pts`.
static func along(pts: PackedVector2Array, dist: float) -> Vector2:
	if pts.is_empty():
		return Vector2.ZERO
	var left := dist
	for i in pts.size() - 1:
		var seg := pts[i].distance_to(pts[i + 1])
		if left <= seg:
			return pts[i].lerp(pts[i + 1], left / maxf(seg, 1e-6))
		left -= seg
	return pts[pts.size() - 1]


## A chokepoint on `pts`: a road node at least `min_d` along (where an ambush
## waits), or the midpoint.
func chokepoint(pts: PackedVector2Array, min_d := 800.0) -> Vector2:
	var run := 0.0
	for i in range(1, pts.size()):
		run += pts[i - 1].distance_to(pts[i])
		if run >= min_d and i < pts.size() - 1:
			for k in road_nodes:
				if nodes[k].distance_to(pts[i]) < 1.0 and adj[k].size() >= 2:
					return pts[i]
	return along(pts, length(pts) * 0.5)


func connected(a: Vector2, b: Vector2) -> bool:
	return not path(nearest(a, false), nearest(b, false)).is_empty()
