class_name SquadRender
extends Node3D
## The ground war in 3D: every squad's men as low-poly figures (one MultiMesh
## of bodies per faction and one of heads, so a few hundred men cost a handful
## of draw calls), their cars and trucks, muzzle flashes while a firefight
## runs, and the fallen, who lie where they fell for a while.
##
## Fed squad dictionaries (GroundWar.Squad.dict(), the same shape the
## snapshots carry), so the host's view and a remote seat draw alike. The sim
## moves squads once a second; figures glide between those fixes. Men ride
## in their vehicle while it moves and get out around it when it stops.
##
## Two levels of detail. The nearest men (NEAR_N by quality, inside NEAR_M) are
## Kenney's Blocky Characters (ModelLib): the faction's looks, a gun from the
## squad's loadout at the chest, and the kit's animations - walking, running
## when routed, aiming, firing in a fight, falling. Everyone further out is a
## MultiMesh figure in the faction's colours. Vehicles are the Car Kit's.
## Without the model files everything falls back to the procedural boxes.
##
## The look is the 1980s coast: pastel suits for the organisation, loud shirts
## for Los Cuervos, navy for the task force, dark suits for the Family.

const RANGE_M := {"low": 800.0, "medium": 2500.0, "high": 3500.0}
const SUIT := {"org": Color(0.96, 0.72, 0.82), "rival": Color(0.98, 0.52, 0.16), "police": Color(0.13, 0.2, 0.46),
	"family": Color(0.16, 0.15, 0.17)}
const LEGS := {"org": Color(0.93, 0.93, 0.9), "rival": Color(0.2, 0.2, 0.22), "police": Color(0.1, 0.12, 0.2),
	"family": Color(0.12, 0.12, 0.13)}
const NEAR_N := {"low": 12, "medium": 40, "high": 64}  ## animated characters at most
const NEAR_M := 160.0
const FALLEN_NEAR := 16
const SKIN := Color(0.72, 0.52, 0.38)
const FALLEN_S := 180.0

var world: World
var range_m := 2500.0
var bodies := {}  ## faction -> MultiMeshInstance3D
var heads: MultiMeshInstance3D
var flashes: MultiMeshInstance3D
var dead: MultiMeshInstance3D
var vehicles := {}  ## squad id -> Node3D
var smooth := {}  ## squad id -> [Vector2 pos, heading rad]
var last_men := {}  ## squad id -> men (a drop leaves bodies)
var fallen: Array = []  ## [t, Vector3, faction, yaw]
var _rng := RandomNumberGenerator.new()
var _t := 0.0
var _was_fighting := {}  ## squad id -> faction, last frame
var men_pts: Array = []  ## [squad id, feet position] of every man drawn this frame (Gunplay aims at these)
var near_n := 40
var actors := {}  ## "squad#k" | "fallen#i" -> the character drawn up close


func setup(world_: World, quality: String) -> void:
	world = world_
	range_m = RANGE_M.get(quality, 2500.0)
	near_n = NEAR_N.get(quality, 40) if ModelLib.scene("characters/character-q") != null else 0
	_rng.seed = 11
	for f in SUIT:
		bodies[f] = _mmi(_body_mesh(f), "bodies-" + f)
	heads = _mmi(_head_mesh(), "heads")
	dead = _mmi(_body_mesh("org", true), "fallen")
	var q := QuadMesh.new()
	q.size = Vector2(0.9, 0.9)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.albedo_color = Color(1.0, 0.85, 0.4)
	m.emission_enabled = true
	m.emission = Color(1.0, 0.7, 0.25)
	m.emission_energy_multiplier = 6.0
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 0.95, 0.7, 1.0))
	grad.set_color(1, Color(1.0, 0.5, 0.1, 0.0))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 32
	tex.height = 32
	m.albedo_texture = tex
	q.material = m
	flashes = _mmi(q, "muzzle-flashes")


