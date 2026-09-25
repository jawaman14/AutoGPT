class_name Models
extends RefCounted
## Procedural geometry: terrain, water, runways, trees, aircraft, police units,
## boats (port of render/models.py). No external art: everything is built from
## vertex-coloured primitives so the game runs from a clean checkout.
##
## All builders take game coordinates (x east, y north, z up) and return Godot
## nodes (x, z, -y); models face -Z (Godot forward) with rotation 0.

static var _vmat: StandardMaterial3D
static var _emis := {}


static func vertex_material() -> StandardMaterial3D:
	if _vmat == null:
		_vmat = StandardMaterial3D.new()
		_vmat.vertex_color_use_as_albedo = true
		_vmat.roughness = 0.85
	return _vmat


## Unshaded, glowing: lights, beacons, light bars.
static func emissive(color: Color, energy := 2.0) -> StandardMaterial3D:
	var key := "%s|%s" % [color, energy]
	if not _emis.has(key):
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = color
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = energy
		if color.a < 1.0:
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_emis[key] = m
	return _emis[key]


# ====================================================================== terrain
## Per-vertex colour: grass, drying with height, rock on steep or high ground,
## sand at the shore, seabed below the water (render/models.py terrain_colors;
## the jitter is a hash instead of numpy's normal stream).
static func terrain_colors(world: World, step := 1) -> PackedColorArray:
	var h := world.terrain.get_heights()
	var G := World.GRID
	var out := PackedColorArray()
	var dry := Vector3(0.55, 0.52, 0.30)
	var rock := Vector3(0.45, 0.42, 0.40)
	var sand := Vector3(0.83, 0.77, 0.55)
	for j in range(0, G, step):
		for i in range(0, G, step):
			var z: float = h[j * G + i]
			var gx: float = (h[j * G + mini(i + 1, G - 1)] - h[j * G + maxi(i - 1, 0)]) / (World.CELL * (mini(i + 1, G - 1) - maxi(i - 1, 0)))
			var gy: float = (h[mini(j + 1, G - 1) * G + i] - h[maxi(j - 1, 0) * G + i]) / (World.CELL * (mini(j + 1, G - 1) - maxi(j - 1, 0)))
			var slope := sqrt(gx * gx + gy * gy)
			var jit := (fposmod(sin(i * 12.9898 + j * 78.233) * 43758.5453, 1.0) - 0.5) * 0.08
			var col := Vector3(0.28 + jit, 0.47 + jit * 1.5, 0.18 + jit)
			col = col.lerp(dry, clampf((z - 250) / 500, 0, 1))
			var t_rock := maxf(clampf((slope - 0.35) / 0.4, 0, 1), clampf((z - 850) / 250, 0, 1))
			col = col.lerp(rock, t_rock)
			col = col.lerp(sand, clampf((6 - z) / 4, 0, 1))
			if z < -2:
				col = Vector3(0.55, 0.60, 0.45)
			out.append(Color(clampf(col.x, 0, 1), clampf(col.y, 0, 1), clampf(col.z, 0, 1)))
	return out


