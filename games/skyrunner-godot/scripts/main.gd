extends Node
## Entry point (port of skyrunner/__main__.py).
##
##   godot                                   # sandbox, solo
##   godot -- --mode campaign                # story mode (1979 ->)
##   godot -- --mode coop                    # host: friends join as co-pilot / spotter
##   godot -- --mode versus                  # host: a friend runs the task-force desk
##   godot -- --police                       # play the task force against AI runners
##   godot -- --players 6                    # seats and rule layers for a table of six
##   godot -- --watch --graphics low         # the AI flies the career; you watch
##   godot -- --map city                     # Costa Brava, the city coast (the default for new games)
##   godot -- --map 42                       # a generated island (0 = the classic one)
##   godot -- --shot out.png --frames 90     # render N frames, save a screenshot, quit
##
## With no arguments the lobby opens, which sets the same options with menus.

const SAVE_DIR := "user://"

var args := {"mode": "solo", "police": false, "host": false, "port": 47800, "bind": "*", "new": false, "seed": 1,
	"players": 0, "layer": 0, "graphics": "high", "watch": false, "shot": "", "frames": 90, "hour": -1.0,
	"map": -1, "weather": "", "connect": "", "role": "copilot", "name": "player", "seat3d": false, "lobby": true}


func _ready() -> void:
	var a := OS.get_cmdline_user_args()
	var i := 0
	while i < a.size():
		var k: String = a[i].trim_prefix("--")
		if args.has(k) and args[k] is bool:
			args[k] = true
		elif args.has(k) and i + 1 < a.size():
			var v: String = a[i + 1]
			if k == "map" and v == "city":
				v = str(MapCity.SEED)
			args[k] = int(v) if args[k] is int else (float(v) if args[k] is float else v)
			i += 1
		else:
			push_warning("unknown argument " + a[i])
		i += 1
	if not a.is_empty():
		args["lobby"] = false
	if args["lobby"]:
		var lobby := Lobby.new()
		add_child(lobby)
		lobby.start.connect(func(opts):
			lobby.queue_free()
			args.merge(opts, true)
			start())
		return
	start()


func start() -> void:
	if args["connect"] != "":
		_join()
		return
	var features = null
	if args["players"] or args["layer"]:
		var plan := Layers.plan_match(maxi(1, args["players"]), args["mode"] != "coop", args["layer"])
		print(plan.describe())
		if args["mode"] in ["solo", "coop", "versus"]:
			args["mode"] = plan.mode
		features = Layers.features_for(plan.layer)
		if plan.layer >= 5:
			features["hq"] = true
		features = features.keys()
	if args["police"]:  # offline task-force desk against AI runners
		var ps := Session.new({"mode": Roles.POLICE, "seed": args["seed"], "humans": {Roles.CONTROLLER: args["name"]},
			"map_seed": args["map"] if args["map"] >= 0 else MapCity.SEED})
		var desk := StationApp.new()
		add_child(desk)
		desk.setup(LocalLink.new(ps, Roles.CONTROLLER), Roles.CONTROLLER, ps.world)
		return
	var mode: String = args["mode"]
	var save := SAVE_DIR + ("campaign.json" if mode == Roles.CAMPAIGN else "save.json")
	if args["new"] and FileAccess.file_exists(save):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(save))
	var opts := {"seed": args["seed"], "mode": mode, "ai_law_upgrades": true, "ground_war": true, "chronicle": true, "agency": true}  # the AI chief shops as forfeiture comes in
	if args["map"] >= 0:  # --map 0 = classic island, --map N = generated island N
		opts["map_seed"] = args["map"]
	elif not FileAccess.file_exists(save):
		opts["map_seed"] = MapCity.SEED  # a new game starts on the city coast; old saves keep their island
	if features != null:
		opts["features"] = features
	var sess := Session.load_or_new(save, opts)
	if args["weather"] != "":  # --weather clear|cloud|storm[,moon 0..1]; the HQ season sets its own each night
		var wp: PackedStringArray = str(args["weather"]).split(",")
		sess.set_weather({"sky": wp[0], "moon": float(wp[1]) if wp.size() > 1 else 0.5})
	if mode == Roles.CAMPAIGN:
		Campaign.from_dict(Session.read_save(save).get("campaign")).attach(sess)
	var server = null
	if args["host"] or mode in [Roles.COOP, Roles.VERSUS]:
		server = HostServer.new()
		add_child(server)
		var err = server.start(args["port"], mode if mode != Roles.SOLO else Roles.COOP)
		if err:
			sess.say(err)
			server = null
		else:
			sess.say("Hosting on port %d: friends join with --connect YOUR_IP:%d (--role pick to choose a seat; the AI plays every seat nobody takes)" % [server.port, server.port])
	var bot = null
	if args["watch"]:
		bot = AutoRunner.new(sess)
		sess.say("Watching the AI fly. [C] cycles cameras.")
	var app := PilotApp.new()
	add_child(app)
	app.setup(sess, args["graphics"], bot, server)
	if args["hour"] >= 0:
		app.scene.set_hour(args["hour"])
	if args["shot"] != "":
		_shoot(app)


## Remote seat: a 3D view for the police pilot (and the co-pilot with --seat3d),
## the 2D station for everyone else.
func _join() -> void:
	var a: String = args["connect"]
	var i := a.rfind(":")
	var host := a.substr(0, i) if i > 0 else "127.0.0.1"
	var port := int(a.substr(i + 1)) if i >= 0 else HostServer.DEFAULT_PORT
	var link := NetClient.new()
	add_child(link)
	var role: String = args["role"] if args["role"] != "pick" else ""
	link.open(host, port, args["name"], role)
	if role == "":
		# the live seat list: take whatever the AI is playing
		var picker := SeatPicker.new()
		add_child(picker)
		picker.setup(link)
		picker.seated.connect(func(r):
			picker.queue_free()
			_seat(link, r), CONNECT_ONE_SHOT)
		return
	_seat(link, role)


func _seat(link: NetClient, role: String) -> void:
	if role in [Roles.INTERCEPTOR, Roles.PILOT] or (role == Roles.COPILOT and args["seat3d"]):
		var seat := RemoteSeat.new()
		add_child(seat)
		seat.setup(link, role, args["graphics"])
	else:
		var st := StationApp.new()
		add_child(st)
		st.setup(link, role)


## Render a few frames and save a screenshot (docs, CI smoke tests).
func _shoot(app: PilotApp) -> void:
	for f in args["frames"]:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path: String = args["shot"]
	img.save_png(path if path.is_absolute_path() else ProjectSettings.globalize_path("res://").path_join(path))
	print("saved ", path)
	get_tree().quit()
