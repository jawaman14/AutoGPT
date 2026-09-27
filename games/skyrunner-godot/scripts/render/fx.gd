class_name FX
extends Node3D
## Fire, smoke, explosions and splashes: billboarded Kenney Particle Pack
## sprites (CC0, assets/fx/kenney_particles) on CPUParticles3D, which every
## renderer draws the same (the compatibility renderer included) and which cost
## nothing on the GPU for the few dozen particles each effect uses.
##
## The node is the pilot seat's effects layer:
##   burn(key, pos)   a lasting fire and its smoke column, kept alive while the
##                    caller keeps naming it (sweep() puts out the rest)
##   smoke(key, pos)  a lasting smoke column alone (a burned-out stash house)
##   blast(pos)       a one-shot explosion: flash, fireball, sparks, smoke puff
##   splash(pos)      a one-shot splash: spray and a ring on the water
##   puff(pos)        a one-shot dust puff
## A blast also throws debris: a few rigid bodies (Jolt) that tumble, bounce on
## the ground and the buildings, and go after DEBRIS_S; at most MAX_DEBRIS.
## Smoke leans downwind with `wind` (m/s, Godot axes).

const TEX := "res://assets/fx/kenney_particles/%s.png"
const FIRE := Color(1.0, 0.55, 0.15)
const MAX_DEBRIS := 36
const DEBRIS_S := 8.0
var debris: Array = []
var wind := Vector3.ZERO
var lasting := {}  ## key -> Node3D
var _seen := {}
static var _mats := {}


## A billboard material for one of the sprites; `add` blends additively (fire, sparks).
static func mat(sprite: String, add: bool) -> StandardMaterial3D:
	var k := "%s:%s" % [sprite, add]
	if not _mats.has(k):
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if add else BaseMaterial3D.BLEND_MODE_MIX
		m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		m.vertex_color_use_as_albedo = true
		m.albedo_texture = load(TEX % sprite) if ResourceLoader.exists(TEX % sprite) else null
		m.no_depth_test = false
		m.disable_receive_shadows = true
		_mats[k] = m
	return _mats[k]


static func _emitter(sprite: String, add: bool, amount: int, life: float, size: float) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(size, size)
	q.material = mat(sprite, add)
	p.mesh = q
	p.amount = amount
	p.lifetime = life
	p.local_coords = false
	p.angle_min = 0.0
	p.angle_max = 360.0
	return p


static func _ramp(cols: Array) -> Gradient:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array(range(cols.size()).map(func(i): return float(i) / (cols.size() - 1)))
	g.colors = PackedColorArray(cols)
	return g


static func _grow(a: float, b: float) -> Curve:
	var c := Curve.new()
	c.add_point(Vector2(0, a))
	c.add_point(Vector2(1, b))
	return c


## Flames licking up from a burning wreck, `size` metres across.
static func flames(size := 3.0) -> CPUParticles3D:
	var p := _emitter("fire_01", true, 28, 0.9, size)
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = size * 0.35
	p.direction = Vector3.UP
	p.spread = 12.0
	p.gravity = Vector3(0, size * 1.2, 0)
	p.initial_velocity_min = size * 0.4
	p.initial_velocity_max = size * 0.9
	p.scale_amount_curve = _grow(1.0, 0.25)
	p.color_ramp = _ramp([Color(1, 0.85, 0.4, 0.0), Color(1.0, 0.6, 0.15, 0.95), Color(0.9, 0.25, 0.05, 0.6), Color(0.3, 0.1, 0.05, 0.0)])
	p.name = "flames"
	return p


