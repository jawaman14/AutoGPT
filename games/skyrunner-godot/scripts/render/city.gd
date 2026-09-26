class_name CityRender
extends RefCounted
## What MapCity puts on the ground: the city's buildings (one MultiMesh of unit
## boxes with the window shader, so thousands stay cheap), cranes on the docks,
## roads as ribbons draped on the terrain, street lamps through town and the
## stash houses. The buildings drawn here are the obstacles in the physics
## tree list (MapCity.post), so what you see is what you hit.

const PALETTE := [Color(0.86, 0.79, 0.63), Color(0.80, 0.60, 0.52), Color(0.63, 0.73, 0.76), Color(0.87, 0.84, 0.77),
	Color(0.77, 0.69, 0.50), Color(0.70, 0.78, 0.62), Color(0.90, 0.72, 0.55)]

static var _mat: ShaderMaterial
static var _lamp_mat: StandardMaterial3D


static func city_material() -> ShaderMaterial:
	if _mat == null:
		_mat = ShaderMaterial.new()
		_mat.shader = load("res://shaders/city.gdshader")
		_mat.set_shader_parameter("noise_pack", TexGen.noise_pack())
	return _mat


static func set_night(n: float) -> void:
	if _mat != null:
		_mat.set_shader_parameter("night", clampf((n - 0.25) / 0.5, 0.0, 1.0))
	if _lamp_mat != null:
		_lamp_mat.emission_energy_multiplier = 4.0 * clampf((n - 0.3) / 0.4, 0.0, 1.0)


static func build(world: World, q: Quality) -> Node3D:
	var root := Node3D.new()
	root.name = "city"
	var l := world.map
	if l.buildings.is_empty() and l.roads.is_empty():
		return root
	root.add_child(_buildings(l.buildings, q))
	for b in l.buildings:
		if b.style == "crane":
			root.add_child(_crane(b))
	root.add_child(_roads(world, l.roads))
	root.add_child(_lamps(world, l.roads))
	for st in l.stashes:
		root.add_child(stash_house(world, st))
	return root


static func _buildings(list: Array, q: Quality) -> MultiMeshInstance3D:
	var boxes := list.filter(func(b): return b.style != "crane")
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	var bm := BoxMesh.new()
	bm.size = Vector3.ONE
	mm.mesh = bm
	mm.instance_count = boxes.size()
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	for i in boxes.size():
		var b: Dictionary = boxes[i]
		var h: float = b.h + 1.5  # sunk 1.5 m: sloping lots never show a gap under the wall
		var basis := Basis.IDENTITY.scaled(Vector3(b.w, h, b.d))
		mm.set_instance_transform(i, Transform3D(basis, Vector3(b.x, b.z - 1.5 + h / 2, -b.y)))
		var col: Color
		match b.style:
			"warehouse":
				col = Color(0.56, 0.50, 0.44).lerp(Color(0.45, 0.52, 0.58), rng.randf())
				col.a = 0.0
			"tower":
				col = Color(0.60, 0.64, 0.68).lerp(Color(0.80, 0.78, 0.72), rng.randf())
				col.a = 1.0
			_:
				col = PALETTE[rng.randi() % PALETTE.size()]
				col.a = 1.0
		mm.set_instance_color(i, col)
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "buildings"
	mmi.multimesh = mm
	mmi.material_override = city_material()
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if q.shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mmi


static func _crane(b: Dictionary) -> Node3D:
	var k := Buildings.Kit.new("crane")
	var h: float = b.h
	for sx in [-1, 1]:
		for sz in [-1, 1]:
			k.box(Vector3(sx * 4.0, 4.0, sz * 4.0), Vector3(0.8, 8.0, 0.8), "orange", false)  # portal legs
	k.box(Vector3(0, 8.4, 0), Vector3(9.5, 0.8, 9.5), "orange", false)
	k.box(Vector3(0, 8.8 + (h - 8.8) / 2, 0), Vector3(2.2, h - 8.8, 2.2), "orange", false)
	k.box(Vector3(0, h, -14.0), Vector3(1.6, 1.4, 40.0), "orange", false)  # boom out over the water
	k.box(Vector3(0, h + 1.8, 2.0), Vector3(3.0, 2.2, 4.0), "white", false)  # cab
	k.box(Vector3(0, h - 0.5, 9.0), Vector3(3.0, 2.0, 5.0), "concrete_dark", false)  # counterweight
	var n := k.finish()
	n.position = Vector3(b.x, b.z, -b.y)
	return n


## Roads: a 9 m ribbon a little above the ground, a deck over water (bridges).
static func _roads(world: World, roads: Array) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for r in roads:
		var pts := PackedVector2Array()
		for k in r.size() - 1:
			var a := Vector2(r[k][0], r[k][1])
			var b := Vector2(r[k + 1][0], r[k + 1][1])
			var n := int(a.distance_to(b) / 12.0) + 1
			for q in n:
				pts.append(a.lerp(b, float(q) / n))
		pts.append(Vector2(r[r.size() - 1][0], r[r.size() - 1][1]))
		var prev_l := Vector3.ZERO
		var prev_r := Vector3.ZERO
		for k in pts.size():
			var dir := (pts[mini(k + 1, pts.size() - 1)] - pts[maxi(k - 1, 0)]).normalized()
			var side := Vector2(-dir.y, dir.x) * 4.5
			var zs := []
			for p in [pts[k] + side, pts[k] - side, pts[k]]:
				zs.append(world.ground(p.x, p.y))
			var z := maxf(maxf(zs[0], zs[1]), maxf(zs[2], 2.2)) + 0.45
			var lp := Vector3(pts[k].x + side.x, z, -(pts[k].y + side.y))
			var rp := Vector3(pts[k].x - side.x, z, -(pts[k].y - side.y))
			if k > 0:
				for v in [prev_l, lp, rp, prev_l, rp, prev_r]:
					st.set_normal(Vector3.UP)
					st.add_vertex(v)
			prev_l = lp
			prev_r = rp
	var mi := MeshInstance3D.new()
	mi.name = "roads"
	mi.mesh = st.commit()
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.2, 0.2, 0.21)
	m.roughness = 0.95
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


