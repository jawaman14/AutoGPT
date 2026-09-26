class_name Buildings
extends RefCounted
## Buildings for the airfields and the three headquarters, authored in Godot
## coordinates (y up, local -z = the building's front). Every part is a PBR
## material with triplanar noise detail; every solid part also gets a box
## collider so the on-foot player can walk around, and into, them. Buildings
## expose interaction points (Area3D with meta "action") for the walker:
##   jobs     job board (hangar notice board)
##   load     fuel pump / load planner
##   hangar   aircraft dealer and gear
##   hq_org   the organisation's desk (the boss's orders)
##   hq_law   the task-force desk
##   hq_rival the cartel's table (what the organisation knows about Los Cuervos)

static var _mats := {}


static func mat(key: String) -> StandardMaterial3D:
	if _mats.has(key):
		return _mats[key]
	var specs := {
		"stucco": [Color(0.74, 0.69, 0.6), 0.9, 0.0],
		"stucco_pink": [Color(0.78, 0.58, 0.52), 0.9, 0.0],
		"terracotta": [Color(0.72, 0.33, 0.2), 0.8, 0.0],
		"concrete": [Color(0.55, 0.55, 0.53), 0.92, 0.0],
		"concrete_dark": [Color(0.42, 0.43, 0.44), 0.9, 0.0],
		"metal": [Color(0.72, 0.74, 0.76), 0.45, 0.8],
		"metal_rust": [Color(0.55, 0.36, 0.24), 0.7, 0.5],
		"wood": [Color(0.46, 0.32, 0.2), 0.85, 0.0],
		"glass": [Color(0.25, 0.35, 0.42, 0.55), 0.08, 0.2],
		"window_lit": [Color(1.0, 0.85, 0.55), 0.3, 0.0],
		"white": [Color(0.78, 0.78, 0.78), 0.6, 0.0],
		"red": [Color(0.75, 0.12, 0.1), 0.6, 0.0],
		"blue": [Color(0.12, 0.2, 0.55), 0.5, 0.2],
		"black": [Color(0.06, 0.06, 0.07), 0.5, 0.3],
		"water": [Color(0.2, 0.62, 0.72, 0.85), 0.05, 0.0],
		"asphalt": [Color(0.2, 0.2, 0.21), 0.95, 0.0],
		"orange": [Color(1.0, 0.45, 0.05), 0.6, 0.0],
		"green": [Color(0.2, 0.4, 0.2), 0.8, 0.0],
		"neon": [Color(1.0, 0.25, 0.7), 0.3, 0.0],
		"neon_cyan": [Color(0.2, 0.9, 1.0), 0.3, 0.0],
	}
	var s: Array = specs.get(key, specs["concrete"])
	var m := StandardMaterial3D.new()
	m.albedo_color = s[0]
	m.roughness = s[1]
	m.metallic = s[2]
	m.cull_mode = BaseMaterial3D.CULL_DISABLED  # you can walk inside
	if s[0].a < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if key in ["window_lit", "neon", "neon_cyan"]:
		m.emission_enabled = true
		m.emission = s[0]
		m.emission_energy_multiplier = 0.0  # WorldScene raises it at night
	if key not in ["glass", "window_lit", "water", "neon", "neon_cyan"]:
		m.normal_enabled = true
		m.normal_texture = TexGen.normal_pack()
		m.normal_scale = 0.5
		m.uv1_triplanar = true
		m.uv1_world_triplanar = true
		m.uv1_scale = Vector3(0.35, 0.35, 0.35)
	_mats[key] = m
	return m


## Night: light the windows.
static func set_night(night: float) -> void:
	mat("window_lit").emission_energy_multiplier = 2.2 * clampf((night - 0.3) / 0.5, 0.0, 1.0)
	for k in ["neon", "neon_cyan"]:  # the club's signs glow a little even by day
		mat(k).emission_energy_multiplier = 0.6 + 3.4 * clampf((night - 0.2) / 0.5, 0.0, 1.0)