static func build_terrain(world: World, q: Quality) -> MeshInstance3D:
	var step := q.terrain_step
	var G := World.GRID
	var h := world.terrain.get_heights()
	var n := (G - 1) / step + 1
	var verts := PackedVector3Array()
	var nrms := PackedVector3Array()
	verts.resize(n * n)
	nrms.resize(n * n)
	var cell := World.CELL * step
	for jj in n:
		for ii in n:
			var i := ii * step
			var j := jj * step
			var z: float = h[j * G + i]
			verts[jj * n + ii] = Vector3(-World.HALF + i * World.CELL, z, -(-World.HALF + j * World.CELL))
			var zl: float = h[j * G + maxi(i - step, 0)]
			var zr: float = h[j * G + mini(i + step, G - 1)]
			var zd: float = h[maxi(j - step, 0) * G + i]
			var zu: float = h[mini(j + step, G - 1) * G + i]
			var gx := (zr - zl) / (2 * cell)
			var gy := (zu - zd) / (2 * cell)
			nrms[jj * n + ii] = Vector3(-gx, 1.0, gy).normalized()  # game (-gx, -gy, 1) -> godot (x, z, -y)
	var idx := PackedInt32Array()
	idx.resize((n - 1) * (n - 1) * 6)
	var k := 0
	for jj in n - 1:
		for ii in n - 1:
			var a := jj * n + ii
			var b := a + 1
			var c := a + n + 1
			var d := a + n
			# game-frame CCW (a, b, c), (a, c, d) -> Godot clockwise front faces
			idx[k] = a; idx[k + 1] = c; idx[k + 2] = b
			idx[k + 3] = a; idx[k + 4] = d; idx[k + 5] = c
			k += 6
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = nrms
	arr[Mesh.ARRAY_COLOR] = terrain_colors(world, step)
	arr[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mi := MeshInstance3D.new()
	mi.name = "terrain"
	mi.mesh = am
	if q.shaded:
		var m := ShaderMaterial.new()
		m.shader = load("res://shaders/terrain.gdshader")
		mi.material_override = m
	else:
		mi.material_override = vertex_material()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if q.shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


static func build_water(q: Quality, size := 90000.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "water"
	var pm := PlaneMesh.new()
	pm.size = Vector2(size, size)
	mi.mesh = pm
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if q.shaded:
		var m := ShaderMaterial.new()
		m.shader = load("res://shaders/water.gdshader")
		m.set_shader_parameter("anim", 1.0 if q.water_anim else 0.0)
		mi.material_override = m
	else:
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.12, 0.33, 0.52, 0.88)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.roughness = 0.3
		mi.material_override = m
	return mi


## Trees as two MultiMeshes (foliage tinted per instance, trunks), one draw call
## each instead of Python's 8000-cone merged mesh.
static func build_trees(world: World, q: Quality) -> Node3D:
	var root := Node3D.new()
	root.name = "trees"
	var trees := world.terrain.get_trees()
	var count := trees.size() / 4
	var keep := []
	for k in count:
		var ht: float = trees[k * 4 + 3]
		if k % q.tree_keep == 0 or ht >= 21:  # keep the deliberate tree lines at strip ends
			keep.append(k)
	# unit tree: height 1, origin at the ground
	var fol := MeshBuilder.new()
	fol.cone(0, 0, 0.2, 0.28, 0.8, [1, 1, 1], q.tree_segments)
	if q.tree_segments > 5:
		fol.cone(0, 0, 0.5, 0.2, 0.55, [1.1, 1.1, 1.1], q.tree_segments)
	var trunk := MeshBuilder.new()
	trunk.cone(0, 0, -0.02, 0.06, 0.25, [0.30, 0.22, 0.12], 3)
	var fm := MultiMesh.new()
	fm.transform_format = MultiMesh.TRANSFORM_3D
	fm.use_colors = true
	fm.mesh = fol.mesh()
	fm.instance_count = keep.size()
	var tm := MultiMesh.new()
	tm.transform_format = MultiMesh.TRANSFORM_3D
	tm.mesh = trunk.mesh()
	tm.instance_count = keep.size()
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for n in keep.size():
		var k: int = keep[n]
		var x: float = trees[k * 4]
		var y: float = trees[k * 4 + 1]
		var z: float = trees[k * 4 + 2]
		var ht: float = trees[k * 4 + 3]
		var g := rng.randf_range(0.75, 1.1)
		var hue := rng.randf_range(-0.03, 0.03)
		var b := Basis.from_euler(Vector3(0, rng.randf() * TAU, 0)).scaled(Vector3(ht, ht, ht))
		var t := Transform3D(b, Vector3(x, z, -y))
		fm.set_instance_transform(n, t)
		fm.set_instance_color(n, Color(0.10 * g + hue, 0.28 * g, 0.12 * g - hue))
		tm.set_instance_transform(n, t)
	var fmi := MultiMeshInstance3D.new()
	fmi.multimesh = fm
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.95
	fmi.material_override = mat
	fmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if q.shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(fmi)
	var tmi := MultiMeshInstance3D.new()
	tmi.multimesh = tm
	tmi.material_override = vertex_material()
	root.add_child(tmi)
	return root


const SURFACE_COLORS := {
	"asphalt": [0.20, 0.20, 0.22],
	"gravel": [0.52, 0.49, 0.44],
	"grass": [0.36, 0.55, 0.26],
	"dirt": [0.50, 0.38, 0.25],
	"sand": [0.88, 0.82, 0.62],
}


## Runway, markings, edge cones, buildings, windsock, plus edge lights (lit at
## night by WorldScene) as a separate node so they can glow.
static func build_airfield(world: World, af: Airfield, q: Quality) -> Node3D:
	var mb := MeshBuilder.new()
	var lights := MeshBuilder.new()
	var z := world.airfield_elev(af) + 0.12
	var ux := af.ux
	var uy := af.uy
	var px := uy
	var py := -ux
	var p := func(a: float, c: float, dz := 0.0) -> Array:
		return [af.x + ux * a + px * c, af.y + uy * a + py * c, z + dz]
	var L := af.length / 2
	var W := af.width / 2
	mb.quad(p.call(-L, -W), p.call(-L, W), p.call(L, W), p.call(L, -W), SURFACE_COLORS[af.surface])
	var white := [0.95, 0.95, 0.95]
	if af.surface == "asphalt":
		var a := -L + 60
		while a < L - 60:
			mb.quad(p.call(a, -0.45, 0.02), p.call(a, 0.45, 0.02), p.call(a + 30, 0.45, 0.02), p.call(a + 30, -0.45, 0.02), white)
			a += 50
		for end in [-1, 1]:
			for k in range(-4, 5):
				if k == 0:
					continue
				var c0 := k * W / 5.2
				var a0: float = end * (L - 6)
				var a1: float = end * (L - 36)
				mb.quad(p.call(minf(a0, a1), c0 - 0.9, 0.02), p.call(minf(a0, a1), c0 + 0.9, 0.02),
					p.call(maxf(a0, a1), c0 + 0.9, 0.02), p.call(maxf(a0, a1), c0 - 0.9, 0.02), white)
	var orange := [1.0, 0.45, 0.05]
	var a2 := -L
	while a2 <= L + 0.1:
		for side in [-1, 1]:
			var e: Array = p.call(a2, side * (W + 1.5))
			mb.cone(e[0], e[1], z, 0.6, 1.0, white if int(a2) % 80 else orange, 4)
			lights.box(e[0], e[1], z + 1.15, 0.35, 0.35, 0.3, [1.0, 0.85, 0.5])
		a2 += 40
	for end in [-1, 1]:
		for side in range(-3, 4):
			var e: Array = p.call(end * (L + 3), side * W / 3.5)
			mb.box(e[0], e[1], z + 0.4, 1.2, 1.2, 0.8, orange)
			# threshold lights: green facing in on both ends
			lights.box(e[0], e[1], z + 0.9, 0.4, 0.4, 0.25, [0.2, 1.0, 0.3])
	# the buildings are Buildings.airfield_site (walkable, with colliders)
	var ws: Array = p.call(-L * 0.7, -W - 12)
	mb.box(ws[0], ws[1], z + 3, 0.2, 0.2, 6, [0.6, 0.6, 0.6])
	mb.box(ws[0] + 1.2, ws[1], z + 5.8, 2.4, 0.5, 0.5, orange)
	var root := Node3D.new()
	root.name = "af-" + af.code
	var body := mb.node("field")
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if q.shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(body)
	var lit := lights.node("lights", emissive(Color(1, 1, 1), 3.0))
	var lm := StandardMaterial3D.new()
	lm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lm.vertex_color_use_as_albedo = true
	lm.emission_enabled = true
	lm.emission_energy_multiplier = 3.0
	lit.material_override = lm
	lit.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	lit.visible = false  # WorldScene switches them on at dusk
	root.add_child(lit)
	return root


static func build_beacon(height := 260.0, radius := 6.0, color := Color(0.2, 1.0, 0.3, 0.35)) -> MeshInstance3D:
	var mb := MeshBuilder.new()
	mb.cylinder(0, 0, 0, radius, height, [color.r, color.g, color.b, color.a], 12)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.no_depth_test = false
	var mi := mb.node("beacon", m)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


## North-up minimap image (terrain colours, shaded by height, sea blue).
static func minimap_image(world: World, size := 256) -> Image:
	var img := Image.create(size, size, false, Image.FORMAT_RGB8)
	var cols := terrain_colors(world)
	var h := world.terrain.get_heights()
	var G := World.GRID
	for py in size:
		var row := int(float(size - 1 - py) / (size - 1) * (G - 1))
		for px in size:
			var c := int(float(px) / (size - 1) * (G - 1))
			var z: float = h[row * G + c]
			if z < 0:
				img.set_pixel(px, py, Color(0.12, 0.3, 0.5))
			else:
				var col: Color = cols[row * G + c]
				var shade := 0.85 + 0.15 * minf(1.0, z / 900)
				img.set_pixel(px, py, Color(col.r * shade, col.g * shade, col.b * shade))
	return img


# ====================================================================== aircraft
static func _c(col: Color) -> Array:
	return [col.r, col.g, col.b]


## Origin at the CG, forward -Z. Returns [root, props, lights] where lights is
## {"nav": [nodes], "landing": SpotLight3D or null, "strobe": node}.
static func build_aircraft(v: Aircraft.Visual, gear_height_m: float, q: Quality = null) -> Array:
	var root := Node3D.new()
	root.name = "aircraft"
	var mb := MeshBuilder.new()
	var L := v.length_m
	var S := v.span_m
	var fw := L * 0.075
	var fh := L * 0.085
	var body := _c(v.color)
	var stripe := _c(v.stripe)
	var glass := [0.2, 0.3, 0.4]
	var cz := 0.25
	var nose_y := L * 0.38
	var tail_y := -L * 0.62
	mb.frustum(nose_y - L * 0.14, nose_y, [0, cz, fw, fh], [0, cz - 0.05, fw * 0.55, fh * 0.6], body)
	mb.frustum(-L * 0.12, nose_y - L * 0.14, [0, cz, fw, fh], [0, cz, fw, fh], body)
	mb.frustum(tail_y, -L * 0.12, [0, cz + fh * 0.55, fw * 0.18, fh * 0.28], [0, cz, fw, fh], body)
	mb.frustum(nose_y - L * 0.2, nose_y - L * 0.135, [0, cz + fh * 0.8, fw * 1.01, fh * 0.35], [0, cz + fh * 0.6, fw * 0.85, fh * 0.3], glass)
	mb.box(0, -L * 0.02, cz + fh * 0.45, fw * 2.03, L * 0.14, fh * 0.45, glass)
	mb.box(0, -L * 0.1, cz - fh * 0.2, fw * 2.04, L * 0.55, fh * 0.18, stripe)
	var chord := S * 0.14
	var wz := cz + fh + 0.08 if v.wing == "high" else cz - fh * 0.8
	var wy := nose_y - L * 0.3
	mb.box(0, wy, wz, S, chord, 0.16, body)
	mb.box(S * 0.47, wy, wz + 0.01, S * 0.06, chord * 1.01, 0.17, stripe)
	mb.box(-S * 0.47, wy, wz + 0.01, S * 0.06, chord * 1.01, 0.17, stripe)
	if v.wing == "high":
		for side in [-1, 1]:
			mb.frustum(wy - 0.05, wy + 0.05, [side * fw, cz - fh * 0.6, 0.05, 0.05], [side * S * 0.28, wz, 0.05, 0.05], [0.7, 0.7, 0.7])
	mb.box(0, tail_y + 0.35, cz + fh * 0.55, S * 0.36, chord * 0.75, 0.1, body)
	mb.frustum(tail_y + 0.05, tail_y + chord * 0.9, [0, cz + fh * 0.55 + L * 0.09, 0.06, L * 0.09], [0, cz + fh * 0.55 + L * 0.05, 0.06, L * 0.05], body)
	mb.box(0, tail_y + 0.4, cz + fh * 0.55 + L * 0.13, 0.13, chord * 0.5, L * 0.05, stripe)
	var engine_pos := []
	if v.engines == 1:
		engine_pos.append([0.0, nose_y + 0.05, cz - 0.05])
	else:
		for side in [-1, 1]:
			var ex: float = side * S * 0.2
			mb.frustum(wy - chord * 0.9, wy + chord * 0.9, [ex, wz - 0.1, 0.32, 0.32], [ex, wz - 0.1, 0.28, 0.3], body)
			engine_pos.append([ex, wy + chord * 0.9 + 0.05, wz - 0.1])
	var gz := -gear_height_m
	var tire := [0.08, 0.08, 0.08]
	var main_y := -L * 0.06
	for side in [-1, 1]:
		mb.frustum(main_y - 0.06, main_y + 0.06, [side * fw, cz - fh, 0.05, 0.05], [side * fw * 2.2, gz + 0.3, 0.05, 0.05], [0.6, 0.6, 0.6])
		mb.box(side * fw * 2.2, main_y, gz + 0.3, 0.18, 0.6, 0.6, tire)
	if v.tricycle:
		mb.box(0, nose_y - L * 0.08, (cz + gz) / 2, 0.08, 0.08, cz - gz - 0.3, [0.6, 0.6, 0.6])
		mb.box(0, nose_y - L * 0.08, gz + 0.25, 0.14, 0.5, 0.5, tire)
	var frame := mb.node("airframe")
	frame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	root.add_child(frame)
	var props := []
	for e in engine_pos:
		var pm := MeshBuilder.new()
		var r := 0.95 if v.engines == 1 else 1.2
		pm.box(0, 0, 0, r * 2, 0.06, 0.14, [0.12, 0.12, 0.12])
		pm.box(0, 0.06, 0, 0.25, 0.2, 0.25, [0.8, 0.8, 0.8])
		var prop := pm.node("prop")
		prop.position = MeshBuilder.to_godot(e)
		root.add_child(prop)
		# prop disc: a faint blur shown instead of the blades at high rpm
		var disc := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = r
		cyl.bottom_radius = r
		cyl.height = 0.02
		cyl.radial_segments = 24
		disc.mesh = cyl
		disc.rotation = Vector3(PI / 2, 0, 0)
		var dm := StandardMaterial3D.new()
		dm.albedo_color = Color(0.15, 0.15, 0.15, 0.22)
		dm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		disc.material_override = dm
		disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		disc.name = "disc"
		disc.visible = false
		prop.add_child(disc)
		props.append(prop)
	# navigation lights: red port, green starboard, white tail; a strobe; landing light
	var lights := {"nav": [], "landing": null, "strobe": null}
	for spec in [[-S / 2, [1, 0.1, 0.1]], [S / 2, [0.1, 1, 0.2]]]:
		var lb := MeshBuilder.new()
		lb.box(0, 0, 0, 0.18, 0.18, 0.12, spec[1])
		var ln := lb.node("nav", emissive(Color(spec[1][0], spec[1][1], spec[1][2]), 4.0))
		ln.position = MeshBuilder.to_godot([spec[0], wy, wz])
		ln.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(ln)
		lights["nav"].append(ln)
	var sb := MeshBuilder.new()
	sb.box(0, 0, 0, 0.16, 0.16, 0.16, [1, 1, 1])
	var strobe := sb.node("strobe", emissive(Color(1, 1, 1), 6.0))
	strobe.position = MeshBuilder.to_godot([0, tail_y + 0.3, cz + fh * 0.55 + L * 0.16])
	strobe.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(strobe)
	lights["strobe"] = strobe
	if q != null and q.real_lights:
		var spot := SpotLight3D.new()
		spot.name = "landing_light"
		spot.position = MeshBuilder.to_godot([0, nose_y - L * 0.25, wz - 0.1])
		spot.rotation = Vector3(deg_to_rad(-6), 0, 0)
		spot.spot_range = 900
		spot.spot_angle = 14
		spot.light_energy = 6
		spot.light_color = Color(1, 0.95, 0.85)
		spot.visible = false
		root.add_child(spot)
		lights["landing"] = spot
	return [root, props, lights]


## Returns [root, rotors/props, light-bar nodes].
static func build_pursuer(kind: String, q: Quality = null) -> Array:
	var root := Node3D.new()
	root.name = kind
	var lights := []
	var spinners := []
	var bar_z := 0.0
	var bar_y := 0.0
	if kind == "heli":
		var mb := MeshBuilder.new()
		var blue := [0.08, 0.15, 0.55]
		var white := [0.93, 0.93, 0.95]
		mb.frustum(-1.5, 2.2, [0, 0, 1.0, 1.1], [0, -0.1, 0.7, 0.8], white)
		mb.frustum(2.2, 3.0, [0, -0.1, 0.7, 0.8], [0, -0.3, 0.2, 0.3], [0.2, 0.3, 0.4])
		mb.box(0, 0.3, -0.4, 2.02, 3.6, 0.35, blue)
		mb.frustum(-7.5, -1.5, [0, 0.4, 0.15, 0.2], [0, 0.2, 0.45, 0.5], blue)
		mb.box(0, -7.3, 1.1, 0.1, 0.8, 1.6, blue)
		for side in [-1, 1]:
			mb.box(side * 1.1, 0, -1.6, 0.12, 4.0, 0.12, [0.2, 0.2, 0.2])
		mb.box(0, 0, 1.3, 0.3, 0.3, 0.5, [0.3, 0.3, 0.3])
		root.add_child(mb.node("heli"))
		var rm := MeshBuilder.new()
		rm.box(0, 0, 0, 10.5, 0.35, 0.06, [0.1, 0.1, 0.1])
		rm.box(0, 0, 0, 0.35, 10.5, 0.06, [0.1, 0.1, 0.1])
		var rotor := rm.node("rotor")
		rotor.position = Vector3(0, 1.6, 0)
		root.add_child(rotor)
		spinners.append(rotor)
		bar_z = 1.15
		bar_y = 1.0
		if q != null and q.real_lights:
			var spot := SpotLight3D.new()  # the "Nightsun" searchlight
			spot.name = "searchlight"
			spot.position = Vector3(0, -1.2, -1.5)
			spot.rotation = Vector3(deg_to_rad(-55), 0, 0)
			spot.spot_range = 1200
			spot.spot_angle = 6
			spot.light_energy = 10
			spot.visible = false
			root.add_child(spot)
	elif kind == "interceptor":
		var mb := MeshBuilder.new()
		var body := [0.12, 0.16, 0.3]
		var dark := [0.05, 0.05, 0.08]
		mb.frustum(-6, 4, [0, 0, 0.8, 0.8], [0, 0, 0.6, 0.6], body)
		mb.frustum(4, 8, [0, 0, 0.6, 0.6], [0, -0.1, 0.05, 0.05], body)
		mb.frustum(1.5, 4.5, [0, 0.7, 0.45, 0.25], [0, 0.6, 0.2, 0.1], [0.3, 0.4, 0.5])
		for side in [-1, 1]:
			mb.tri([side * 0.6, 2.5, 0], [side * 5.5, -3.5, 0], [side * 0.6, -4.5, 0], body)
			mb.tri([side * 0.6, 2.5, 0], [side * 0.6, -4.5, 0], [side * 5.5, -3.5, 0], body)
		mb.frustum(-6, -2.5, [0, 1.9, 0.08, 1.2], [0, 0.9, 0.08, 0.2], dark)
		mb.box(0, -3.0, 0.02, 7, 1.8, 0.08, [0.9, 0.9, 0.9])
		root.add_child(mb.node("jet"))
		bar_z = 0.95
		bar_y = 0.0
	else:  # rival smugglers: a black twin
		var v := Aircraft.Visual.new("low", 2, 11.0, 12.5, Color(0.07, 0.07, 0.07), Color(0.6, 0.1, 0.6))
		var r := build_aircraft(v, 1.2, q)
		return [r[0], r[1], []]
	for k in 2:
		var spec: Array = [[-0.35, Color(1, 0.05, 0.05)], [0.35, Color(0.1, 0.3, 1)]][k]
		var lm := MeshBuilder.new()
		lm.box(0, 0, 0, 0.5, 0.3, 0.2, [1, 1, 1])
		var ln := lm.node("light%d" % k, emissive(spec[1], 5.0))
		ln.position = MeshBuilder.to_godot([spec[0], bar_y, bar_z])
		ln.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(ln)
		lights.append(ln)
	return [root, spinners, lights]


# ====================================================================== maritime
## Go-fast (long, low, loud) or Coast Guard cutter. Waterline at y=0. Returns [root, lights].
static func build_boat(kind: String) -> Array:
	var mb := MeshBuilder.new()
	var lights := []
	var root: Node3D
	if kind == "cutter":
		var hull := [0.92, 0.92, 0.94]
		var trim := [0.8, 0.15, 0.1]
		mb.frustum(-18, 14, [0, 0.8, 3.2, 1.6], [0, 1.2, 2.6, 1.8], hull)
		mb.frustum(14, 22, [0, 1.2, 2.6, 1.8], [0, 2.0, 0.2, 0.9], hull)
		mb.box(0, 8, 1.2, 5.3, 1.2, 1.5, trim)
		mb.box(0, -2, 4.4, 4.2, 10, 3.0, hull)
		mb.box(0, 1, 7.0, 2.2, 3, 2.2, [0.3, 0.35, 0.4])
		mb.box(0, -1, 9.5, 0.3, 0.3, 3.0, [0.2, 0.2, 0.2])
		root = mb.node("cutter")
		var lm := MeshBuilder.new()
		lm.box(0, 0, 0, 0.8, 0.8, 0.5, [1, 1, 1])
		var light := lm.node("beacon", emissive(Color(0.2, 0.4, 1), 5.0))
		light.position = MeshBuilder.to_godot([0, -1, 11.2])
		root.add_child(light)
		lights.append(light)
	else:
		var hull := [0.95, 0.95, 0.95]
		var deck := [0.85, 0.1, 0.25]
		mb.frustum(-5.5, 5, [0, 0.3, 1.2, 0.6], [0, 0.45, 1.0, 0.6], hull)
		mb.frustum(5, 8, [0, 0.45, 1.0, 0.6], [0, 0.8, 0.1, 0.25], hull)
		mb.box(0, 0, 1.0, 2.05, 9.5, 0.12, deck)
		mb.box(0, 0.5, 1.4, 1.6, 1.4, 0.8, [0.15, 0.2, 0.25])
		for side in [-0.45, 0.45]:
			mb.box(side, -5.9, 0.2, 0.35, 0.6, 1.0, [0.1, 0.1, 0.1])
		root = mb.node("gofast")
	return [root, lights]


static func build_bale() -> MeshInstance3D:
	var mb := MeshBuilder.new()
	mb.box(0, 0, 0.3, 0.9, 0.6, 0.6, [0.55, 0.45, 0.25])
	mb.box(0, 0, 0.3, 0.92, 0.1, 0.62, [0.2, 0.2, 0.2])
	return mb.node("bale")


## Tethered radar balloon: a fat white ellipsoid with fins, radome underneath.
static func build_aerostat() -> MeshInstance3D:
	var mb := MeshBuilder.new()
	var segs := 16
	var rings := 10
	var L := 70.0
	var R := 13.0
	var pts := []
	for r in rings + 1:
		var t := float(r) / rings
		var y := -L / 2 + t * L
		var rad := R * pow(sin(PI * t), 0.7)
		var ring := []
		for k in segs:
			ring.append([rad * cos(TAU * k / segs), y, rad * sin(TAU * k / segs)])
		pts.append(ring)
	var white := [0.95, 0.95, 0.93]
	for r in rings:
		for k in segs:
			mb.quad(pts[r][k], pts[r + 1][k], pts[r + 1][(k + 1) % segs], pts[r][(k + 1) % segs], white)
	for ang in [0, 120, 240]:
		var a := deg_to_rad(ang + 90)
		var tip := [cos(a) * R * 1.3, -L * 0.42, sin(a) * R * 1.3]
		mb.tri([0, -L * 0.3, 0], [0, -L * 0.48, 0], tip, [0.85, 0.85, 0.85])
		mb.tri([0, -L * 0.48, 0], [0, -L * 0.3, 0], tip, [0.85, 0.85, 0.85])
	mb.box(0, 0, -R - 2.5, 7, 7, 5, [0.8, 0.8, 0.8])
	return mb.node("aerostat")
