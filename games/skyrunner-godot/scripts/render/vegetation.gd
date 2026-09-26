class_name Vegetation
extends RefCounted
## Island vegetation from the terrain's tree list: coconut palms along the
## coast and lowlands, broadleaf canopy inland, conifers on the high ground,
## undergrowth bushes around them. One MultiMesh per species with a wind-sway
## shader. Tree trunks/heights are the physics trees (Terrain.tree_hit), so what
## you see is what you hit.

const LEAF := [0.20, 0.42, 0.14]


## Unit-height meshes (origin at the ground). Vertex alpha = sway weight.
static func _palm(seg := 6) -> ArrayMesh:
	var mb := MeshBuilder.new()
	var lean := 0.12
	var n := 6
	for k in n:  # a slightly curved, tapering trunk
		var z0 := float(k) / n * 0.85
		var z1 := float(k + 1) / n * 0.85
		var r0 := 0.035 - 0.012 * z0
		var r1 := 0.035 - 0.012 * z1
		var x0 := lean * z0 * z0
		var x1 := lean * z1 * z1
		for s in seg:
			var a0 := TAU * s / seg
			var a1 := TAU * (s + 1) / seg
			var col := [0.45, 0.36, 0.25, z0]
			mb.quad([x0 + r0 * cos(a0), r0 * sin(a0), z0], [x0 + r0 * cos(a1), r0 * sin(a1), z0],
				[x1 + r1 * cos(a1), r1 * sin(a1), z1], [x1 + r1 * cos(a0), r1 * sin(a0), z1], col)
	var top := [lean * 0.72, 0.0, 0.85]
	for f in 9:  # drooping fronds
		var a := TAU * f / 9 + 0.3
		var prev := top
		for k in 4:
			var t := float(k + 1) / 4
			var reach := 0.42 * t
			var droop := 0.85 + 0.08 * t - 0.25 * t * t
			var p := [top[0] + cos(a) * reach, top[1] + sin(a) * reach, droop]
			var side := [-sin(a) * 0.06 * (1.0 - t * 0.6), cos(a) * 0.06 * (1.0 - t * 0.6), 0.0]
			var g := 0.85 + 0.15 * t
			var col := [LEAF[0] * g, LEAF[1] * g, LEAF[2] * g, 1.0]
			mb.quad([prev[0] - side[0], prev[1] - side[1], prev[2]], [prev[0] + side[0], prev[1] + side[1], prev[2]],
				[p[0] + side[0], p[1] + side[1], p[2]], [p[0] - side[0], p[1] - side[1], p[2]], col)
			prev = p
	return mb.mesh()


static func _broadleaf() -> ArrayMesh:
	var mb := MeshBuilder.new()
	mb.cylinder(0, 0, -0.02, 0.04, 0.45, [0.36, 0.27, 0.18, 0.0], 5)
	var blobs := [[0.0, 0.0, 0.62, 0.3], [0.14, 0.08, 0.52, 0.22], [-0.13, -0.06, 0.55, 0.22], [0.03, -0.14, 0.72, 0.2],
		[-0.05, 0.13, 0.78, 0.18]]
	for b in blobs:
		_blob(mb, b[0], b[1], b[2], b[3], [0.17, 0.33, 0.12])
	return mb.mesh()


static func _conifer() -> ArrayMesh:
	var mb := MeshBuilder.new()
	mb.cylinder(0, 0, -0.02, 0.03, 0.3, [0.32, 0.24, 0.16, 0.0], 5)
	for tier in [[0.18, 0.30, 0.42], [0.42, 0.24, 0.34], [0.64, 0.16, 0.36]]:
		mb.cone(0, 0, tier[0], tier[1], tier[2], [0.10, 0.24, 0.12, 0.7 + tier[0] * 0.4], 8)
	return mb.mesh()


## A red mangrove: a tangle of arching prop roots under a wide, low canopy.
static func _mangrove() -> ArrayMesh:
	var mb := MeshBuilder.new()
	for r in 7:
		var a := TAU * r / 7 + 0.4
		var foot := [cos(a) * 0.32, sin(a) * 0.32, -0.02]
		var knee := [cos(a) * 0.2, sin(a) * 0.2, 0.22]
		mb.quad([foot[0] - 0.015, foot[1], foot[2]], [foot[0] + 0.015, foot[1], foot[2]], [knee[0] + 0.015, knee[1], knee[2]],
			[knee[0] - 0.015, knee[1], knee[2]], [0.36, 0.27, 0.2, 0.0])
		mb.quad([knee[0] - 0.015, knee[1], knee[2]], [knee[0] + 0.015, knee[1], knee[2]], [0.015, 0.0, 0.34], [-0.015, 0.0, 0.34],
			[0.36, 0.27, 0.2, 0.0])
	mb.cylinder(0, 0, 0.3, 0.035, 0.3, [0.36, 0.27, 0.18, 0.2], 5)
	for b in [[0.0, 0.0, 0.72, 0.42], [0.3, 0.12, 0.66, 0.3], [-0.28, -0.1, 0.68, 0.32], [0.05, -0.3, 0.7, 0.28], [-0.1, 0.3, 0.74, 0.26]]:
		_blob(mb, b[0], b[1], b[2], b[3], [0.14, 0.30, 0.13])
	return mb.mesh()


static func _bush() -> ArrayMesh:
	var mb := MeshBuilder.new()
	_blob(mb, 0, 0, 0.35, 0.45, [0.22, 0.36, 0.15])
	_blob(mb, 0.3, 0.1, 0.3, 0.32, [0.25, 0.4, 0.16])
	return mb.mesh()