# ------------------------------------------------------------------ kit
class Kit:
	var root: Node3D
	var body: StaticBody3D
	var st := {}  ## material key -> SurfaceTool

	func _init(name_: String) -> void:
		root = Node3D.new()
		root.name = name_
		body = StaticBody3D.new()
		body.name = "collision"
		root.add_child(body)

	func _tool(key: String) -> SurfaceTool:
		if not st.has(key):
			var t := SurfaceTool.new()
			t.begin(Mesh.PRIMITIVE_TRIANGLES)
			st[key] = t
		return st[key]

	func _quad(t: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
		var n := (b - a).cross(c - a).normalized()
		for p in [a, c, b, a, d, c]:
			t.set_normal(n)
			t.add_vertex(p)

	## Axis-aligned box (centre, size) in the building's frame.
	func box(c: Vector3, s: Vector3, key: String, collide := true) -> void:
		var h := s / 2
		var t := _tool(key)
		var p := [c + Vector3(-h.x, -h.y, -h.z), c + Vector3(h.x, -h.y, -h.z), c + Vector3(h.x, -h.y, h.z), c + Vector3(-h.x, -h.y, h.z),
			c + Vector3(-h.x, h.y, -h.z), c + Vector3(h.x, h.y, -h.z), c + Vector3(h.x, h.y, h.z), c + Vector3(-h.x, h.y, h.z)]
		_quad(t, p[0], p[1], p[2], p[3])  # bottom
		_quad(t, p[4], p[7], p[6], p[5])  # top
		_quad(t, p[0], p[4], p[5], p[1])  # -z
		_quad(t, p[1], p[5], p[6], p[2])  # +x
		_quad(t, p[2], p[6], p[7], p[3])  # +z
		_quad(t, p[3], p[7], p[4], p[0])  # -x
		if collide:
			var cs := CollisionShape3D.new()
			var bs := BoxShape3D.new()
			bs.size = s
			cs.shape = bs
			cs.position = c
			body.add_child(cs)

	## A wall from (x0,z0) to (x1,z1), with an optional doorway in the middle.
	func wall(x0: float, z0: float, x1: float, z1: float, y0: float, height: float, thick: float, key: String, door := 0.0, door_h := 2.4) -> void:
		var a := Vector2(x0, z0)
		var b := Vector2(x1, z1)
		var len := a.distance_to(b)
		var dir := (b - a) / len
		var pieces := [[0.0, len]]
		if door > 0:
			pieces = [[0.0, len / 2 - door / 2], [len / 2 + door / 2, len]]
			if height > door_h + 0.05:  # lintel over the door (a low wall's gate has none)
				var mid := a + dir * len / 2
				_seg(mid - dir * door / 2, mid + dir * door / 2, y0 + door_h, height - door_h, thick, key)
		for pc in pieces:
			if pc[1] - pc[0] > 0.05:
				_seg(a + dir * pc[0], a + dir * pc[1], y0, height, thick, key)

	func _seg(a: Vector2, b: Vector2, y0: float, h: float, thick: float, key: String) -> void:
		var c := (a + b) / 2
		var len := a.distance_to(b)
		var ang := atan2(b.y - a.y, b.x - a.x)
		var node := Node3D.new()
		# build as an axis-aligned box rotated about y: emit directly with a basis
		var basis := Basis(Vector3.UP, -ang)
		var h3 := Vector3(len / 2, h / 2, thick / 2)
		var cc := Vector3(c.x, y0 + h / 2, c.y)
		var t := _tool(key)
		var pts := []
		for sx in [-1, 1]:
			for sy in [-1, 1]:
				for sz in [-1, 1]:
					pts.append(cc + basis * Vector3(sx * h3.x, sy * h3.y, sz * h3.z))
		# pts index: (sx,sy,sz) -> ((sx+1)/2)*4 + ((sy+1)/2)*2 + (sz+1)/2
		var P := func(sx, sy, sz) -> Vector3: return pts[((sx + 1) / 2) * 4 + ((sy + 1) / 2) * 2 + (sz + 1) / 2]
		_quad(t, P.call(-1, -1, -1), P.call(1, -1, -1), P.call(1, -1, 1), P.call(-1, -1, 1))
		_quad(t, P.call(-1, 1, -1), P.call(-1, 1, 1), P.call(1, 1, 1), P.call(1, 1, -1))
		_quad(t, P.call(-1, -1, -1), P.call(-1, 1, -1), P.call(1, 1, -1), P.call(1, -1, -1))
		_quad(t, P.call(1, -1, -1), P.call(1, 1, -1), P.call(1, 1, 1), P.call(1, -1, 1))
		_quad(t, P.call(1, -1, 1), P.call(1, 1, 1), P.call(-1, 1, 1), P.call(-1, -1, 1))
		_quad(t, P.call(-1, -1, 1), P.call(-1, 1, 1), P.call(-1, 1, -1), P.call(-1, -1, -1))
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = h3 * 2
		cs.shape = bs
		cs.transform = Transform3D(basis, cc)
		body.add_child(cs)
		node.free()

	## Gable roof over a w x d footprint, ridge along z, eaves at y0.
	func gable(c: Vector3, w: float, d: float, rise: float, key: String, overhang := 0.6) -> void:
		var t := _tool(key)
		var hw := w / 2 + overhang
		var hd := d / 2 + overhang
		var r := Vector3(c.x, c.y + rise, c.z)
		_quad(t, c + Vector3(-hw, 0, -hd), c + Vector3(-hw, 0, hd), r + Vector3(0, 0, hd), r + Vector3(0, 0, -hd))
		_quad(t, c + Vector3(hw, 0, hd), c + Vector3(hw, 0, -hd), r + Vector3(0, 0, -hd), r + Vector3(0, 0, hd))
		# gable ends
		for sz in [-1, 1]:
			var a := c + Vector3(-hw + overhang, 0, sz * (hd - overhang))
			var b := c + Vector3(hw - overhang, 0, sz * (hd - overhang))
			var top := r + Vector3(0, 0, sz * (hd - overhang))
			var n: Vector3 = (b - a).cross(top - a).normalized() * (-sz)
			for p in ([a, top, b] if sz < 0 else [a, b, top]):
				t.set_normal(n)
				t.add_vertex(p)

	## Half-cylinder (Quonset) roof over a hangar, axis along z.
	func arch(c: Vector3, w: float, d: float, key: String, seg := 12) -> void:
		var t := _tool(key)
		var r := w / 2
		for k in seg:
			var a0 := PI * k / seg
			var a1 := PI * (k + 1) / seg
			var p0 := Vector3(c.x + r * cos(a0), c.y + r * sin(a0), 0)
			var p1 := Vector3(c.x + r * cos(a1), c.y + r * sin(a1), 0)
			_quad(t, p0 + Vector3(0, 0, c.z - d / 2), p0 + Vector3(0, 0, c.z + d / 2), p1 + Vector3(0, 0, c.z + d / 2), p1 + Vector3(0, 0, c.z - d / 2))
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3(w, 0.3, d)
		cs.shape = bs
		cs.position = Vector3(c.x, c.y + r, c.z)
		body.add_child(cs)

	func cylinder(c: Vector3, r: float, h: float, key: String, seg := 12, collide := true) -> void:
		var t := _tool(key)
		for k in seg:
			var a0 := TAU * k / seg
			var a1 := TAU * (k + 1) / seg
			var p0 := Vector3(c.x + r * cos(a0), c.y, c.z + r * sin(a0))
			var p1 := Vector3(c.x + r * cos(a1), c.y, c.z + r * sin(a1))
			_quad(t, p0, p1, p1 + Vector3(0, h, 0), p0 + Vector3(0, h, 0))
			for tri in [[Vector3(c.x, c.y + h, c.z), p1 + Vector3(0, h, 0), p0 + Vector3(0, h, 0)]]:
				for p in tri:
					t.set_normal(Vector3.UP)
					t.add_vertex(p)
		if collide:
			var cs := CollisionShape3D.new()
			var sh := CylinderShape3D.new()
			sh.radius = r
			sh.height = h
			cs.shape = sh
			cs.position = c + Vector3(0, h / 2, 0)
			body.add_child(cs)

	## An interaction point for the walker.
	func interact(p: Vector3, action: String, label: String, radius := 2.0) -> void:
		var a := Area3D.new()
		a.name = "use_" + action
		a.set_meta("action", action)
		a.set_meta("label", label)
		var cs := CollisionShape3D.new()
		var sp := SphereShape3D.new()
		sp.radius = radius
		cs.shape = sp
		a.add_child(cs)
		a.position = p
		a.collision_layer = 4
		a.collision_mask = 0
		a.monitorable = true
		root.add_child(a)

	## A warm ceiling lamp (interiors get no bounce light in the compatibility renderer).
	func lamp(p: Vector3, energy := 1.4, reach := 9.0) -> void:
		var l := OmniLight3D.new()
		l.name = "lamp"
		l.position = p
		l.light_color = Color(1.0, 0.86, 0.66)
		l.light_energy = energy
		l.omni_range = reach
		l.omni_attenuation = 1.2
		l.shadow_enabled = false
		l.distance_fade_enabled = true  # only the buildings you're near pay for their lamps
		l.distance_fade_begin = 150.0
		l.distance_fade_length = 50.0
		l.add_to_group("lamps")
		root.add_child(l)

	func finish() -> Node3D:
		for key in st:
			var t: SurfaceTool = st[key]
			var mi := MeshInstance3D.new()
			mi.name = key
			mi.mesh = t.commit()
			mi.material_override = Buildings.mat(key)
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if key in ["glass", "window_lit"] else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			root.add_child(mi)
		return root


# ------------------------------------------------------------------ pieces
static func _windows(k: Kit, x0: float, x1: float, z: float, y: float, n: int, facing := -1.0) -> void:
	for i in n:
		var x := lerpf(x0, x1, (i + 0.5) / n)
		k.box(Vector3(x, y, z + facing * 0.02), Vector3(1.1, 1.2, 0.08), "window_lit", false)


static func hangar(k: Kit, c: Vector3, w := 18.0, d := 20.0, with_board := true) -> void:
	k.box(c + Vector3(0, -0.1, 0), Vector3(w + 2, 0.2, d + 2), "concrete")  # floor pad
	k.wall(c.x - w / 2, c.z + d / 2, c.x + w / 2, c.z + d / 2, c.y, w / 2, 0.3, "metal")  # back wall
	k.arch(c + Vector3(0, 0.0, 0), w, d, "metal")
	for sx in [-1, 1]:  # arch feet
		k.box(c + Vector3(sx * (w / 2 - 0.2), 1.0, 0), Vector3(0.4, 2.0, d), "concrete_dark")
	if with_board:
		k.box(c + Vector3(w / 2 - 1.2, 1.5, d / 2 - 0.4), Vector3(2.0, 1.4, 0.1), "wood", false)
		k.interact(c + Vector3(w / 2 - 1.2, 1.0, d / 2 - 1.6), "jobs", "Job board")
		k.box(c + Vector3(-w / 2 + 2.0, 0.6, d / 2 - 1.2), Vector3(3.0, 1.2, 1.2), "wood")  # workbench
		k.interact(c + Vector3(-w / 2 + 2.0, 1.0, d / 2 - 2.6), "hangar", "Hangar: aircraft & gear")
	k.lamp(c + Vector3(0, w / 2 - 1.5, 2.0), 2.0, 16.0)


static func tower(k: Kit, c: Vector3, h := 14.0) -> void:
	k.box(c + Vector3(0, h / 2, 0), Vector3(4, h, 4), "concrete")
	k.box(c + Vector3(0, h + 1.4, 0), Vector3(6.5, 2.8, 6.5), "glass", false)
	k.box(c + Vector3(0, h + 2.95, 0), Vector3(7.2, 0.3, 7.2), "concrete_dark")
	k.cylinder(c + Vector3(0, h + 3.1, 0), 0.08, 5.0, "metal", 6, false)


static func fuel_pump(k: Kit, c: Vector3) -> void:
	k.box(c + Vector3(0, 0.1, 0), Vector3(3.5, 0.2, 2.5), "concrete")
	k.box(c + Vector3(0, 0.9, 0), Vector3(0.8, 1.6, 0.6), "red")
	k.box(c + Vector3(0, 1.8, 0), Vector3(1.0, 0.25, 0.8), "white", false)
	k.interact(c + Vector3(0, 1.0, -1.4), "load", "Fuel & load planner")


static func drums(k: Kit, c: Vector3, n := 5) -> void:
	for i in n:
		k.cylinder(c + Vector3((i % 3) * 0.7, 0, (i / 3) * 0.7), 0.3, 0.9, "blue" if i % 2 else "metal_rust", 10)
	k.interact(c + Vector3(0.7, 1.0, -1.4), "load", "Fuel drums & load planner")


static func shed(k: Kit, c: Vector3, w := 7.0, d := 5.0, key := "wood") -> void:
	k.box(c + Vector3(0, -0.1, 0), Vector3(w + 1, 0.2, d + 1), "concrete_dark")
	k.wall(c.x - w / 2, c.z - d / 2, c.x + w / 2, c.z - d / 2, c.y, 2.8, 0.2, key, 1.2, 2.2)
	k.wall(c.x - w / 2, c.z + d / 2, c.x + w / 2, c.z + d / 2, c.y, 2.8, 0.2, key)
	k.wall(c.x - w / 2, c.z - d / 2, c.x - w / 2, c.z + d / 2, c.y, 2.8, 0.2, key)
	k.wall(c.x + w / 2, c.z - d / 2, c.x + w / 2, c.z + d / 2, c.y, 2.8, 0.2, key)
	k.gable(c + Vector3(0, 2.8, 0), w, d, 1.4, "metal_rust")
	k.box(c + Vector3(w / 2 - 1.0, 1.5, d / 2 - 0.25), Vector3(1.4, 1.0, 0.08), "wood", false)
	k.interact(c + Vector3(w / 2 - 1.0, 1.0, d / 2 - 1.2), "jobs", "Job board")


static func terminal(k: Kit, c: Vector3, w := 36.0, d := 14.0) -> void:
	k.box(c + Vector3(0, -0.1, 0), Vector3(w + 6, 0.2, d + 8), "concrete")
	for side in [[-1, 2.6], [1, 0.0]]:
		k.wall(c.x - w / 2, c.z + side[0] * d / 2, c.x + w / 2, c.z + side[0] * d / 2, c.y, 6.0, 0.3, "stucco", side[1])
	k.wall(c.x - w / 2, c.z - d / 2, c.x - w / 2, c.z + d / 2, c.y, 6.0, 0.3, "stucco")
	k.wall(c.x + w / 2, c.z - d / 2, c.x + w / 2, c.z + d / 2, c.y, 6.0, 0.3, "stucco")
	k.box(c + Vector3(0, 6.2, 0), Vector3(w + 1.5, 0.4, d + 1.5), "concrete_dark")
	_windows(k, c.x - w / 2 + 2, c.x + w / 2 - 2, c.z - d / 2 - 0.15, c.y + 2.2, 8)
	_windows(k, c.x - w / 2 + 2, c.x + w / 2 - 2, c.z - d / 2 - 0.15, c.y + 4.4, 8)
	k.box(c + Vector3(-w / 4, 1.1, 0), Vector3(6, 1.1, 1.0), "wood")  # desk inside
	k.interact(c + Vector3(-w / 4, 1.0, -1.6), "jobs", "Freight desk: job board")
	k.interact(c + Vector3(w / 4, 1.0, -1.6), "hangar", "Aircraft sales & gear")
	k.lamp(c + Vector3(0, 3.0, 0.5), 1.4, 12.0)
	k.box(c + Vector3(w / 4, 1.1, 0), Vector3(6, 1.1, 1.0), "wood")


## The buildings beside one strip, in Godot coordinates, facing the runway.
static func airfield_site(world: World, af: Airfield) -> Node3D:
	var z := world.airfield_elev(af) + 0.12
	var k := Kit.new("site-" + af.code)
	# frame: origin beside the runway on its right-hand side, local -z faces the runway
	var W := af.width / 2
	var L := af.length / 2
	var off := W + 38.0
	match af.kind:
		"hub":
			terminal(k, Vector3(0, 0, 18), 36, 14)
			tower(k, Vector3(34, 0, 20), 16)
			hangar(k, Vector3(-38, 0, 14), 22, 24)
			hangar(k, Vector3(-64, 0, 14), 22, 24, false)
			fuel_pump(k, Vector3(14, 0, -6))
		"regional":
			terminal(k, Vector3(0, 0, 14), 20, 10)
			tower(k, Vector3(20, 0, 14), 10)
			hangar(k, Vector3(-26, 0, 12), 18, 20)
			fuel_pump(k, Vector3(10, 0, -6))
		"bush":
			shed(k, Vector3(0, 0, 8), 7, 5, "wood")
			drums(k, Vector3(7, 0, 4))
		_:
			shed(k, Vector3(0, 0, 8), 6, 4, "metal_rust")
			drums(k, Vector3(6, 0, 4), 7)
	var node := k.finish()
	for c in node.get_children():
		if c is Area3D:
			c.set_meta("field", af.code)
	# place: along = -L * 0.3 (the classic buildings' spot), across = +off to the right
	var along := -L * 0.3 if af.kind in ["hub", "regional"] else -L * 0.6
	var gx := af.x + af.ux * along + af.uy * off
	var gy := af.y + af.uy * along - af.ux * off
	node.position = Vector3(gx, z, -gy)
	# local -z must face the runway: the runway lies toward (-uy, +ux) from the site
	node.rotation.y = atan2(af.uy, af.ux)
	return node


# ------------------------------------------------------------------ headquarters
static func hq(world: World, spec: Dictionary) -> Node3D:
	var k := Kit.new("hq-" + spec.kind)
	match spec.get("style", ""):
		"nightclub":
			_nightclub(k)
		"customs":
			_task_force(k)
			_customs(k)
		"hacienda":
			_compound(k)
			_hacienda(k)
		_:
			match spec.kind:
				"org":
					_villa(k)
				"law":
					_task_force(k)
				_:
					_compound(k)
	var node := k.finish()
	var z := world.ground(spec.x, spec.y)
	node.position = Vector3(spec.x, z, -spec.y)
	node.rotation.y = -deg_to_rad(spec.heading)
	# a foundation down to the lowest ground under the footprint
	var low := z
	for d in [[-14, -14], [14, -14], [14, 14], [-14, 14]]:
		low = minf(low, world.ground(spec.x + d[0], spec.y + d[1]))
	var fk := Kit.new("foundation")
	fk.box(Vector3(0, (low - z) / 2 - 0.25, 0), Vector3(26, z - low + 0.5, 26), "concrete_dark")
	node.add_child(fk.finish())
	node.set_meta("hq", spec.kind)
	return node


## The organisation's villa: stucco, terracotta, a pool, a courtyard wall. The
## ground floor is open: the boss's desk (orders) and a map table.
static func _villa(k: Kit) -> void:
	var w := 16.0
	var d := 11.0
	k.box(Vector3(0, 0.05, 0), Vector3(28, 0.1, 26), "concrete")  # terrace
	# ground floor walls, doorway in the front (-z)
	k.wall(-w / 2, -d / 2, w / 2, -d / 2, 0, 3.4, 0.3, "stucco_pink", 1.8)
	k.wall(-w / 2, d / 2, w / 2, d / 2, 0, 3.4, 0.3, "stucco_pink")
	k.wall(-w / 2, -d / 2, -w / 2, d / 2, 0, 3.4, 0.3, "stucco_pink")
	k.wall(w / 2, -d / 2, w / 2, d / 2, 0, 3.4, 0.3, "stucco_pink")
	k.box(Vector3(0, 3.5, 0), Vector3(w + 0.4, 0.25, d + 0.4), "concrete")  # floor slab
	# upper floor and roof
	k.wall(-w / 2, -d / 2, w / 2, -d / 2, 3.6, 3.0, 0.3, "stucco_pink")
	k.wall(-w / 2, d / 2, w / 2, d / 2, 3.6, 3.0, 0.3, "stucco_pink")
	k.wall(-w / 2, -d / 2, -w / 2, d / 2, 3.6, 3.0, 0.3, "stucco_pink")
	k.wall(w / 2, -d / 2, w / 2, d / 2, 3.6, 3.0, 0.3, "stucco_pink")
	k.gable(Vector3(0, 6.6, 0), w, d, 2.6, "terracotta", 0.9)
	_windows(k, -w / 2 + 1.5, -1.5, -d / 2 - 0.16, 1.7, 2)
	_windows(k, 1.5, w / 2 - 1.5, -d / 2 - 0.16, 1.7, 2)
	_windows(k, -w / 2 + 1.5, w / 2 - 1.5, -d / 2 - 0.16, 5.1, 4)
	# inside: the desk and the map table
	k.box(Vector3(-4.0, 0.45, 2.8), Vector3(2.6, 0.9, 1.2), "wood")
	k.box(Vector3(-4.0, 0.6, 3.9), Vector3(0.7, 1.2, 0.7), "black")  # chair
	k.interact(Vector3(-4.0, 1.0, 1.6), "hq_org", "The boss's desk: tonight's orders")
	k.lamp(Vector3(-4.0, 3.0, 1.5))
	k.lamp(Vector3(3.5, 3.0, 0.0))
	k.box(Vector3(3.5, 0.5, 1.0), Vector3(3.0, 1.0, 2.0), "wood")
	k.box(Vector3(3.5, 1.02, 1.0), Vector3(2.8, 0.04, 1.8), "green", false)  # the map on the table
	k.interact(Vector3(3.5, 1.0, -0.6), "hq_rival", "Map table: what we know about Los Cuervos")
	# pool and courtyard
	k.box(Vector3(0, -0.3, -9.5), Vector3(8, 0.6, 4), "concrete_dark", false)
	k.box(Vector3(0, 0.02, -9.5), Vector3(7.4, 0.02, 3.4), "water", false)
	k.wall(-13, -13, 13, -13, 0, 1.6, 0.4, "stucco", 3.0)
	k.wall(-13, -13, -13, 12, 0, 1.6, 0.4, "stucco")
	k.wall(13, -13, 13, 12, 0, 1.6, 0.4, "stucco")
	k.box(Vector3(9, 0.7, -9), Vector3(4.2, 1.4, 1.9), "black")  # a black sedan
	k.box(Vector3(9, 1.6, -9), Vector3(2.4, 0.6, 1.8), "glass", false)


## The task-force HQ: a concrete block, flag, antenna, a turning radar dish,
## patrol cars. The duty desk inside is the task force's.
static func _task_force(k: Kit) -> void:
	var w := 24.0
	var d := 13.0
	k.box(Vector3(0, 0.05, -4), Vector3(34, 0.1, 30), "asphalt")
	for y in [0.0, 3.6]:
		k.wall(-w / 2, -d / 2, w / 2, -d / 2, y, 3.5, 0.35, "concrete", 2.2 if y == 0 else 0.0)
		k.wall(-w / 2, d / 2, w / 2, d / 2, y, 3.5, 0.35, "concrete")
		k.wall(-w / 2, -d / 2, -w / 2, d / 2, y, 3.5, 0.35, "concrete")
		k.wall(w / 2, -d / 2, w / 2, d / 2, y, 3.5, 0.35, "concrete")
		k.box(Vector3(0, y + 3.55, 0), Vector3(w + 0.4, 0.2, d + 0.4), "concrete_dark")
	_windows(k, -w / 2 + 1.2, -2.0, -d / 2 - 0.2, 1.8, 4)
	_windows(k, 2.0, w / 2 - 1.2, -d / 2 - 0.2, 1.8, 4)
	_windows(k, -w / 2 + 1.2, w / 2 - 1.2, -d / 2 - 0.2, 5.4, 8)
	k.box(Vector3(0, 7.4, 0), Vector3(w, 0.4, d), "concrete_dark")
	k.cylinder(Vector3(8, 7.6, 3), 0.12, 12.0, "metal", 6, false)  # antenna mast
	k.cylinder(Vector3(-8, 7.6, 2), 0.25, 2.0, "metal", 8, false)  # radar pedestal
	k.cylinder(Vector3(-14, 0, -9), 0.08, 9.0, "white", 6, false)  # flagpole
	k.box(Vector3(-13.2, 8.2, -9), Vector3(1.6, 1.0, 0.04), "blue", false)
	k.box(Vector3(-2.0, 0.55, 2.0), Vector3(4.0, 1.1, 1.2), "wood")
	k.interact(Vector3(-2.0, 1.0, 0.6), "hq_law", "Task-force duty desk")
	k.lamp(Vector3(-2.0, 3.0, 1.5))
	for i in 3:  # patrol cars
		k.box(Vector3(-6 + i * 5.5, 0.7, -12), Vector3(1.9, 1.4, 4.4), "white")
		k.box(Vector3(-6 + i * 5.5, 1.55, -12.3), Vector3(1.8, 0.1, 0.5), "blue", false)
		k.box(Vector3(-6 + i * 5.5, 1.5, -11.2), Vector3(1.7, 0.5, 1.8), "glass", false)


## Los Cuervos: a walled compound, a corrugated warehouse, a watchtower, trucks.
static func _compound(k: Kit) -> void:
	k.box(Vector3(0, 0.05, 0), Vector3(40, 0.1, 40), "concrete_dark")
	k.wall(-20, -20, 20, -20, 0, 3.2, 0.5, "concrete", 5.0, 3.2)
	k.wall(-20, 20, 20, 20, 0, 3.2, 0.5, "concrete")
	k.wall(-20, -20, -20, 20, 0, 3.2, 0.5, "concrete")
	k.wall(20, -20, 20, 20, 0, 3.2, 0.5, "concrete")
	hangar(k, Vector3(-5, 0, 6), 16, 18, false)
	k.box(Vector3(-5, 0.8, 4), Vector3(4, 1.6, 3), "wood")  # crates
	k.interact(Vector3(-5, 1.0, 1.2), "hq_rival", "Los Cuervos' warehouse")
	k.lamp(Vector3(-5, 3.2, 2.0), 1.0)
	for p in [[16, -16], [-16, 16]]:  # watchtowers
		for sx in [-1, 1]:
			for sz in [-1, 1]:
				k.box(Vector3(p[0] + sx * 1.2, 3.5, p[1] + sz * 1.2), Vector3(0.25, 7.0, 0.25), "wood")
		k.box(Vector3(p[0], 7.1, p[1]), Vector3(3.2, 0.2, 3.2), "wood")
		k.gable(Vector3(p[0], 9.0, p[1]), 3.0, 3.0, 1.0, "metal_rust", 0.3)
	for i in 2:
		k.box(Vector3(10, 1.2, -6 + i * 5), Vector3(2.4, 2.4, 6.5), "metal_rust")
		k.box(Vector3(10, 1.4, -9.8 + i * 5), Vector3(2.3, 1.8, 1.6), "black")


## The organisation's front: Club Tropicana, two storeys of pink stucco on a
## downtown corner, neon on the facade, a dance floor below and the boss's
## office above - reached by the stairs at the back. The desk (orders) and the
## map table (Los Cuervos) are in the office.
static func _nightclub(k: Kit) -> void:
	var w := 22.0
	var d := 16.0
	k.box(Vector3(0, 0.05, -2), Vector3(30, 0.1, 26), "concrete")  # the pavement
	for y in [0.0, 4.2]:
		k.wall(-w / 2, -d / 2, w / 2, -d / 2, y, 4.1, 0.3, "stucco_pink", 3.0 if y == 0 else 0.0)
		k.wall(-w / 2, d / 2, w / 2, d / 2, y, 4.1, 0.3, "stucco_pink")
		k.wall(-w / 2, -d / 2, -w / 2, d / 2, y, 4.1, 0.3, "stucco_pink")
		k.wall(w / 2, -d / 2, w / 2, d / 2, y, 4.1, 0.3, "stucco_pink", 1.4 if y == 0 else 0.0)
		k.box(Vector3(0, y + 4.15, 0), Vector3(w + 0.4, 0.2, d + 0.4), "concrete_dark")
	# neon: the name over the door, a stripe around the parapet
	k.box(Vector3(0, 5.6, -d / 2 - 0.25), Vector3(12, 1.6, 0.1), "neon", false)
	k.box(Vector3(0, 8.5, -d / 2 - 0.2), Vector3(w, 0.25, 0.1), "neon_cyan", false)
	k.box(Vector3(-w / 2 - 0.2, 8.5, 0), Vector3(0.1, 0.25, d), "neon_cyan", false)
	k.box(Vector3(w / 2 + 0.2, 8.5, 0), Vector3(0.1, 0.25, d), "neon_cyan", false)
	_windows(k, -w / 2 + 1.5, w / 2 - 1.5, -d / 2 - 0.16, 6.2, 6)
	# downstairs: the bar and the dance floor
	k.box(Vector3(-6, 0.55, 5.5), Vector3(8, 1.1, 1.2), "wood")
	k.box(Vector3(3, 0.03, 0), Vector3(9, 0.06, 9), "neon_cyan", false)
	k.lamp(Vector3(3, 3.4, 0), 1.6, 12.0)
	# the stairs at the back up to the office (a ramp the walker can climb)
	for i in 14:
		k.box(Vector3(w / 2 - 1.6, 0.15 + i * 0.3, -6 + i * 0.5), Vector3(2.4, 0.3, 0.5), "concrete_dark")
	k.box(Vector3(-3, 4.2 + 0.45, 3.5), Vector3(2.8, 0.9, 1.2), "wood")  # the boss's desk
	k.box(Vector3(-3, 4.2 + 0.6, 4.7), Vector3(0.7, 1.2, 0.7), "black")
	k.interact(Vector3(-3, 5.2, 2.2), "hq_org", "The boss's desk: tonight's orders")
	k.box(Vector3(4, 4.2 + 0.5, 2.0), Vector3(3.0, 1.0, 2.0), "wood")
	k.box(Vector3(4, 4.2 + 1.02, 2.0), Vector3(2.8, 0.04, 1.8), "green", false)
	k.interact(Vector3(4, 5.2, 0.4), "hq_rival", "Map table: what we know about Los Cuervos")
	k.lamp(Vector3(0, 7.6, 2.0))
	# a doorman's rope and the boss's car at the kerb
	k.box(Vector3(0, 0.5, -d / 2 - 2.0), Vector3(4, 1.0, 0.08), "red", false)
	k.box(Vector3(9, 0.7, -d / 2 - 4.5), Vector3(4.6, 1.4, 2.0), "black")
	k.box(Vector3(9, 1.6, -d / 2 - 4.5), Vector3(2.6, 0.6, 1.9), "glass", false)


## The customs house extras: a lattice radar tower and a customs launch at the quay.
static func _customs(k: Kit) -> void:
	for sx in [-1, 1]:
		for sz in [-1, 1]:
			k.box(Vector3(16 + sx * 1.5, 9.0, 4 + sz * 1.5), Vector3(0.35, 18.0, 0.35), "white", false)
	k.box(Vector3(16, 18.2, 4), Vector3(4.2, 0.4, 4.2), "white", false)
	k.cylinder(Vector3(16, 18.4, 4), 0.3, 1.4, "metal", 8, false)
	k.box(Vector3(16, 20.0, 4), Vector3(6.5, 0.9, 0.35), "metal", false)  # the antenna
	k.box(Vector3(0, 9.0, -6.6), Vector3(9, 1.1, 0.1), "blue", false)  # ADUANAS
	k.box(Vector3(-8, 0.7, -15.5), Vector3(3.0, 1.4, 11), "white")  # a customs launch hauled out
	k.box(Vector3(-8, 1.9, -14), Vector3(2.2, 1.0, 3.0), "blue", false)


## The hacienda: a long, low terracotta-roofed house inside the compound walls.
static func _hacienda(k: Kit) -> void:
	k.box(Vector3(6, 1.8, 13), Vector3(22, 3.6, 8), "stucco")
	k.gable(Vector3(6, 3.6, 13), 22, 8, 2.2, "terracotta", 0.9)
	for i in 5:  # the veranda posts
		k.box(Vector3(-3 + i * 4.5, 1.4, 8.4), Vector3(0.3, 2.8, 0.3), "wood")
	k.box(Vector3(6, 2.9, 8.4), Vector3(22, 0.2, 2.4), "terracotta", false)
	_windows(k, -3, 15, 8.9, 1.8, 4)