func _mmi(mesh: Mesh, name_: String) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = name_ == "fallen"
	mm.mesh = mesh
	mm.instance_count = 0
	var n := MultiMeshInstance3D.new()
	n.name = name_
	n.multimesh = mm
	n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# instances come and go every frame anywhere on the map: never cull the batch
	n.custom_aabb = AABB(Vector3(-20000, -200, -20000), Vector3(40000, 3000, 40000))
	add_child(n)
	return n


## A standing man, 1.8 m: legs, a jacket (the faction's colour), arms; origin at the feet.
static func _body_mesh(f: String, tinted := false) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var legs: Color = Color.WHITE if tinted else LEGS[f]
	var suit: Color = Color.WHITE if tinted else SUIT[f]
	_box(st, Vector3(-0.1, 0.42, 0), Vector3(0.16, 0.84, 0.2), legs)
	_box(st, Vector3(0.1, 0.42, 0), Vector3(0.16, 0.84, 0.2), legs)
	_box(st, Vector3(0, 1.17, 0), Vector3(0.46, 0.66, 0.26), suit)
	_box(st, Vector3(-0.3, 1.15, -0.08), Vector3(0.12, 0.6, 0.14), suit)
	_box(st, Vector3(0.3, 1.15, -0.08), Vector3(0.12, 0.6, 0.14), suit)
	_box(st, Vector3(0.12, 1.2, -0.42), Vector3(0.06, 0.08, 0.6), Color(0.08, 0.08, 0.09))  # the weapon, levelled forward
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = 0.8
	if tinted:
		m.albedo_color = Color(0.55, 0.5, 0.48)
	st.set_material(m)
	return st.commit()


static func _head_mesh() -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = 0.13
	s.height = 0.26
	s.radial_segments = 8
	s.rings = 4
	var m := StandardMaterial3D.new()
	m.albedo_color = SKIN
	m.roughness = 0.7
	s.material = m
	return s


static func _box(st: SurfaceTool, c: Vector3, s: Vector3, col: Color) -> void:
	var h := s / 2
	var p := [c + Vector3(-h.x, -h.y, -h.z), c + Vector3(h.x, -h.y, -h.z), c + Vector3(h.x, -h.y, h.z), c + Vector3(-h.x, -h.y, h.z),
		c + Vector3(-h.x, h.y, -h.z), c + Vector3(h.x, h.y, -h.z), c + Vector3(h.x, h.y, h.z), c + Vector3(-h.x, h.y, h.z)]
	for f in [[0, 1, 2, 3], [4, 7, 6, 5], [0, 4, 5, 1], [1, 5, 6, 2], [2, 6, 7, 3], [3, 7, 4, 0]]:
		var a: Vector3 = p[f[0]]
		var b: Vector3 = p[f[1]]
		var cc: Vector3 = p[f[2]]
		var d: Vector3 = p[f[3]]
		var n := (b - a).cross(cc - a).normalized()
		for v in [a, cc, b, a, d, cc]:
			st.set_color(col)
			st.set_normal(n)
			st.add_vertex(v)


## A vehicle for a squad: length along -Z (Godot forward), origin at the road.
static func vehicle(faction: String, kind: String) -> Node3D:
	var model := ModelLib.car(faction, kind)
	if model != null:
		return model
	return box_vehicle(faction, kind)


