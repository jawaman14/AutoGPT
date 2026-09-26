extends SceneTree
## The cast and the vehicles (ModelLib's Kenney CC0 kits) lined up in the
## afternoon sun, for checking scale and facing and for the docs:
##   godot --script res://tools/shots/models_shot.gd -- <out.png> [anim]
## The men are turned to face the camera, the cars and boats side-on.
var out := "models.png"
var anim := "holding-both"
var n := 0


func _initialize():
	var a := OS.get_cmdline_user_args()
	if a.size() > 0: out = a[0]
	if a.size() > 1: anim = a[1]
	var w := Node3D.new()
	root.add_child(w)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.55, 0.42, 0.62)
	env.environment.ambient_light_color = Color(1, 0.9, 0.95)
	env.environment.ambient_light_energy = 0.35
	env.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	w.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 30, 0)
	sun.light_color = Color(1.0, 0.85, 0.7)
	sun.shadow_enabled = true
	w.add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(200, 160)
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.62, 0.55, 0.45)
	pm.material = gm
	ground.mesh = pm
	w.add_child(ground)
	var x := -9.0
	var tiers := ["pistol", "rifle", "mg", "rpg"]
	var i := 0
	for f in ["org", "rival", "police", "swat", "family"]:
		for v in ModelLib.CHARACTERS[f].size():
			var m := ModelLib.character(f, v)
			m.position = Vector3(x, 0, 0)
			m.rotation.y = PI  # models face -Z: turn them to the camera (+Z)
			w.add_child(m)
			ModelLib.arm(m, tiers[i % tiers.size()])
			var ap: AnimationPlayer = m.get_meta("anim")
			ap.play("holding-right" if tiers[i % tiers.size()] == "pistol" else anim)
			x += 1.5
			i += 1
	var col := 0
	for f in ["org", "rival", "police", "family"]:
		for k in ["car", "truck"]:
			var c := ModelLib.car(f, k)
			c.position = Vector3(-10.5 + (col % 4) * 6.0 + (3.0 if k == "truck" else 0.0), 0, -7.0 - 6.0 * int(k == "truck"))
			c.rotation.y = PI / 2  # nose to the right
			w.add_child(c)
			col += 1 if k == "truck" else 0
	var gf := ModelLib.boat("gofast")
	gf.position = Vector3(-4, 0, -26)
	gf.rotation.y = PI / 2
	w.add_child(gf)
	var cu := ModelLib.boat("cutter")
	cu.position = Vector3(26, 0, -60)
	cu.rotation.y = PI / 2
	w.add_child(cu)
	for p in 4:
		var pmesh := ModelLib.palm_mesh(p, 9.0)
		var pi := MeshInstance3D.new()
		pi.mesh = pmesh[0]
		pi.scale = Vector3.ONE * pmesh[1]
		pi.position = Vector3(-22 + p * 3.0, 0, -18)
		w.add_child(pi)
	for t in tiers.size():
		var g := ModelLib.weapon(tiers[t], 2.0)
		g.position = Vector3(8.0, 0.2, 3.0 - t * 0.9)
		g.rotation.y = -PI / 2  # barrel to the right
		w.add_child(g)
	var cam := Camera3D.new()
	w.add_child(cam)
	cam.look_at_from_position(Vector3(0, 7.0, 15), Vector3(0, 1.0, -8), Vector3.UP)
	cam.fov = 60
	cam.current = true


func _process(_dt: float) -> bool:
	n += 1
	if n == 20:
		root.get_viewport().get_texture().get_image().save_png(out)
		return true
	return false
