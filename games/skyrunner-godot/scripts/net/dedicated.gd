extends SceneTree
## Dedicated headless server (no pilot seat): police-vs-AI for remote desks
## (port of `python -m skyrunner.net.server`).
##
##   godot --headless --script res://scripts/net/dedicated.gd -- [--port 47800] [--seed 1] [--seconds N]

var sess: Session
var srv: HostServer
var seconds := -1.0
var t := 0.0
var acc := 0.0
const DT := 1.0 / 30


func _init() -> void:
	var a := OS.get_cmdline_user_args()
	var port := HostServer.DEFAULT_PORT
	var seed := 1
	for i in a.size() - 1:
		match a[i]:
			"--port": port = int(a[i + 1])
			"--seed": seed = int(a[i + 1])
			"--seconds": seconds = float(a[i + 1])
	sess = Session.new({"mode": Roles.POLICE, "seed": seed, "map_seed": MapCity.SEED, "ground_war": true, "chronicle": true, "agency": true})  # AI runs the desk until a controller joins
	srv = HostServer.new()
	srv.attach(sess)
	root.add_child.call_deferred(srv)
	var err = srv.start(port, Roles.POLICE)
	if err:
		printerr(err)
		quit(1)
		return
	print("Skyrunner task-force server on port %d - connect with --connect HOST:%d --role controller" % [srv.port, srv.port])


func _process(delta: float) -> bool:
	acc += delta
	while acc >= DT:
		acc -= DT
		srv.pump(sess)
		sess.update(DT)
		t += DT
	srv.publish(sess)
	return seconds > 0 and t >= seconds
