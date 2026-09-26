extends TestCase
## The Kenney CC0 models (ModelLib): every one the game names loads, comes out
## the right size and facing the right way, the squads draw the nearest men as
## animated characters with their guns, and without the files everything
## falls back to the procedural boxes.


func after_each() -> void:
	World.use_map(0)
	ModelLib.ENABLED = true


func test_every_named_model_loads() -> void:
	for f in ModelLib.CHARACTERS:
		for v in ModelLib.CHARACTERS[f].size():
			var m := ModelLib.character(f, v)
			check(m != null, "%s look %d" % [f, v])
			if m != null:
				m.free()
	for f in ModelLib.CARS:
		for k in ["car", "truck"]:
			var c := ModelLib.car(f, k)
			check(c != null, "%s %s" % [f, k])
			if c != null:
				c.free()
	for t in ModelLib.WEAPONS:
		var w := ModelLib.weapon(t)
		check(w != null, t)
		if w != null:
			w.free()
	for b in ModelLib.BOATS:
		var n := ModelLib.boat(b)
		check(n != null, b)
		if n != null:
			n.free()
	for p in ModelLib.PALMS.size():
		check(not ModelLib.palm_mesh(p, 10.0).is_empty(), "palm %d" % p)


func test_sizes_and_facing() -> void:
	var m := ModelLib.character("police", 0)
	var b := ModelLib.bounds(m)
	check_near(b.size.y, ModelLib.MAN_H, 0.05, "a man is 1.8 m")
	check_near(b.position.y, 0.0, 0.05, "feet at the origin")
	# facing -Z, his right arm is on +X
	var arm: Node3D = m.find_child("arm-right", true, false)
	check(_global(arm).x > 0.0, "his right hand is on his right: he faces -Z")
	var w := ModelLib.arm(m, "rifle")
	check(w != null and w.position.z < 0.0, "the rifle held out in front")
	check_eq(ModelLib.arm(m, "rifle"), w, "arming twice keeps the one gun")
	var p := ModelLib.arm(m, "pistol")
	check(p != w and m.get_node_or_null("weapon") == p, "a pistol replaces it")
	m.free()
	var c := ModelLib.car("police", "car")
	var cb := ModelLib.bounds(c)
	check_near(maxf(cb.size.x, cb.size.z), ModelLib.CAR_LEN.car, 0.05, "a car 4.6 m long")
	check(cb.size.z > cb.size.x, "lengthwise along Z")
	check_near(cb.get_center().x, 0.0, 0.05, "centred")
	c.free()
	var g := ModelLib.weapon("rifle")
	var gb := ModelLib.bounds(g)
	check(gb.size.z > gb.size.x * 3.0, "the barrel along Z")
	g.free()
	var boat := ModelLib.boat("gofast")
	check_near(maxf(ModelLib.bounds(boat).size.x, ModelLib.bounds(boat).size.z), 12.0, 0.1, "a 12 m go-fast")
	boat.free()


func _global(n: Node3D) -> Vector3:
	var xf := n.transform
	var p := n.get_parent()
	while p is Node3D:
		xf = (p as Node3D).transform * xf
		p = p.get_parent()
	return xf.origin


func _sess() -> Session:
	var s := Session.new({"seed": 3, "map_seed": MapCity.SEED, "location": "HAR", "features": Session.SANDBOX_FEATURES,
		"ground_war": true})
	s.police.frozen = true
	s.ground._started = true
	for f in s.ground.commanders:
		s.ground.commanders[f].ai = false
	s.update(1.0 / 30)
	return s


func test_squads_near_are_characters_far_are_figures() -> void:
	var s := _sess()
	var g := s.ground
	var near = g.recruit("rival", "foot", Vector2(-1640, -10660), false)
	g.arsenal("rival").give_back(near.loadout)
	near.loadout = {"rifle": 2, "pistol": 2}
	near.men = 4
	near.state = "holding"
	var far = g.recruit("police", "car", Vector2(-1640, -9300), false)
	far.state = "holding"
	var r := SquadRender.new()
	r.setup(s.world, "medium")
	Engine.get_main_loop().root.add_child(r)
	var cam := Vector3(-1640, 10, 10700)
	r.sync(g.squads.map(func(q): return q.dict()), [], cam, s.time, 0.1)
	check_eq(r.near_drawn(), 4, "the rival crew up close as characters")
	check(r.bodies.police.multimesh.instance_count > 0, "the far patrol as figures")
	check_eq(r.bodies.rival.multimesh.instance_count, 0, "not both")
	check_eq(r.men_pts.filter(func(m): return m[0] == near.id).size(), 4, "still aimable")
	var a: Node3D = r.actors["%s#0" % near.id]
	check_eq(a.get_node("weapon").get_meta("tier"), "rifle", "best gun first")
	var ap: AnimationPlayer = a.get_meta("anim")
	check_eq(ap.assigned_animation, "holding-both", "standing, aiming")
	check_eq(r.actors["%s#3" % near.id].get_meta("anim").assigned_animation, "holding-right", "one-handed with a pistol")
	# a fight: they fire
	r.sync(g.squads.map(func(q): return q.dict()), [{"x": -1600.0, "y": -10600.0, "a": near.id, "b": far.id}], cam, s.time, 0.1)
	check_eq(ap.assigned_animation, "holding-both-shoot", "firing")
	# one goes down: he falls where he stood
	near.men = 3
	r.sync(g.squads.map(func(q): return q.dict()), [], cam, s.time + 1.0, 0.1)
	check_eq(r.near_drawn(), 3, "three standing")
	check(r.actors.keys().any(func(k): return k.begins_with("fallen")), "and one on the ground")
	# a car: the kit's police cruiser
	var v: Node3D = r.vehicles.get(far.id)
	check(v != null and v.name == "police", "the Car Kit's black-and-white")
	r.free()
	s.dispose()


func test_without_the_files_the_boxes_stand_in() -> void:
	ModelLib.ENABLED = false
	check(ModelLib.character("org") == null and ModelLib.car("org", "car") == null, "nothing loads")
	var s := _sess()
	var q = s.ground.recruit("org", "car", Vector2(-1640, -10660), false)
	q.state = "holding"
	var r := SquadRender.new()
	r.setup(s.world, "medium")
	Engine.get_main_loop().root.add_child(r)
	r.sync(s.ground.squads.map(func(x): return x.dict()), [], Vector3(-1640, 10, 10700), s.time, 0.1)
	check_eq(r.near_drawn(), 0, "no characters")
	check(r.bodies.org.multimesh.instance_count > 0, "figures")
	check(r.vehicles.has(q.id), "a box car")
	check(Models.build_boat("cutter")[0] != null, "a box cutter")
	r.free()
	s.dispose()