## A column of smoke, black from burning fuel or grey from a smouldering house.
static func column(size := 4.0, dark := true, wind := Vector3.ZERO) -> CPUParticles3D:
	var p := _emitter("smoke_04", false, 36, 7.0, size)
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = size * 0.3
	p.direction = Vector3.UP
	p.spread = 8.0
	p.initial_velocity_min = 2.0
	p.initial_velocity_max = 3.5
	p.gravity = Vector3(0, 0.6, 0) + wind * 0.35
	p.damping_min = 0.3
	p.damping_max = 0.6
	p.scale_amount_curve = _grow(0.6, 3.2)
	var c := Color(0.08, 0.08, 0.08) if dark else Color(0.55, 0.55, 0.56)
	p.color_ramp = _ramp([Color(c, 0.0), Color(c, 0.75), Color(c.lightened(0.25), 0.4), Color(c.lightened(0.4), 0.0)])
	p.name = "smoke"
	return p


## One-shot pieces: they emit once and free themselves.
static func _once(p: CPUParticles3D) -> CPUParticles3D:
	p.one_shot = true
	p.explosiveness = 0.9
	p.emitting = true
	p.finished.connect(p.queue_free)
	return p


func burn(key: String, pos: Vector3, size := 3.0) -> Node3D:
	_seen[key] = true
	if not lasting.has(key):
		var n := Node3D.new()
		n.name = key.validate_node_name()
		n.add_child(flames(size))
		n.add_child(column(size * 1.4, true, wind))
		var l := OmniLight3D.new()
		l.name = "glow"
		l.light_color = FIRE
		l.omni_range = size * 6.0
		l.light_energy = 1.5
		l.shadow_enabled = false
		l.position.y = size * 0.5
		n.add_child(l)
		add_child(n)
		lasting[key] = n
	lasting[key].position = pos
	return lasting[key]


func smoke(key: String, pos: Vector3, size := 5.0) -> Node3D:
	_seen[key] = true
	if not lasting.has(key):
		var n := Node3D.new()
		n.name = key.validate_node_name()
		n.add_child(column(size, false, wind))
		add_child(n)
		lasting[key] = n
	lasting[key].position = pos
	return lasting[key]


## Put out every lasting effect not named since the last sweep.
func sweep() -> void:
	for k in lasting.keys():
		if not _seen.has(k):
			lasting[k].queue_free()
			lasting.erase(k)
	_seen.clear()


func blast(pos: Vector3, size := 4.0) -> Node3D:
	var n := Node3D.new()
	n.name = "blast"
	add_child(n)
	n.position = pos
	var fb := _once(_emitter("fire_02", true, 16, 0.5, size))
	fb.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	fb.emission_sphere_radius = size * 0.3
	fb.spread = 180.0
	fb.initial_velocity_min = size * 1.5
	fb.initial_velocity_max = size * 3.0
	fb.gravity = Vector3.ZERO
	fb.damping_min = size * 3.0
	fb.damping_max = size * 4.0
	fb.scale_amount_curve = _grow(0.6, 1.6)
	fb.color_ramp = _ramp([Color(1, 0.95, 0.7, 1), Color(1, 0.5, 0.1, 0.9), Color(0.3, 0.1, 0.05, 0.0)])
	n.add_child(fb)
	var sp := _once(_emitter("spark_01", true, 24, 0.8, size * 0.25))
	sp.spread = 180.0
	sp.initial_velocity_min = 12.0
	sp.initial_velocity_max = 28.0
	sp.gravity = Vector3(0, -9.8, 0)
	sp.color = Color(1, 0.8, 0.4)
	n.add_child(sp)
	var sm := _once(column(size * 1.3, true, wind))
	sm.amount = 14
	sm.lifetime = 4.0
	sm.explosiveness = 0.6
	n.add_child(sm)
	var l := OmniLight3D.new()
	l.light_color = FIRE
	l.omni_range = size * 8.0
	l.light_energy = 6.0
	n.add_child(l)
	throw_debris(pos, 6, size)
	var tw := n.create_tween()
	tw.tween_property(l, "light_energy", 0.0, 0.35)
	tw.tween_interval(4.0)
	tw.tween_callback(n.queue_free)
	return n


