class_name Gunplay
extends Node3D
## The walker's gun (the 3D side of FootCombat): 1-4 draw a pistol, a rifle, a
## machine gun or an RPG from the organisation's armoury, H holsters, R
## reloads, the left mouse button fires (hold it for the rifle and the machine
## gun). The ray from the eye is tested against the men SquadRender drew
## (a capsule each) and against the world's colliders, so walls stop bullets;
## the session decides whether the hit counts. Recoil kicks the view, a tracer
## and a muzzle flash show the shot, and a crosshair with the ammo sits on the HUD.

const RATE := {"pistol": 0.28, "rifle": 0.1, "mg": 0.07, "rpg": 1.5}  ## s between shots
const AUTO := ["rifle", "mg"]
const SPREAD := {"pistol": 0.012, "rifle": 0.008, "mg": 0.02, "rpg": 0.004}  ## rad
const KICK := {"pistol": 0.02, "rifle": 0.012, "mg": 0.01, "rpg": 0.06}
const CAPSULE_R := 0.32

var sess: Session
var walker: Walker
var squads: SquadRender
var hud: Label
var cross: Label
var viewmodel: Node3D
var tracer: MeshInstance3D
var _cool := 0.0
var _tracer_t := 0.0
var _rng := RandomNumberGenerator.new()
var last_result := ""  ## what the last shot did (tests, the HUD)


func setup(sess_: Session, walker_: Walker, squads_: SquadRender, ui: Node) -> Gunplay:
	sess = sess_
	walker = walker_
	squads = squads_
	_rng.randomize()
	hud = UIStyle.label("", 18, UIStyle.WHITE, UIStyle.mono())
	hud.anchor_left = 1.0
	hud.anchor_right = 1.0
	hud.anchor_top = 1.0
	hud.anchor_bottom = 1.0
	hud.offset_left = -360
	hud.offset_top = -90
	hud.offset_right = -24
	hud.offset_bottom = -24
	hud.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	ui.add_child(hud)
	cross = UIStyle.label("+", 26, Color(1, 1, 1, 0.85))
	cross.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	cross.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cross.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	ui.add_child(cross)
	viewmodel = Node3D.new()
	walker.cam.add_child(viewmodel)
	tracer = MeshInstance3D.new()
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(1.0, 0.9, 0.5)
	m.emission_enabled = true
	m.emission = Color(1.0, 0.8, 0.4)
	m.emission_energy_multiplier = 4.0
	tracer.material_override = m
	tracer.visible = false
	add_child(tracer)
	sess.foot.enter(walker.game_xy()[0], walker.game_xy()[1])
	_refresh_viewmodel()
	return self


func teardown() -> void:
	sess.foot.leave()
	if is_instance_valid(hud):
		hud.queue_free()
	if is_instance_valid(cross):
		cross.queue_free()
	if is_instance_valid(viewmodel):
		viewmodel.queue_free()


func key(k: String) -> bool:
	var f := sess.foot
	if FootCombat.KEYS.has(k):
		var err := f.draw(FootCombat.KEYS[k])
		if err != "":
			sess.say(err)
		_refresh_viewmodel()
		return true
	match k:
		"h":
			f.holster()
			_refresh_viewmodel()
		"r":
			if f.reload():
				_cool = 1.6 if f.tier != "rpg" else 2.5
		_:
			return false
	return true


func _refresh_viewmodel() -> void:
	for c in viewmodel.get_children():
		c.queue_free()
	var t := sess.foot.tier
	if t == "":
		return
	var k := Buildings.Kit.new("gun")
	var L: float = {"pistol": 0.22, "rifle": 0.8, "mg": 1.0, "rpg": 1.1}[t]
	k.box(Vector3(0, 0, -L / 2), Vector3(0.05 if t == "pistol" else 0.07, 0.07, L), "black", false)
	if t != "pistol":
		k.box(Vector3(0, -0.08, -0.15), Vector3(0.05, 0.14, 0.08), "black", false)  # the grip / magazine
		k.box(Vector3(0, -0.01, 0.12), Vector3(0.06, 0.1, 0.24), "wood" if t == "rifle" else "black", false)  # the stock
	if t == "rpg":
		k.box(Vector3(0, 0, -L - 0.12), Vector3(0.12, 0.12, 0.25), "green", false)
	var n := k.finish()
	var col = n.get_node_or_null("collision")
	if col != null:
		col.free()
	n.position = Vector3(0.18, -0.2, -0.35)
	viewmodel.add_child(n)