## The procedural fallback: boxes in the faction's paint.
static func box_vehicle(faction: String, kind: String) -> Node3D:
	var k := Buildings.Kit.new("vehicle-%s-%s" % [faction, kind])
	var wheel := func(x: float, z: float): k.box(Vector3(x, 0.34, z), Vector3(0.28, 0.68, 0.68), "black", false)
	if kind == "truck":
		var paint := "black" if faction == "police" else ("white" if faction == "org" else "metal_rust")
		k.box(Vector3(0, 1.0, -2.6), Vector3(2.3, 1.5, 1.8), paint, false)  # cab
		k.box(Vector3(0, 1.1, -2.85), Vector3(2.1, 0.7, 1.4), "glass", false)
		k.box(Vector3(0, 1.75, 1.0), Vector3(2.4, 2.5, 5.2), "white" if faction != "police" else "blue", false)  # box
		for z in [-2.6, 0.2, 2.6]:
			wheel.call(-1.1, z)
			wheel.call(1.1, z)
		if faction == "police":
			k.box(Vector3(0, 3.05, 1.0), Vector3(2.0, 0.1, 3.0), "white", false)  # SWAT roof marking
	elif faction == "org":
		# the white wedge: low, wide, a long rear deck
		k.box(Vector3(0, 0.62, 0), Vector3(1.95, 0.5, 4.5), "white", false)
		k.box(Vector3(0, 1.02, 0.2), Vector3(1.6, 0.34, 1.9), "glass", false)
		k.box(Vector3(0, 0.66, 2.24), Vector3(1.9, 0.12, 0.08), "red", false)  # tail-light bar
		k.box(Vector3(0, 0.5, -2.24), Vector3(1.9, 0.1, 0.06), "black", false)
		for z in [-1.45, 1.45]:
			wheel.call(-0.95, z)
			wheel.call(0.95, z)
	elif faction == "rival":
		# a red pickup
		k.box(Vector3(0, 0.85, -0.9), Vector3(1.9, 0.9, 2.6), "red", false)
		k.box(Vector3(0, 1.55, -0.6), Vector3(1.8, 0.6, 1.5), "glass", false)
		k.box(Vector3(0, 0.75, 1.5), Vector3(1.9, 0.7, 2.0), "red", false)
		k.box(Vector3(0, 1.05, 1.5), Vector3(1.6, 0.1, 1.8), "black", false)
		for z in [-1.5, 1.5]:
			wheel.call(-0.95, z)
			wheel.call(0.95, z)
	else:
		# a patrol car: white, blue doors, a light bar
		k.box(Vector3(0, 0.8, 0), Vector3(1.85, 0.7, 4.8), "white", false)
		k.box(Vector3(0, 1.4, 0.2), Vector3(1.7, 0.55, 2.4), "glass", false)
		k.box(Vector3(0.93, 0.85, 0), Vector3(0.02, 0.45, 1.8), "blue", false)
		k.box(Vector3(-0.93, 0.85, 0), Vector3(0.02, 0.45, 1.8), "blue", false)
		k.box(Vector3(-0.3, 1.74, 0.2), Vector3(0.5, 0.14, 0.3), "red", false)
		k.box(Vector3(0.3, 1.74, 0.2), Vector3(0.5, 0.14, 0.3), "blue", false)
		for z in [-1.5, 1.5]:
			wheel.call(-0.95, z)
			wheel.call(0.95, z)
	var n := k.finish()
	var col = n.get_node_or_null("collision")
	if col != null:
		col.free()
	return n