## Street lamps along the roads in town, a glowing head every 45 m on alternate sides.
static func _lamps(world: World, roads: Array) -> MultiMeshInstance3D:
	var spots := []
	for r in roads:
		var run := 0.0
		for k in r.size() - 1:
			var a := Vector2(r[k][0], r[k][1])
			var b := Vector2(r[k + 1][0], r[k + 1][1])
			var dir := (b - a).normalized()
			var side := Vector2(-dir.y, dir.x)
			var d := 0.0
			while d < a.distance_to(b):
				var p := a + dir * d + side * (7.0 if int(run / 45.0) % 2 == 0 else -7.0)
				var cls := MapCity.at(world.map.land_use, p.x, p.y)
				if cls in [MapCity.URBAN, MapCity.PORT] or world.airfield_at(p.x, p.y, 200.0) != null:
					spots.append(Vector3(p.x, world.ground(p.x, p.y) + 7.0, -p.y))
				d += 45.0
				run += 45.0
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var sm := SphereMesh.new()
	sm.radius = 0.45
	sm.height = 0.9
	sm.radial_segments = 6
	sm.rings = 3
	mm.mesh = sm
	mm.instance_count = spots.size()
	for i in spots.size():
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, spots[i]))
	_lamp_mat = StandardMaterial3D.new()
	_lamp_mat.albedo_color = Color(1.0, 0.8, 0.5)
	_lamp_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_lamp_mat.emission_enabled = true
	_lamp_mat.emission = Color(1.0, 0.75, 0.45)
	_lamp_mat.emission_energy_multiplier = 0.0
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "lamps"
	mmi.multimesh = mm
	mmi.material_override = _lamp_mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.visibility_range_end = 6000.0
	return mmi


## A stash house by its kind: a barn, a shack on stilts, a dockside warehouse,
## a lock-up, tents under the canopy, a quarry shed, a boathouse, a villa.
static func stash_house(world: World, st: Dictionary) -> Node3D:
	var k := Buildings.Kit.new("stash-" + st.id)
	match st.kind:
		"barn":
			k.box(Vector3(0, 3.0, 0), Vector3(12, 6, 18), "red")
			k.gable(Vector3(0, 6.0, 0), 12, 18, 3.5, "metal_rust")
		"shack":
			for sx in [-1, 1]:
				for sz in [-1, 1]:
					k.box(Vector3(sx * 2.6, 0.9, sz * 2.0), Vector3(0.25, 1.8, 0.25), "wood")
			k.box(Vector3(0, 3.0, 0), Vector3(6, 2.4, 5), "wood")
			k.gable(Vector3(0, 4.2, 0), 6, 5, 1.4, "metal_rust")
		"warehouse":
			k.box(Vector3(0, 5.0, 0), Vector3(30, 10, 18), "metal")
			k.box(Vector3(0, 2.2, -9.05), Vector3(6, 4.4, 0.1), "black", false)
			k.box(Vector3(9, 8.5, -9.1), Vector3(5, 1.2, 0.1), "white", false)  # "7"
		"lockup":
			for i in 4:
				k.box(Vector3(-6 + i * 4.0, 1.4, 0), Vector3(3.8, 2.8, 6), "concrete")
				k.box(Vector3(-6 + i * 4.0, 1.2, -3.05), Vector3(3.2, 2.4, 0.08), "metal_rust", false)
		"camp":
			for p in [[0, 0], [7, 3], [-6, 4]]:
				k.gable(Vector3(p[0], 0.2, p[1]), 5, 7, 2.6, "green", 0.2)
			k.box(Vector3(2, 0.5, -6), Vector3(3, 1.0, 2), "wood")
		"shed":
			Buildings.shed(k, Vector3(0, 0, 0), 9, 6, "metal_rust")
		"boathouse":
			k.box(Vector3(0, 2.5, 0), Vector3(8, 5, 14), "wood")
			k.gable(Vector3(0, 5.0, 0), 8, 14, 2.0, "metal_rust")
			k.box(Vector3(0, 0.3, -12), Vector3(3, 0.6, 10), "wood")  # the jetty
		_:
			k.box(Vector3(0, 2.0, 0), Vector3(14, 4, 10), "stucco_pink")
			k.gable(Vector3(0, 4.0, 0), 14, 10, 2.4, "terracotta", 0.8)
			k.box(Vector3(0, -0.2, -9), Vector3(8, 0.4, 4), "concrete", false)
	var n := k.finish()
	var z := world.ground(st.x, st.y)
	n.position = Vector3(st.x, z, -st.y)
	n.set_meta("stash", st.id)
	return n
