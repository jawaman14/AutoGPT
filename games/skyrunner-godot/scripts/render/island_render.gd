class_name IslandRender
extends RefCounted
## Isla Soberana in 3D, over the southern horizon: its ground (Island.height,
## so what's drawn is what you land on), sand at the rim and green inland, the
## runway and its buildings, a faded colonial port town of pastel boxes around
## Puerto Rojo, a mole and a fort on the headland, and the Nature Kit's palms.

const GRID := Vector2i(120, 70)


static func build(world: World, q: Quality) -> Node3D:
	var root := Node3D.new()
	root.name = "isla-soberana"
	root.add_child(_ground())
	root.add_child(_palms(q))
	root.add_child(_town())
	for af in world.map.foreign:
		var n := Models.build_airfield(world, af, q)
		root.add_child(n)
	return root


static func _ground() -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var x0 := Island.C.x - Island.R.x * 1.08
	var y0 := Island.C.y - Island.R.y * 1.08
	var dx := Island.R.x * 2.16 / GRID.x
	var dy := Island.R.y * 2.16 / GRID.y
	var pts := []
	for j in GRID.y + 1:
		var row := []
		for i in GRID.x + 1:
			var x := x0 + i * dx
			var y := y0 + j * dy
			row.append(Vector3(x, Island.height(x, y), -y))
		pts.append(row)
	for j in GRID.y:
		for i in GRID.x:
			var a: Vector3 = pts[j][i]
			var b: Vector3 = pts[j][i + 1]
			var c: Vector3 = pts[j + 1][i + 1]
			var d: Vector3 = pts[j + 1][i]
			if maxf(maxf(a.y, b.y), maxf(c.y, d.y)) < -0.4:
				continue  # all under water: the ocean draws it
			for tri in [[a, c, b], [a, d, c]]:
				var n: Vector3 = (tri[1] - tri[0]).cross(tri[2] - tri[0]).normalized()
				if n.y < 0:
					n = -n
				for v in tri:
					st.set_color(_tint(v.y, n.y, v.x, -v.z))
					st.set_normal(n)
					st.add_vertex(v)
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = 0.95
	st.set_material(m)
	var mi := MeshInstance3D.new()
	mi.name = "ground"
	mi.mesh = st.commit()
	return mi


static func _tint(h: float, up: float, x: float, y: float) -> Color:
	if h < 1.4:
		return Color(0.86, 0.79, 0.58)  # the beach
	if h < 3.0:
		return Color(0.5, 0.6, 0.3)
	if h > 18.0:
		# the Sierra: forest, rock on the steep faces
		return Color(0.17, 0.33, 0.15).lerp(Color(0.45, 0.42, 0.36), clampf((1.0 - up) * 2.5, 0.0, 1.0))
	# the plain: a patchwork of cane fields, tobacco and pasture
	var cell := int(floor(x / 260.0)) * 7 + int(floor(y / 180.0)) * 13
	var fields := [Color(0.42, 0.56, 0.22), Color(0.55, 0.6, 0.28), Color(0.33, 0.5, 0.2), Color(0.6, 0.52, 0.32), Color(0.38, 0.47, 0.24)]
	return (fields[posmod(cell, fields.size())] as Color).darkened(0.25 * (1.0 - up))


static func _palms(q: Quality) -> Node3D:
	var root := Node3D.new()
	root.name = "palms"
	var kit := ModelLib.palm_mesh(0, 1.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1959
	var xfs := []
	var n := 160 if q.name == "low" else 420
	var tries := 0
	while xfs.size() < n and tries < n * 20:
		tries += 1
		var a := rng.randf() * TAU
		var r := sqrt(rng.randf())
		var x := Island.C.x + cos(a) * r * Island.R.x
		var y := Island.C.y + sin(a) * r * Island.R.y
		var h := Island.height(x, y)
		if h < 0.6 or (h > 3.4 and h < 3.8):  # not in the sea, not on the graded runway corridor
			continue
		var s: float = rng.randf_range(8.0, 13.0) * (float(kit[1]) if not kit.is_empty() else 1.0)
		xfs.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s, s)), Vector3(x, h, -y)))
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = kit[0] if not kit.is_empty() else Vegetation._palm(5)
	mm.instance_count = xfs.size()
	for i in xfs.size():
		mm.set_instance_transform(i, xfs[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.custom_aabb = AABB(Vector3(Island.C.x - Island.R.x, -5, -Island.C.y - Island.R.y), Vector3(Island.R.x * 2, 80, Island.R.y * 2))
	root.add_child(mmi)
	return root


## Puerto Rojo: a grid of faded pastel two-storey blocks behind the quay, the
## mole, a fort on the headland, the harbour master's tower.
static func _town() -> Node3D:
	var k := Buildings.Kit.new("puerto-rojo")
	var rng := RandomNumberGenerator.new()
	rng.seed = 1962
	var paints := ["stucco", "stucco_pink", "white", "stucco", "terracotta", "neon_cyan"]
	var p := Island.PORT
	for bi in 9:
		for bj in 5:
			var x := p.x - 1400.0 + bi * 150.0 + rng.randf_range(-20, 20)
			var y := p.y - 250.0 - bj * 140.0 + rng.randf_range(-20, 20)
			var h := Island.height(x, y)
			if h < 1.0:
				continue
			var ht := rng.randf_range(6.0, 12.0)
			k.box(Vector3(x - p.x, h + ht / 2, -(y - p.y)), Vector3(rng.randf_range(24, 40), ht, rng.randf_range(20, 34)),
				paints[rng.randi() % paints.size()], false)
	# the mole and the quay
	k.box(Vector3(-500, 1.2, -60), Vector3(1000, 2.4, 30), "concrete", false)  # the quay
	k.box(Vector3(0, 1.2, -260), Vector3(30, 2.4, 380), "concrete", false)  # the mole, out into the bay
	# the fort on the headland and the harbour master's tower
	var fx := 700.0
	var fy := -150.0
	var fh := Island.height(p.x + fx, p.y + fy)
	k.box(Vector3(fx, fh + 5, -fy), Vector3(120, 10, 120), "concrete", false)
	k.box(Vector3(fx + 60, fh + 12, -fy - 60), Vector3(16, 14, 16), "concrete", false)
	k.box(Vector3(-200, 12, 40), Vector3(10, 24, 10), "white", false)
	var n := k.finish()
	var col = n.get_node_or_null("collision")
	if col != null:
		col.free()
	n.position = Vector3(p.x, 0, -p.y)
	return n