func _process(dt: float) -> void:
	var f := sess.foot
	var xy: Array = walker.game_xy()
	f.move(xy[0], xy[1], walker.velocity.length() > 0.5)
	_cool = maxf(0.0, _cool - dt)
	_tracer_t -= dt
	tracer.visible = _tracer_t > 0.0
	viewmodel.position = viewmodel.position.lerp(Vector3.ZERO, clampf(dt * 10.0, 0.0, 1.0))
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if f.tier in AUTO or not _held:
			trigger()
		_held = true
	else:
		_held = false
	var who: String = "" if f.tier == "" else Arsenal.TIERS[f.tier].name.to_upper().trim_suffix("S")
	hud.text = ("%s  %d / %d\n" % [who, f.mag, f.reserve] if f.tier != "" else "1-4 draw a gun\n") + "HEALTH %d" % int(f.hp)
	hud.add_theme_color_override("font_color", UIStyle.RED if f.hp < 35 else UIStyle.WHITE)
	cross.visible = f.tier != ""


var _held := false


## Pull the trigger once: a round, a ray, and whatever it meets.
func trigger() -> String:
	var f := sess.foot
	if _cool > 0.0 or f.tier == "":
		return ""
	if not f.fire():
		last_result = "click"
		if f.reserve > 0:
			key("r")
		return last_result
	_cool = RATE[f.tier]
	var cam := walker.cam
	var origin := cam.global_position
	var sp: float = SPREAD[f.tier] * (1.8 if f.moving else 1.0)
	var dir := (-cam.global_transform.basis.z).rotated(cam.global_transform.basis.x, _rng.randf_range(-sp, sp)).rotated(Vector3.UP, _rng.randf_range(-sp, sp)).normalized()
	var range: float = Arsenal.TIERS[f.tier].range
	var hit := aim(origin, dir, range)
	var end: Vector3 = origin + dir * (hit[1] if hit[0] != "" else range)
	# the world's colliders (walls, terrain) stop the round first
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	if space != null:
		var q := PhysicsRayQueryParameters3D.create(origin, end)
		q.exclude = [walker.get_rid()]
		var r := space.intersect_ray(q)
		if not r.is_empty():
			end = r.position
			if hit[0] != "" and origin.distance_to(r.position) < hit[1] - 0.3:
				hit = ["", 0.0]
	last_result = f.hit(hit[0], hit[1]) if hit[0] != "" else "miss"
	_tracer(origin + dir * 0.6, end)
	# recoil: the view climbs, the gun kicks back
	cam.rotation.x = clampf(cam.rotation.x + KICK[f.tier], -1.4, 1.4)
	viewmodel.position = Vector3(0, 0.01, 0.06)
	return last_result


## The first man the ray meets: [squad id, distance] or ["", 0].
func aim(origin: Vector3, dir: Vector3, range: float) -> Array:
	var best := ["", range]
	if squads == null:
		return ["", 0.0]
	for m in squads.men_pts:
		var feet: Vector3 = m[1]
		var t := _ray_capsule(origin, dir, feet + Vector3(0, 0.3, 0), feet + Vector3(0, 1.75, 0), CAPSULE_R)
		if t >= 0.0 and t < best[1]:
			best = [m[0], t]
	return best if best[0] != "" else ["", 0.0]


## Distance along the ray to a capsule (segment a-b, radius r), or -1.
static func _ray_capsule(o: Vector3, d: Vector3, a: Vector3, b: Vector3, r: float) -> float:
	# closest points between the ray and the segment
	var u := b - a
	var w := o - a
	var aa := d.dot(d)
	var bb := d.dot(u)
	var cc := u.dot(u)
	var dd := d.dot(w)
	var ee := u.dot(w)
	var den := aa * cc - bb * bb
	var s := 0.0
	var t := 0.0
	if den > 1e-9:
		s = (bb * ee - cc * dd) / den
		t = (aa * ee - bb * dd) / den
	t = clampf(t, 0.0, 1.0)
	s = maxf(0.0, (u * t - w).dot(d) / aa)
	var p := o + d * s
	var q := a + u * t
	return s if p.distance_to(q) <= r else -1.0


func _tracer(a: Vector3, b: Vector3) -> void:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_add_vertex(a)
	im.surface_add_vertex(b)
	im.surface_end()
	tracer.mesh = im
	_tracer_t = 0.05