## Draw the squads: `squads` are dicts, `fights` [{x, y, a, b}], `cam` the camera.
func sync(squads: Array, fights: Array, cam: Vector3, now: float, dt: float) -> void:
	_t = now
	var seen := {}
	var men_by := {}
	for f in SUIT:
		men_by[f] = []
	var head_xf := []
	var flash_xf := []
	var entries := []  ## every man: [key, faction, look, Transform3D, anim, tier, dist]
	men_pts = []
	var fighting := {}
	for fx in fights:
		fighting[fx.a] = Vector2(fx.x, fx.y)
		fighting[fx.b] = Vector2(fx.x, fx.y)
	for d in squads:
		var id: String = d.id
		seen[id] = true
		var target := Vector2(d.x, d.y)
		if not smooth.has(id):
			smooth[id] = [target, 0.0]
		var sp: Array = smooth[id]
		var cur: Vector2 = sp[0]
		var step := target - cur
		if step.length() > 1.0:
			sp[1] = atan2(step.x, step.y)  # heading from north, clockwise
		# glide: close most of the gap each second, snap if it's a jump
		sp[0] = target if step.length() > 400.0 else cur + step * clampf(dt * 1.5, 0.0, 1.0)
		var p: Vector2 = sp[0]
		var g3 := Vector3(p.x, world.ground(p.x, p.y), -p.y)
		# the fallen: men lost since last frame lie where they fell
		var men: int = int(d.men)
		if last_men.has(id) and men < last_men[id]:
			for k in last_men[id] - men:
				var off := Vector2(_rng.randf_range(-6, 6), _rng.randf_range(-6, 6))
				fallen.append([now, Vector3(p.x + off.x, world.ground(p.x + off.x, p.y + off.y), -(p.y + off.y)), d.faction, _rng.randf() * TAU])
		last_men[id] = men
		if g3.distance_to(cam) > range_m:
			_hide_vehicle(id)
			continue
		var moving: bool = d.state in ["moving", "routed"] and step.length() > 0.5
		var riding: bool = d.kind != "foot" and moving
		if d.kind != "foot":
			if not vehicles.has(id):
				var v := vehicle(d.faction, d.kind)
				add_child(v)
				vehicles[id] = v
			var v: Node3D = vehicles[id]
			v.visible = true
			v.position = g3 + Vector3(0, 0.45, 0)  # the roads are draped 0.45 m up
			v.rotation = Vector3(0, -sp[1], 0)
		if riding or bool(d.hidden) and d.faction != "police" and cam.distance_to(g3) > 150.0:
			continue  # in the car, or melted into the crowd
		var yaw: float = -sp[1]
		if fighting.has(id):
			var e: Vector2 = fighting[id]
			yaw = -atan2(e.x - p.x, e.y - p.y)  # face the fight (the model faces -Z)
		var basis := Basis(Vector3.UP, yaw)
		var fwd := basis * Vector3(0, 0, -1)
		var right := basis * Vector3(1, 0, 0)
		var guns := _guns(d.get("loadout", {}), men)
		var look: String = "swat" if d.faction == "police" and d.kind == "truck" else ("family" if d.get("tag", "") == "family" else d.faction)
		var anim := "holding-both"
		if fighting.has(id):
			anim = "holding-both-shoot"
		elif moving:
			anim = "sprint" if d.state == "routed" else "walk"
		for k in men:
			var row := k / 4
			var col := k % 4
			var off: Vector3 = right * ((col - 1.5) * 1.6) - fwd * (row * 2.0) + (right * 3.2 if d.kind != "foot" else Vector3.ZERO)
			var wp: Vector3 = g3 + off
			wp.y = world.ground(wp.x, -wp.z) + 0.3
			men_pts.append([id, wp])
			var tier: String = guns[k]
			var a := anim
			if tier == "pistol" and anim.begins_with("holding-both"):
				a = anim.replace("both", "right")
			entries.append(["%s#%d" % [id, k], d.faction, look, Transform3D(basis, wp), a, tier, wp.distance_to(cam), k + id.hash()])
			if fighting.has(id) and _rng.randf() < 0.35:
				flash_xf.append(Transform3D(Basis.IDENTITY, wp + Vector3(0, 1.25, 0) + fwd * 0.9 + right * 0.12))
	# the nearest men as characters, the rest as figures
	entries.sort_custom(func(a, b): return a[6] < b[6])
	var used := {}
	for e in entries:
		if used.size() < near_n and e[6] < NEAR_M:
			_actor(e[0], e[2], e[7], e[3], e[4], e[5])
			used[e[0]] = true
		else:
			var xf: Transform3D = e[3]
			men_by[e[1]].append(xf)
			head_xf.append(Transform3D(Basis.IDENTITY, xf.origin + Vector3(0, 1.64, 0)))
	# a squad wiped out in a fight leaves its last men on the ground
	for id in last_men.keys():
		if not seen.has(id) and _was_fighting.has(id) and smooth.has(id):
			var p: Vector2 = smooth[id][0]
			for k in last_men[id]:
				var off := Vector2(_rng.randf_range(-6, 6), _rng.randf_range(-6, 6))
				fallen.append([now, Vector3(p.x + off.x, world.ground(p.x + off.x, p.y + off.y), -(p.y + off.y)), _was_fighting[id], _rng.randf() * TAU])
			last_men.erase(id)
			smooth.erase(id)
	_was_fighting = {}
	for d in squads:
		if fighting.has(d.id):
			_was_fighting[d.id] = d.faction
	for id in vehicles.keys():
		if not seen.has(id):
			vehicles[id].queue_free()
			vehicles.erase(id)
			smooth.erase(id)
			last_men.erase(id)
	fallen = fallen.filter(func(fl): return now - fl[0] < FALLEN_S)
	if fallen.size() > 80:
		fallen = fallen.slice(-80)
	for f in SUIT:
		_fill(bodies[f], men_by[f])
	_fill(heads, head_xf)
	_fill(flashes, flash_xf)
	var dead_xf := []
	var dead_col := []
	var near_dead := 0
	for i in fallen.size():
		var fl: Array = fallen[i]
		if near_n > 0 and near_dead < FALLEN_NEAR and fl[1].distance_to(cam) < NEAR_M:
			var key := "fallen#%d#%d" % [int(fl[0] * 1000.0), i]
			_actor(key, fl[2], i, Transform3D(Basis(Vector3.UP, fl[3]), fl[1]), "die", "")
			used[key] = true
			near_dead += 1
			continue
		dead_xf.append(Transform3D(Basis(Vector3.UP, fl[3]) * Basis(Vector3.RIGHT, -PI / 2), fl[1] + Vector3(0, 0.15, 0)))
		dead_col.append(SUIT.get(fl[2], SUIT.org))
	_fill(dead, dead_xf)
	for i in dead_col.size():
		dead.multimesh.set_instance_color(i, dead_col[i])
	for key in actors.keys():
		if not used.has(key):
			actors[key].queue_free()
			actors.erase(key)