## A low-poly lumpy sphere (octahedron subdivided once).
static func _blob(mb: MeshBuilder, x: float, y: float, z: float, r: float, col: Array) -> void:
	var v := [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]]
	var faces := [[0, 2, 4], [2, 1, 4], [1, 3, 4], [3, 0, 4], [2, 0, 5], [1, 2, 5], [3, 1, 5], [0, 3, 5]]
	for f in faces:
		var a := Vector3(v[f[0]][0], v[f[0]][1], v[f[0]][2])
		var b := Vector3(v[f[1]][0], v[f[1]][1], v[f[1]][2])
		var c := Vector3(v[f[2]][0], v[f[2]][1], v[f[2]][2])
		var ab := (a + b).normalized()
		var bc := (b + c).normalized()
		var ca := (c + a).normalized()
		for t in [[a, ab, ca], [ab, b, bc], [ca, bc, c], [ab, bc, ca]]:
			var pts := []
			for p in t:
				var lump := 1.0 + 0.12 * sin(p.x * 7.0 + p.y * 5.0 + x * 13.0)
				pts.append([x + p.x * r * lump, y + p.y * r * lump, z + p.z * r * 0.8 * lump])
			var shade: float = 0.8 + 0.25 * (t[0].z + 1.0) / 2.0
			mb.tri(pts[0], pts[1], pts[2], [col[0] * shade, col[1] * shade, col[2] * shade, 1.0])


## A lookup: is (x, y) inside one of the city's building footprints?
static func _building_index(buildings: Array) -> Callable:
	var cells := {}
	for b in buildings:
		var key := Vector2i(floori(b.x / 100.0), floori(b.y / 100.0))
		if not cells.has(key):
			cells[key] = []
		cells[key].append(b)
	return func(x: float, y: float) -> bool:
		for dj in [-1, 0, 1]:
			for di in [-1, 0, 1]:
				for b in cells.get(Vector2i(floori(x / 100.0) + di, floori(y / 100.0) + dj), []):
					if absf(x - b.x) <= b.w / 2 + 0.5 and absf(y - b.y) <= b.d / 2 + 0.5:
						return true
		return false


static func build(world: World, q: Quality) -> Node3D:
	var root := Node3D.new()
	root.name = "trees"
	var trees := world.terrain.get_trees()
	var count := trees.size() / 4
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var kinds := {"palm": [], "broad": [], "conifer": [], "bush": [], "mangrove": []}
	var lu := world.map.land_use
	var scrub_bush := {}  ## trees drawn as a big thorn bush (scrub land)
	var in_building := _building_index(world.map.buildings)
	for k in count:
		var ht: float = trees[k * 4 + 3]
		if k % q.tree_keep != 0 and ht < 21:  # keep the deliberate tree lines at strip ends
			continue
		var z: float = trees[k * 4 + 2]
		var r := rng.randf()
		var kind := "broad"
		if not lu.is_empty():
			var x: float = trees[k * 4]
			var y: float = trees[k * 4 + 1]
			if in_building.call(x, y):
				continue  # a building's obstacle point, drawn by CityRender
			match MapCity.at(lu, x, y):
				MapCity.MANGROVE:
					kind = "mangrove"
				MapCity.SWAMP:
					kind = "palm" if r < 0.35 else "broad"
				MapCity.JUNGLE:
					kind = "palm" if r < 0.25 else ("conifer" if z > 700 and r > 0.8 else "broad")
				MapCity.SCRUB:
					kind = "bush" if r < 0.5 else "broad"
					if kind == "bush":
						scrub_bush[k] = true
				_:
					if z < 70 and r < 0.8:
						kind = "palm"
					elif z > 480 or (z > 250 and r < 0.4):
						kind = "conifer"
		elif z < 70 and r < 0.8:
			kind = "palm"
		elif z > 480 or (z > 250 and r < 0.4):
			kind = "conifer"
		kinds[kind].append(k)
		if q.shaded and rng.randf() < 0.35 and not scrub_bush.has(k):
			kinds["bush"].append(k)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/foliage.gdshader")
	var meshes := {"palm": _palm(), "broad": _broadleaf(), "conifer": _conifer(), "bush": _bush(), "mangrove": _mangrove()}
	for kind in kinds:
		var list: Array = kinds[kind]
		if list.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = meshes[kind]
		mm.instance_count = list.size()
		for n in list.size():
			var k: int = list[n]
			var x: float = trees[k * 4]
			var y: float = trees[k * 4 + 1]
			var z: float = trees[k * 4 + 2]
			var ht: float = trees[k * 4 + 3]
			var s := ht * (1.15 if kind == "palm" else 1.0)
			var pos := Vector3(x, z, -y)
			if kind == "bush" and scrub_bush.has(k):
				s = ht * 0.5  # scrub: a low, wide thorn bush where a tree stood
			elif kind == "bush":
				s = rng.randf_range(1.5, 3.0)
				var off := Vector2(rng.randf_range(-7, 7), rng.randf_range(-7, 7))
				pos = Vector3(x + off.x, world.ground(x + off.x, y - off.y), -(y - off.y))
			var b := Basis.from_euler(Vector3(0, rng.randf() * TAU, 0)).scaled(Vector3(s, s, s))
			mm.set_instance_transform(n, Transform3D(b, pos))
			var g := rng.randf_range(0.8, 1.15)
			mm.set_instance_color(n, Color(g * rng.randf_range(0.92, 1.05), g, g * rng.randf_range(0.85, 1.0)))
		var mmi := MultiMeshInstance3D.new()
		mmi.name = kind
		mmi.multimesh = mm
		mmi.material_override = mat if q.shaded else Models.vertex_material()
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if q.shadows and kind != "bush" else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.visibility_range_end = 9000.0 if kind == "bush" else 0.0
		root.add_child(mmi)
	return root
