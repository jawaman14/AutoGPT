class_name Walker
extends CharacterBody3D
## On foot, first person. Walk the apron, the hangars and the headquarters;
## E uses whatever you're facing (Buildings' interaction points), TAB climbs
## back into the parked aircraft (PilotApp handles both).
##
## Collides with the island (one HeightMapShape3D, see `ground_body`), every
## building's colliders and the parked aircraft. Deep water is off limits.

signal used(action: String, area: Area3D)

const WALK := 1.6
const RUN := 5.5
const JUMP := 4.2
const GRAVITY := 9.81
const EYE := 1.65
const STEP := 0.55  ## kerbs, terraces, foundation edges: walk up anything this high
const MOUSE := 0.0025

var cam: Camera3D
var torch: SpotLight3D
var reach: Area3D
var world: World
var focus: Area3D = null  ## the interaction point in front of you
var _last_dry := Vector3.ZERO
var look_enabled := true


func setup(w: World) -> Walker:
	world = w
	name = "Walker"
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.32
	cap.height = 1.75
	cs.shape = cap
	cs.position = Vector3(0, 0.875, 0)
	add_child(cs)
	cam = Camera3D.new()
	cam.position = Vector3(0, EYE, 0)
	cam.near = 0.05
	cam.far = 30000.0
	cam.fov = 75
	add_child(cam)
	torch = SpotLight3D.new()
	torch.spot_range = 40
	torch.spot_angle = 28
	torch.light_energy = 3.0
	torch.visible = false
	cam.add_child(torch)
	reach = Area3D.new()
	reach.collision_layer = 0
	reach.collision_mask = 4
	var rs := CollisionShape3D.new()
	var sp := SphereShape3D.new()
	sp.radius = 1.8
	rs.shape = sp
	reach.add_child(rs)
	reach.position = Vector3(0, 1.0, -1.0)
	add_child(reach)
	floor_snap_length = 0.6
	floor_max_angle = deg_to_rad(50)
	return self


## The island's collision: one height field over the whole map.
static func ground_body(w: World) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "ground"
	var G := World.GRID
	var h := w.terrain.get_heights()
	var data := PackedFloat32Array()
	data.resize(G * G)
	# HeightMapShape3D rows run along +z (south in game terms): flip the north-up grid
	for r in G:
		var j := G - 1 - r
		for i in G:
			data[r * G + i] = h[j * G + i]
	var shape := HeightMapShape3D.new()
	shape.map_width = G
	shape.map_depth = G
	shape.map_data = data
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.scale = Vector3(World.CELL, 1.0, World.CELL)
	body.add_child(cs)
	return body


## Put the walker at a game-frame point (x east, y north), standing on the ground.
func place(x: float, y: float, heading_deg: float) -> void:
	global_position = Vector3(x, world.ground(x, y) + 0.2, -y)
	rotation = Vector3(0, -deg_to_rad(heading_deg), 0)
	cam.rotation = Vector3.ZERO
	velocity = Vector3.ZERO
	_last_dry = global_position


func game_xy() -> Array:
	return [global_position.x, -global_position.z]


func _unhandled_input(ev: InputEvent) -> void:
	if not look_enabled:
		return
	if ev is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-ev.relative.x * MOUSE)
		cam.rotation.x = clampf(cam.rotation.x - ev.relative.y * MOUSE, -1.45, 1.45)


func _physics_process(dt: float) -> void:
	var dir := Vector3.ZERO
	if look_enabled:
		var fwd := float(Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP)) \
			- float(Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN))
		var side := float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A))
		# arrow keys turn when the mouse isn't captured (keyboard-only play)
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			rotate_y((float(Input.is_physical_key_pressed(KEY_LEFT)) - float(Input.is_physical_key_pressed(KEY_RIGHT))) * 1.8 * dt)
		dir = (global_transform.basis * Vector3(side, 0, -fwd))
		dir.y = 0
		dir = dir.normalized() if dir.length() > 0.01 else Vector3.ZERO
	var speed := RUN if Input.is_physical_key_pressed(KEY_SHIFT) else WALK
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed
	if is_on_floor():
		if look_enabled and Input.is_physical_key_pressed(KEY_SPACE):
			velocity.y = JUMP
	else:
		velocity.y -= GRAVITY * dt
	move_and_slide()
	_step_up(dir)
	# no swimming: deep water sends you back to the last dry footing
	var gz := world.height(global_position.x, -global_position.z)
	if gz < -1.2 and global_position.y < 0.2:
		global_position = _last_dry
		velocity = Vector3.ZERO
	elif is_on_floor():
		_last_dry = global_position
	# fell through the world somehow: stand back up on the ground
	if global_position.y < world.ground(global_position.x, -global_position.z) - 5.0:
		global_position.y = world.ground(global_position.x, -global_position.z) + 0.5
		velocity = Vector3.ZERO
	_update_focus()


## CharacterBody3D doesn't climb steps: if a low obstacle stops us, try the
## same move from STEP higher and, if that's clear, take the step.
func _step_up(dir: Vector3) -> void:
	if dir == Vector3.ZERO or not is_on_wall() or not is_on_floor():
		return
	var up := Vector3(0, STEP, 0)
	var fwd := dir * 0.35
	if test_move(global_transform, up):
		return  # a ceiling
	if test_move(global_transform.translated(up), fwd):
		return  # a real wall, not a step
	global_position += up + fwd


func _update_focus() -> void:
	focus = null
	var best := 1e9
	var eye := cam.global_position
	var look := -cam.global_transform.basis.z
	for a in reach.get_overlapping_areas():
		if not a.has_meta("action"):
			continue
		var to := a.global_position - eye
		var d := to.length()
		var facing := look.dot(to.normalized())
		var score := d - facing * 2.0
		if facing > 0.2 and score < best:
			best = score
			focus = a


func use() -> void:
	if focus != null:
		used.emit(focus.get_meta("action"), focus)


func toggle_torch() -> void:
	torch.visible = not torch.visible
