extends SceneTree
## A firefight on the city's streets (the ground war in 3D):
##   godot --script res://tools/shots/ground_shot.gd -- <low|medium|high> <hour> <out.png> [scene]
## scene: docks (an org car crew against a patrol near Warehouse 7, default) |
##        checkpoint (a patrol stops a truck, Los Cuervos in a pickup) | street (downtown)
var app: PilotApp
var s: Session
var n := 0
var q := "medium"
var hour := 18.6
var out := "ground.png"
var where := "docks"
var fixed_cam: Array


func _init():
	var a := OS.get_cmdline_user_args()
	if a.size() > 0: q = a[0]
	if a.size() > 1: hour = float(a[1])
	if a.size() > 2: out = a[2]
	if a.size() > 3: where = a[3]
	s = Session.new({"seed": 2, "map_seed": MapCity.SEED, "location": "HAR", "features": Session.SANDBOX_FEATURES,
		"ground_war": true})
	s.police.frozen = true
	var g := s.ground
	g._started = true
	for f in g.commanders:
		g.commanders[f].ai = false
	s.update(1.0 / 30)
	var docks: Dictionary = s.stash_net.get_stash("docks")
	# on the street nearest Warehouse 7 (open ground, not inside a block)
	var c: Vector2 = g.graph.nodes[g.graph.nearest(Vector2(docks.x, docks.y + 200))]
	var pairs := []
	if where == "checkpoint":
		c = Vector2(2900, -7400)
		pairs = [["police", "car", c, {"rifle": 3, "pistol": 1}], ["rival", "car", c + Vector2(40, 50), {"rifle": 3, "mg": 1}],
			["org", "truck", c + Vector2(-20, -60), {"rifle": 4}]]
	elif where == "street":
		c = g.graph.nodes[g.graph.nearest(MapCity.CITY_C)]
		pairs = [["org", "foot", c, {"rifle": 4}], ["rival", "foot", c + Vector2(45, 25), {"rifle": 2, "pistol": 2}]]
	else:
		pairs = [["org", "car", c, {"rifle": 3, "mg": 1}], ["police", "car", c + Vector2(55, 30), {"rifle": 4}],
			["police", "car", c + Vector2(70, -18), {"pistol": 4}]]
	var made := []
	for p in pairs:
		var sq = g.recruit(p[0], p[1], p[2], false)
		g.arsenal(p[0]).give_back(sq.loadout)
		sq.loadout = p[3]
		sq.state = "holding"
		made.append(sq)
	g._open(made[0], made[1])
	# look at the middle of the fight from behind the first squad's shoulder, off to the side
	var mid: Vector2 = (made[0].pos() + made[1].pos()) / 2
	var along: Vector2 = (made[1].pos() - made[0].pos()).normalized()
	var eye: Vector2 = made[0].pos() - along * 28 + Vector2(-along.y, along.x) * 16
	fixed_cam = [Vector3(eye.x, s.world.ground(eye.x, eye.y) + 6.0, -eye.y), Vector3(mid.x, s.world.ground(mid.x, mid.y) + 1.0, -mid.y)]
	app = PilotApp.new()
	root.add_child(app)
	app.setup(s, q)
	app.scene.set_hour(hour)
	app.hud.visible = false


func _process(dt: float) -> bool:
	n += 1
	app.set_process(false)
	app.cam.global_position = fixed_cam[0]
	app.cam.look_at(fixed_cam[1], Vector3.UP)
	app.cam.fov = 60
	if n % 20 == 0 and n < 70:
		s.ground._rounds(GroundWar.ROUND_S)  # a few rounds: men fall
	app._sync_squads(0.5)
	app.scene.set_hour(hour)
	if n == 90:
		app.get_viewport().get_texture().get_image().save_png(out)
		print("saved ", out, " men drawn ", app.squads.drawn())
		if OS.get_environment("GROUND_SHOT_DEBUG") != "":
			print("cam ", fixed_cam, " squads ", s.ground.squads.map(func(q): return [q.id, q.x, q.y, q.men]))
			for f in app.squads.bodies:
				var mm: MultiMesh = app.squads.bodies[f].multimesh
				if mm.instance_count > 0:
					print(f, " first man at ", mm.get_instance_transform(0).origin)
		s.dispose()
		return true
	return false