## Chunks flung out of a blast: small boxes on the physics engine, scorched dark.
func throw_debris(pos: Vector3, n: int, size := 4.0) -> int:
	debris = debris.filter(func(b): return is_instance_valid(b))
	# only where there's ground to land on (the island's collider exists once you've walked)
	if not is_inside_tree():
		return 0
	var q := PhysicsRayQueryParameters3D.create(pos + Vector3(0, 2, 0), pos - Vector3(0, 60, 0))
	if get_world_3d().direct_space_state.intersect_ray(q).is_empty():
		return 0
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(pos)
	for i in n:
		if debris.size() >= MAX_DEBRIS:
			var old = debris.pop_front()
			old.queue_free()
		var b := RigidBody3D.new()
		b.name = "debris"
		var s := Vector3(rng.randf_range(0.15, 0.5), rng.randf_range(0.08, 0.25), rng.randf_range(0.15, 0.6))
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = s
		cs.shape = bs
		b.add_child(cs)
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = s
		bm.material = _debris_mat()
		mi.mesh = bm
		b.add_child(mi)
		b.mass = s.x * s.y * s.z * 800.0
		add_child(b)
		b.global_position = pos + Vector3(rng.randf_range(-0.5, 0.5), 0.6, rng.randf_range(-0.5, 0.5))
		var out := Vector3(rng.randf_range(-1, 1), rng.randf_range(0.8, 1.6), rng.randf_range(-1, 1)).normalized()
		b.linear_velocity = out * rng.randf_range(6.0, 14.0) * size / 4.0
		b.angular_velocity = Vector3(rng.randf_range(-9, 9), rng.randf_range(-9, 9), rng.randf_range(-9, 9))
		debris.append(b)
		get_tree().create_timer(DEBRIS_S).timeout.connect(func(): if is_instance_valid(b): b.queue_free())
	return n


static var _dmat: StandardMaterial3D
static func _debris_mat() -> StandardMaterial3D:
	if _dmat == null:
		_dmat = StandardMaterial3D.new()
		_dmat.albedo_color = Color(0.12, 0.1, 0.09)
		_dmat.roughness = 0.9
	return _dmat


func splash(pos: Vector3, size := 2.0) -> Node3D:
	var n := Node3D.new()
	n.name = "splash"
	add_child(n)
	n.position = pos
	var spray := _once(_emitter("circle_05", false, 22, 1.1, size * 0.6))
	spray.direction = Vector3.UP
	spray.spread = 25.0
	spray.initial_velocity_min = size * 2.5
	spray.initial_velocity_max = size * 4.5
	spray.gravity = Vector3(0, -9.8, 0)
	spray.scale_amount_curve = _grow(1.0, 0.4)
	spray.color_ramp = _ramp([Color(1, 1, 1, 0.9), Color(0.85, 0.93, 1, 0.0)])
	n.add_child(spray)
	var ring := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(size * 3.0, size * 3.0)
	q.orientation = PlaneMesh.FACE_Y
	var rm: StandardMaterial3D = mat("circle_05", false).duplicate()
	rm.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED
	rm.vertex_color_use_as_albedo = false
	rm.albedo_color = Color(1, 1, 1, 0.8)
	q.material = rm
	ring.mesh = q
	ring.position.y = 0.15
	n.add_child(ring)
	var tw := n.create_tween()
	tw.set_parallel(true)
	tw.tween_property(ring, "scale", Vector3.ONE * 2.5, 1.6)
	tw.tween_property(rm, "albedo_color:a", 0.0, 1.6)
	tw.chain().tween_callback(n.queue_free)
	return n


func puff(pos: Vector3, size := 2.0) -> CPUParticles3D:
	var p := _once(_emitter("dirt_02", false, 12, 1.6, size))
	p.spread = 70.0
	p.direction = Vector3.UP
	p.initial_velocity_min = 1.0
	p.initial_velocity_max = 3.0
	p.gravity = Vector3(0, -1.0, 0) + wind * 0.3
	p.scale_amount_curve = _grow(0.6, 1.8)
	p.color_ramp = _ramp([Color(0.6, 0.52, 0.4, 0.7), Color(0.6, 0.55, 0.45, 0.0)])
	p.name = "puff"
	add_child(p)
	p.position = pos
	return p