## Each man's gun, best first, from the squad's loadout (a man without one carries a pistol).
static func _guns(loadout: Dictionary, men: int) -> Array:
	var out := []
	for t in ["rpg", "mg", "rifle", "pistol"]:
		for i in int(loadout.get(t, 0)):
			out.append(t)
	while out.size() < men:
		out.append("pistol")
	return out


## Place (making it the first time) the character `key`, playing `anim`.
func _actor(key: String, look: String, variant: int, xf: Transform3D, anim: String, tier: String) -> void:
	var a: Node3D = actors.get(key)
	if a == null:
		a = ModelLib.character(look, variant)
		if a == null:
			return
		add_child(a)
		actors[key] = a
	a.transform = xf  # feet where the figure's feet would be
	if tier != "":
		ModelLib.arm(a, tier)
	var ap: AnimationPlayer = a.get_meta("anim")
	if ap != null and ap.current_animation != anim and ap.assigned_animation != anim:
		ap.play(anim, 0.15)
		if anim == "die":
			ap.seek(ap.current_animation_length, true)  # already down
			ap.pause()


## How many men are characters up close (tests).
func near_drawn() -> int:
	return actors.keys().filter(func(k): return not k.begins_with("fallen")).size()


func _hide_vehicle(id: String) -> void:
	if vehicles.has(id):
		vehicles[id].visible = false


func _fill(n: MultiMeshInstance3D, xf: Array) -> void:
	var mm := n.multimesh
	if mm.instance_count != xf.size():
		mm.instance_count = xf.size()
	for i in xf.size():
		mm.set_instance_transform(i, xf[i])


## How many men are drawn (tests, the HUD), near and far.
func drawn() -> int:
	var n := near_drawn()
	for f in bodies:
		n += bodies[f].multimesh.instance_count
	return n
